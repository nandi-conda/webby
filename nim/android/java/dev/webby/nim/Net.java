package dev.webby.nim;

import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONObject;

/** HTTP for the Nim stores (features/net.nim): one request per "http" event, answered with "http.done". */
final class Net {
    private Net() {}

    private static final ExecutorService pool = Executors.newFixedThreadPool(2);
    private static final Handler main = new Handler(Looper.getMainLooper());

    static void request(JSONObject r) {
        pool.execute(() -> {
            JSONObject done = new JSONObject();
            try {
                done.put("id", r.optInt("id"));
                HttpURLConnection c = (HttpURLConnection) new URL(r.getString("url")).openConnection();
                c.setConnectTimeout(15000);
                c.setReadTimeout(45000);
                c.setInstanceFollowRedirects(false);
                c.setUseCaches(false);
                String method = r.optString("method", "GET");
                c.setRequestMethod(method);
                JSONArray hs = r.optJSONArray("headers");
                for (int i = 0; hs != null && i < hs.length(); i++) {
                    JSONArray h = hs.getJSONArray(i);
                    c.setRequestProperty(h.getString(0), h.getString(1));
                }
                byte[] body = Base64.decode(r.optString("body"), Base64.DEFAULT);
                if (body.length > 0 || method.equals("PUT") || method.equals("POST")) {
                    c.setDoOutput(true);
                    c.setFixedLengthStreamingMode(body.length);
                    try (OutputStream o = c.getOutputStream()) {
                        o.write(body);
                    }
                }
                int status = c.getResponseCode();
                InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream();
                ByteArrayOutputStream b = new ByteArrayOutputStream();
                if (in != null) {
                    try (InputStream s = in) {
                        byte[] buf = new byte[1 << 16];
                        for (int k; (k = s.read(buf)) > 0; ) b.write(buf, 0, k);
                    }
                }
                JSONArray headers = new JSONArray();
                for (Map.Entry<String, List<String>> e : c.getHeaderFields().entrySet()) {
                    if (e.getKey() == null) continue;
                    for (String v : e.getValue()) headers.put(new JSONArray().put(e.getKey().toLowerCase()).put(v));
                }
                done.put("status", status);
                done.put("reason", c.getResponseMessage() == null ? "" : c.getResponseMessage());
                done.put("headers", headers);
                done.put("body", Base64.encodeToString(b.toByteArray(), Base64.NO_WRAP));
                c.disconnect();
            } catch (Exception e) {
                try {
                    done.put("status", 0);
                    done.put("error", e.getMessage() == null ? e.toString() : e.getMessage());
                } catch (Exception ignored) {
                    // not reached
                }
            }
            main.post(() -> Native.command("http.done", done.toString()));
        });
    }

    // ---- Streams (features/net.nim's httpStream): the body goes to Nim piece by piece as it arrives.

    private static final ExecutorService streams = Executors.newCachedThreadPool();
    private static final java.util.Map<Integer, HttpURLConnection> open = new java.util.concurrent.ConcurrentHashMap<>();
    private static final java.util.Set<Integer> cancelled = java.util.concurrent.ConcurrentHashMap.newKeySet();

    private static void send(String command, JSONObject o) {
        main.post(() -> Native.command(command, o.toString()));
    }

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
                String method = r.optString("method", "POST");
                c.setRequestMethod(method);
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

    static void cancelStream(JSONObject r) {
        int id = r.optInt("id");
        cancelled.add(id);
        HttpURLConnection c = open.get(id);
        if (c != null) streams.execute(c::disconnect);
    }
}
