package dev.webby.nim;

import android.app.DownloadManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.FileObserver;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.MediaStore;
import android.system.ErrnoException;
import android.system.Os;
import android.util.Log;
import android.webkit.MimeTypeMap;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.HashMap;
import java.util.Map;

/**
 * Page downloads. Ladybird saves what pages download (Content-Disposition: attachment, &lt;a download&gt;, types it
 * can't show, blob: URLs) into $XDG_DOWNLOAD_DIR by itself, writing "name.N.uuid.download" and renaming it to "name"
 * when done. That folder is the app's files/downloads; this watches it, shows a notification while a file downloads,
 * moves each finished file into the public Downloads collection (MediaStore) and says so with a notification that
 * opens it. The ⋮ menu's Downloads opens the system's downloads list.
 */
final class Downloads {
    private static final String TAG = "webby-nim";
    private static final String CHANNEL = "downloads";
    /** Ladybird's temporary name: the file name, then ".<id>.<uuid>.download". */
    private static final java.util.regex.Pattern TEMPORARY =
        java.util.regex.Pattern.compile("^(.*)\\.\\d+\\.[0-9a-fA-F-]{36}\\.download$");

    private static Context app;
    private static File folder;
    private static FileObserver observer;
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static final Map<String, Long> lastProgress = new HashMap<>();
    private static int nextId = 1000;
    private static final Map<String, Integer> ids = new HashMap<>();

    private Downloads() {}

    static File folder(Context context) {
        return new File(context.getFilesDir(), "downloads");
    }

    /** Before Ladybird starts: where its downloads go. */
    static void setEnvironment(Context context) throws ErrnoException {
        File f = folder(context);
        f.mkdirs();
        Os.setenv("XDG_DOWNLOAD_DIR", f.getPath(), true);
    }

    /** Starts watching the folder (once per process) and publishes anything left there by an earlier run. */
    static synchronized void start(Context context) {
        if (observer != null) return;
        app = context.getApplicationContext();
        folder = folder(app);
        folder.mkdirs();
        observer = new FileObserver(folder, FileObserver.CREATE | FileObserver.MODIFY | FileObserver.MOVED_TO
                | FileObserver.CLOSE_WRITE | FileObserver.DELETE) {
            @Override
            public void onEvent(int event, String name) {
                if (name != null) handle(event & FileObserver.ALL_EVENTS, name);
            }
        };
        observer.startWatching();
        new Thread(() -> {
            File[] left = folder.listFiles();
            if (left == null) return;
            for (File f : left) {
                // An unfinished download from an earlier run is Ladybird's to resume or throw away.
                if (!TEMPORARY.matcher(f.getName()).matches()) publish(f);
            }
        }).start();
    }

    /** Opens the system's list of downloads (the public Downloads folder). */
    static void showAll(MainActivity a) {
        try {
            a.startActivity(new Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (Exception e) {
            Ui.toast(a, "No app shows downloads");
        }
    }

    // Runs on the observer's thread.
    private static void handle(int event, String name) {
        java.util.regex.Matcher m = TEMPORARY.matcher(name);
        if (m.matches()) {
            String shown = m.group(1);
            if (event == FileObserver.CREATE) {
                Log.i(TAG, "download: started " + shown);
                main.post(() -> Ui.toast(app, "Downloading " + shown));
                progress(name, shown, 0);
            } else if (event == FileObserver.MODIFY) {
                long now = SystemClock.uptimeMillis();
                Long last = lastProgress.get(name);
                if (last != null && now - last < 1000) return;
                lastProgress.put(name, now);
                progress(name, shown, new File(folder, name).length());
            } else if (event == FileObserver.DELETE) {
                // Renamed away (finished: MOVED_TO comes for the new name) or deleted (canceled, failed).
                lastProgress.remove(name);
                Integer id;
                synchronized (ids) { id = ids.remove(shown); }
                if (id != null) manager().cancel(id);
            }
            return;
        }
        if (event == FileObserver.MOVED_TO || event == FileObserver.CLOSE_WRITE) {
            File f = new File(folder, name);
            if (f.isFile()) publish(f);
        }
    }

    private static NotificationManager manager() {
        NotificationManager nm = app.getSystemService(NotificationManager.class);
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Downloads", NotificationManager.IMPORTANCE_LOW));
        }
        return nm;
    }

    private static int idFor(String shown) {
        synchronized (ids) {
            Integer id = ids.get(shown);
            if (id == null) ids.put(shown, id = nextId++);
            return id;
        }
    }

    private static void progress(String temporary, String shown, long bytes) {
        Notification note = new Notification.Builder(app, CHANNEL)
            .setSmallIcon(R.drawable.ic_downloading)
            .setContentTitle(shown)
            .setContentText(bytes > 0 ? "Downloading · " + size(bytes) : "Downloading")
            .setProgress(0, 0, true)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build();
        try {
            manager().notify(idFor(shown), note);
        } catch (SecurityException e) {
            // no notification permission
        }
    }

    private static String mimeOf(String name) {
        int dot = name.lastIndexOf('.');
        String type = dot < 0 ? null : MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substring(dot + 1).toLowerCase());
        return type != null ? type : "application/octet-stream";
    }

    /** Moves a finished download into the public Downloads collection and posts "Downloaded <name>". */
    private static synchronized void publish(File f) {
        if (!f.isFile()) return;
        String name = f.getName();
        String mime = mimeOf(name);
        ContentResolver cr = app.getContentResolver();
        ContentValues v = new ContentValues();
        v.put(MediaStore.Downloads.DISPLAY_NAME, name);
        v.put(MediaStore.Downloads.MIME_TYPE, mime);
        v.put(MediaStore.Downloads.IS_PENDING, 1);
        Uri out = null;
        try {
            out = cr.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
            if (out == null) throw new java.io.IOException("MediaStore refused " + name);
            try (InputStream in = new FileInputStream(f); OutputStream o = cr.openOutputStream(out)) {
                byte[] buffer = new byte[1 << 16];
                for (int n; (n = in.read(buffer)) > 0; ) o.write(buffer, 0, n);
            }
            v.clear();
            v.put(MediaStore.Downloads.IS_PENDING, 0);
            cr.update(out, v, null, null);
            long bytes = f.length();
            f.delete();
            Log.i(TAG, "download: saved " + name + " (" + bytes + " bytes) to " + out);
            done(name, out, mime, bytes);
        } catch (Exception e) {
            Log.e(TAG, "download: publishing " + name, e);
            if (out != null) cr.delete(out, null, null);
            main.post(() -> Ui.toast(app, "Couldn't save " + name + " to Downloads"));
        }
    }

    private static void done(String name, Uri uri, String mime, long bytes) {
        Intent open = new Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
        int id = idFor(name);
        synchronized (ids) { ids.remove(name); }
        PendingIntent pi = PendingIntent.getActivity(app, id, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification note = new Notification.Builder(app, CHANNEL)
            .setSmallIcon(R.drawable.ic_download)
            .setContentTitle(name)
            .setContentText("Downloaded · " + size(bytes))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build();
        try {
            manager().notify(id, note);
        } catch (SecurityException e) {
            // no notification permission
        }
        main.post(() -> Ui.toast(app, name + " saved to Downloads"));
    }

    private static String size(long n) {
        if (n < 1000) return n + " B";
        if (n < 1000_000) return String.format("%.0f kB", n / 1e3);
        if (n < 1000_000_000) return String.format("%.1f MB", n / 1e6);
        return String.format("%.2f GB", n / 1e9);
    }
}
