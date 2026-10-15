package dev.webby.kit;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import android.util.Log;
import dev.nimkit.Host;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Platform services the Nim side reaches with hostCall (nim/src/features/android.nim): the password vault's key in
 * the Android Keystore, and streamed HTTP for summaries. Taken from nim/android's Passwords.java and Net.java.
 */
final class Services {
    private static final String TAG = "webby";
    private static final String KEY_ALIAS = "webby-vault";

    private Services() {}

    // --- The vault key: kept in shared preferences, encrypted with a Keystore key that never leaves the device.

    private static SecretKey wrappingKey() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (ks.containsAlias(KEY_ALIAS)) return ((KeyStore.SecretKeyEntry) ks.getEntry(KEY_ALIAS, null)).getSecretKey();
        KeyGenerator g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        g.init(new KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build());
        return g.generateKey();
    }

    private static SharedPreferences prefs(Context c) {
        return c.getSharedPreferences("vault-keys", Context.MODE_PRIVATE);
    }

    /** The profile's vault key, "" when there is none yet, or null when the Keystore failed. */
    static String keystoreGet(Context c, String profile) {
        String saved = prefs(c).getString(profile, null);
        if (saved == null) return "";
        try {
            byte[] blob = Base64.decode(saved, Base64.NO_WRAP);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), new GCMParameterSpec(128, blob, 0, 12));
            return new String(cipher.doFinal(blob, 12, blob.length - 12), StandardCharsets.UTF_8);
        } catch (Exception e) {
            Log.e(TAG, "keystore", e);
            return null;
        }
    }

    /** {profile, secret}; "ok", or null when it failed. */
    static String keystorePut(Context c, String json) {
        try {
            JSONObject j = new JSONObject(json);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, wrappingKey());
            byte[] iv = cipher.getIV();
            byte[] ct = cipher.doFinal(j.getString("secret").getBytes(StandardCharsets.UTF_8));
            byte[] blob = new byte[iv.length + ct.length];
            System.arraycopy(iv, 0, blob, 0, iv.length);
            System.arraycopy(ct, 0, blob, iv.length, ct.length);
            if (!prefs(c).edit().putString(j.getString("profile"), Base64.encodeToString(blob, Base64.NO_WRAP)).commit())
                return null;
            return "ok";
        } catch (Exception e) {
            Log.e(TAG, "keystore", e);
            return null;
        }
    }

    // --- Downloads: Ladybird saves into files/downloads; opening one copies it into the public Downloads collection
    // (once) and hands that to whichever app takes its type.

    private static final Map<String, android.net.Uri> published = new ConcurrentHashMap<>();

    static String openFile(android.app.Activity a, String path) {
        try {
            java.io.File f = new java.io.File(path);
            String ext = android.webkit.MimeTypeMap.getFileExtensionFromUrl(f.getName());
            String mime = ext == null ? null : android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.toLowerCase());
            if (mime == null) mime = "application/octet-stream";
            android.net.Uri uri = published.get(path);
            if (uri == null) {
                android.content.ContentResolver cr = a.getContentResolver();
                android.content.ContentValues v = new android.content.ContentValues();
                v.put(android.provider.MediaStore.Downloads.DISPLAY_NAME, f.getName());
                v.put(android.provider.MediaStore.Downloads.MIME_TYPE, mime);
                uri = cr.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
                if (uri == null) return null;
                try (InputStream in = new java.io.FileInputStream(f); OutputStream out = cr.openOutputStream(uri)) {
                    byte[] buf = new byte[1 << 16];
                    for (int k; (k = in.read(buf)) > 0; ) out.write(buf, 0, k);
                }
                published.put(path, uri);
            }
            a.startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW).setDataAndType(uri, mime)
                .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION));
            return "ok";
        } catch (Exception e) {
            Log.e(TAG, "open " + path, e);
            return null;
        }
    }

    // --- Streams (base.httpStream): the body goes to Nim piece by piece as it arrives, as host events
    // httpStream.status {id, status}, httpStream.data {id, data (base64)} and httpStream.done {id, error}.

    private static final ExecutorService streams = Executors.newCachedThreadPool();
    private static final Map<Integer, HttpURLConnection> open = new ConcurrentHashMap<>();
    private static final Set<Integer> cancelled = ConcurrentHashMap.newKeySet();

    private static void send(String name, JSONObject o) {
        Host.hostEvent(name, o.toString());
    }

    /** {id, method, url, headers: [[k, v]], body (base64)}. */
    static void stream(JSONObject r) {
        int id = r.optInt("id");
        streams.execute(() -> {
            String error = "";
            try {
                HttpURLConnection c = (HttpURLConnection) new URL(r.getString("url")).openConnection();
                open.put(id, c);
                if (cancelled.contains(id)) return;
                c.setConnectTimeout(15000);
                c.setReadTimeout(60000);
                c.setUseCaches(false);
                c.setRequestMethod(r.optString("method", "POST"));
                JSONArray hs = r.optJSONArray("headers");
                for (int i = 0; hs != null && i < hs.length(); i++) {
                    JSONArray h = hs.getJSONArray(i);
                    c.setRequestProperty(h.getString(0), h.getString(1));
                }
                byte[] body = Base64.decode(r.optString("body"), Base64.DEFAULT);
                if (body.length > 0) {
                    c.setDoOutput(true);
                    c.setFixedLengthStreamingMode(body.length);
                    try (OutputStream o = c.getOutputStream()) {
                        o.write(body);
                    }
                }
                int status = c.getResponseCode();
                send("httpStream.status", new JSONObject().put("id", id).put("status", status));
                InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream();
                if (in != null) {
                    try (InputStream s = in) {
                        byte[] buf = new byte[1 << 14];
                        for (int k; (k = s.read(buf)) > 0; ) {
                            if (cancelled.contains(id)) return;
                            send("httpStream.data", new JSONObject().put("id", id)
                                .put("data", Base64.encodeToString(buf, 0, k, Base64.NO_WRAP)));
                        }
                    }
                }
            } catch (Exception e) {
                error = e.getMessage() == null ? e.toString() : e.getMessage();
            } finally {
                HttpURLConnection c = open.remove(id);
                if (c != null) c.disconnect();
            }
            if (cancelled.remove(id)) return;
            try {
                send("httpStream.done", new JSONObject().put("id", id).put("error", error));
            } catch (Exception ignored) {
                // not reached
            }
        });
    }

    static void cancelStream(int id) {
        cancelled.add(id);
        HttpURLConnection c = open.get(id);
        if (c != null) streams.execute(c::disconnect);
    }
}
