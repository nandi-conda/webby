package dev.webby.nim;

import android.content.ContentResolver;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.util.Log;
import android.webkit.MimeTypeMap;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Files in and out: pages' &lt;input type=file&gt; (the system picker; the chosen documents are copied into the cache
 * and their paths handed to Ladybird, as the Flutter app's file_picker does), and reading or writing a document the
 * user picks (bookmarks.html).
 */
final class Files {
    private Files() {}

    private static final String TAG = "webby-nim";

    /** A page asked for files: {tab, request, accept: [...], multiple}. */
    static void pick(MainActivity a, JSONObject r) {
        int tab = r.optInt("tab");
        String request = r.optString("request");
        Set<String> types = new LinkedHashSet<>();
        JSONArray accept = r.optJSONArray("accept");
        for (int i = 0; accept != null && i < accept.length(); i++) {
            String t = accept.optString(i).trim().toLowerCase();
            if (t.startsWith(".")) {
                String m = MimeTypeMap.getSingleton().getMimeTypeFromExtension(t.substring(1));
                types.add(m != null ? m : "*/*");
            } else if (t.contains("/")) {
                types.add(t);
            }
        }
        Intent i = new Intent(Intent.ACTION_GET_CONTENT).addCategory(Intent.CATEGORY_OPENABLE);
        if (types.size() == 1) i.setType(types.iterator().next());
        else {
            i.setType("*/*");
            if (!types.isEmpty() && !types.contains("*/*")) i.putExtra(Intent.EXTRA_MIME_TYPES, types.toArray(new String[0]));
        }
        if (r.optBoolean("multiple")) i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        boolean started = a.startForResult(Intent.createChooser(i, null), (code, data) -> {
            List<Uri> uris = new ArrayList<>();
            if (code == android.app.Activity.RESULT_OK && data != null) {
                if (data.getClipData() != null) {
                    for (int k = 0; k < data.getClipData().getItemCount(); k++) uris.add(data.getClipData().getItemAt(k).getUri());
                } else if (data.getData() != null) {
                    uris.add(data.getData());
                }
            }
            copyIn(a, uris, paths -> Native.cmd("filePicker.respond", "tab", tab, "request", request, "paths", paths));
        });
        if (!started) Native.cmd("filePicker.respond", "tab", tab, "request", request, "paths", new JSONArray());
    }

    interface PathsCallback {
        void done(JSONArray paths);
    }

    /** Copies documents into cache/uploads/<n>/<name> off the main thread; `done` runs on it with their paths. */
    private static void copyIn(MainActivity a, List<Uri> uris, PathsCallback done) {
        if (uris.isEmpty()) {
            done.done(new JSONArray());
            return;
        }
        Handler main = new Handler(Looper.getMainLooper());
        ContentResolver cr = a.getContentResolver();
        File base = new File(a.getCacheDir(), "uploads");
        new Thread(() -> {
            // Earlier uploads: Ladybird has read or opened them by now.
            deleteTree(base);
            JSONArray paths = new JSONArray();
            int n = 0;
            for (Uri u : uris) {
                try {
                    File dir = new File(base, String.valueOf(n++));
                    dir.mkdirs();
                    File out = new File(dir, displayName(cr, u));
                    try (InputStream in = cr.openInputStream(u); OutputStream o = new FileOutputStream(out)) {
                        byte[] buf = new byte[1 << 16];
                        for (int k; (k = in.read(buf)) > 0; ) o.write(buf, 0, k);
                    }
                    paths.put(out.getPath());
                } catch (Exception e) {
                    Log.e(TAG, "copying " + u, e);
                }
            }
            main.post(() -> done.done(paths));
        }).start();
    }

    private static void deleteTree(File f) {
        File[] kids = f.listFiles();
        if (kids != null) for (File k : kids) deleteTree(k);
        f.delete();
    }

    static String displayName(ContentResolver cr, Uri u) {
        String name = null;
        try (Cursor c = cr.query(u, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst()) name = c.getString(0);
        } catch (Exception e) {
            // a provider without names
        }
        if (name == null || name.isEmpty()) name = u.getLastPathSegment();
        if (name == null || name.isEmpty()) name = "file";
        return name.replace('/', '_');
    }

    interface TextCallback {
        void done(String text);
    }

    /** Lets the user pick a document and reads it as UTF-8 text. */
    static void readText(MainActivity a, String mime, TextCallback done) {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(mime);
        a.startForResult(i, (code, data) -> {
            if (code != android.app.Activity.RESULT_OK || data == null || data.getData() == null) return;
            try (InputStream in = a.getContentResolver().openInputStream(data.getData())) {
                ByteArrayOutputStream b = new ByteArrayOutputStream();
                byte[] buf = new byte[1 << 16];
                for (int k; (k = in.read(buf)) > 0; ) b.write(buf, 0, k);
                done.done(new String(b.toByteArray(), StandardCharsets.UTF_8));
            } catch (Exception e) {
                Log.e(TAG, "reading", e);
                Ui.toast(a, "Could not read the file");
            }
        });
    }

    /** Lets the user choose where to save `text` (a new document named `name`). */
    static void writeText(MainActivity a, String name, String mime, String text) {
        Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(mime)
            .putExtra(Intent.EXTRA_TITLE, name);
        a.startForResult(i, (code, data) -> {
            if (code != android.app.Activity.RESULT_OK || data == null || data.getData() == null) return;
            try (OutputStream o = a.getContentResolver().openOutputStream(data.getData(), "wt")) {
                o.write(text.getBytes(StandardCharsets.UTF_8));
                Ui.toast(a, "Saved " + displayName(a.getContentResolver(), data.getData()));
            } catch (Exception e) {
                Log.e(TAG, "writing", e);
                Ui.toast(a, "Could not save the file");
            }
        });
    }

    /** "Save image to Downloads": http(s) through the DownloadManager, data: URLs decoded here. */
    static void saveImage(MainActivity a, String url) {
        try {
            if (url.startsWith("data:")) {
                int comma = url.indexOf(',');
                String meta = url.substring(5, comma);
                String mime = meta.split(";")[0];
                byte[] bytes = meta.endsWith(";base64")
                    ? android.util.Base64.decode(url.substring(comma + 1), android.util.Base64.DEFAULT)
                    : java.net.URLDecoder.decode(url.substring(comma + 1), "UTF-8").getBytes(StandardCharsets.UTF_8);
                String ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime);
                android.content.ContentValues v = new android.content.ContentValues();
                v.put(android.provider.MediaStore.Downloads.DISPLAY_NAME, "image" + (ext != null ? "." + ext : ""));
                v.put(android.provider.MediaStore.Downloads.MIME_TYPE, mime.isEmpty() ? "application/octet-stream" : mime);
                Uri out = a.getContentResolver().insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
                try (OutputStream o = a.getContentResolver().openOutputStream(out)) {
                    o.write(bytes);
                }
                Ui.toast(a, "Saved to Downloads");
                return;
            }
            Uri u = Uri.parse(url);
            String name = u.getLastPathSegment();
            if (name == null || name.isEmpty()) name = "image";
            android.app.DownloadManager.Request r = new android.app.DownloadManager.Request(u)
                .setNotificationVisibility(android.app.DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                .setDestinationInExternalPublicDir(android.os.Environment.DIRECTORY_DOWNLOADS, name.replace('/', '_'));
            a.getSystemService(android.app.DownloadManager.class).enqueue(r);
            Ui.toast(a, "Downloading " + name);
        } catch (Exception e) {
            Log.e(TAG, "save image", e);
            Ui.toast(a, "Could not save the image");
        }
    }
}
