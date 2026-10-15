package dev.nimkit;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.FileObserver;
import android.provider.OpenableColumns;
import android.util.Log;
import android.webkit.MimeTypeMap;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * chooseFiles on Android (CHOOSE_FILES): the system's document picker. Picked documents are copied into the cache
 * and their paths go back to Nim (FILES); a save gets a path in the cache that is copied to the chosen document each
 * time the app finishes writing it.
 */
final class Files {
    private static final String TAG = "nimkit";
    private static final List<FileObserver> saves = new ArrayList<>();
    private static int nextBatch;

    private Files() {}

    /** {title, name, save, multiple, patterns: ["*.html"], mimeTypes: ["text/html"]}. */
    static void choose(Host h, int request, String json) {
        JSONObject r;
        try {
            r = new JSONObject(json);
        } catch (Exception e) {
            answer(request, new JSONArray());
            return;
        }
        Set<String> types = new LinkedHashSet<>();
        JSONArray mimes = r.optJSONArray("mimeTypes");
        for (int i = 0; mimes != null && i < mimes.length(); i++) types.add(mimes.optString(i));
        JSONArray patterns = r.optJSONArray("patterns");
        for (int i = 0; patterns != null && i < patterns.length(); i++) {
            String p = patterns.optString(i);
            int dot = p.lastIndexOf('.');
            String m = dot >= 0 ? MimeTypeMap.getSingleton().getMimeTypeFromExtension(p.substring(dot + 1).toLowerCase()) : null;
            types.add(m != null ? m : "*/*");
        }
        boolean save = r.optBoolean("save");
        Intent i;
        if (save) {
            String type = types.size() == 1 ? types.iterator().next() : "application/octet-stream";
            i = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(type)
                .putExtra(Intent.EXTRA_TITLE, r.optString("name", "file"));
        } else {
            i = new Intent(Intent.ACTION_GET_CONTENT).addCategory(Intent.CATEGORY_OPENABLE);
            if (types.size() == 1) i.setType(types.iterator().next());
            else {
                i.setType("*/*");
                if (!types.isEmpty() && !types.contains("*/*")) i.putExtra(Intent.EXTRA_MIME_TYPES, types.toArray(new String[0]));
            }
            if (r.optBoolean("multiple")) i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
            i = Intent.createChooser(i, r.optString("title", null));
        }
        boolean started = h.startForResult(i, (code, data) -> {
            List<Uri> uris = new ArrayList<>();
            if (code == Activity.RESULT_OK && data != null) {
                if (data.getClipData() != null) {
                    for (int k = 0; k < data.getClipData().getItemCount(); k++) uris.add(data.getClipData().getItemAt(k).getUri());
                } else if (data.getData() != null) {
                    uris.add(data.getData());
                }
            }
            if (save) answer(request, uris.isEmpty() ? new JSONArray() : saveTo(h, uris.get(0)));
            else copyIn(h, uris, paths -> answer(request, paths));
        });
        if (!started) answer(request, new JSONArray());
    }

    private static void answer(int request, JSONArray paths) {
        Native.event(request, Native.FILES, paths.toString(), 0, 0, 0);
    }

    /** A path in the cache whose contents go to `uri` whenever the app closes it after writing. */
    private static JSONArray saveTo(Host h, Uri uri) {
        ContentResolver cr = h.getContentResolver();
        File dir = new File(h.getCacheDir(), "saves/" + nextBatch++);
        dir.mkdirs();
        File file = new File(dir, displayName(cr, uri));
        FileObserver o = new FileObserver(dir, FileObserver.CLOSE_WRITE | FileObserver.MOVED_TO) {
            @Override
            public void onEvent(int event, String name) {
                if (name == null || !name.equals(file.getName())) return;
                try (InputStream in = new FileInputStream(file); OutputStream out = cr.openOutputStream(uri, "wt")) {
                    byte[] buf = new byte[1 << 16];
                    for (int k; (k = in.read(buf)) > 0; ) out.write(buf, 0, k);
                } catch (Exception e) {
                    Log.e(TAG, "saving to " + uri, e);
                }
            }
        };
        o.startWatching();
        saves.add(o);
        return new JSONArray().put(file.getPath());
    }

    interface PathsCallback {
        void done(JSONArray paths);
    }

    /** Copies documents into cache/picked/<n>/<name> off the main thread; `done` runs on it with their paths. */
    private static void copyIn(Host h, List<Uri> uris, PathsCallback done) {
        if (uris.isEmpty()) {
            done.done(new JSONArray());
            return;
        }
        ContentResolver cr = h.getContentResolver();
        File base = new File(h.getCacheDir(), "picked");
        new Thread(() -> {
            deleteTree(base);   // earlier picks: the app has read or opened them by now
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
            Host.main.post(() -> done.done(paths));
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
}
