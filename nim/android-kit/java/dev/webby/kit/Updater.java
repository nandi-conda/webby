package dev.webby.kit;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageInstaller;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.util.Log;
import dev.nimkit.Host;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import org.json.JSONObject;

/**
 * In-app updates (features/apkupdate.nim): the Nim side finds a newer webby-nim-android-&lt;version&gt; release on
 * GitHub and calls "updateInstall" with {version, apk, sha256} (asset download URLs). This downloads the APK into
 * the cache, checks it against the release's .sha256, and hands it to the system's PackageInstaller, which asks
 * the user to confirm. Installing over this app needs the "install unknown apps" permission for Webby; without it
 * this opens that setting and carries on when the user comes back (WebbyHost.onResume).
 *
 * Progress goes back to Nim as host events: update.progress (percent), update.installing, update.permission,
 * update.failed (why). On success Android replaces the app and stops this process.
 */
final class Updater {
    private static final String TAG = "webby";
    private static final String ACTION = "dev.webby.kit.UPDATE_STATUS";
    private static JSONObject waitingForPermission;
    private static boolean running;
    private static BroadcastReceiver receiver;

    private Updater() {}

    static String install(Activity a, JSONObject r) {
        if (running) return "busy";
        if (!a.getPackageManager().canRequestPackageInstalls()) {
            waitingForPermission = r;
            Host.hostEvent("update.permission", "");
            a.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + a.getPackageName())));
            return "permission";
        }
        start(a, r);
        return "ok";
    }

    /** Back from the "install unknown apps" setting: go on if it was turned on. */
    static void resumed(Activity a) {
        JSONObject r = waitingForPermission;
        if (r == null) return;
        waitingForPermission = null;
        if (a.getPackageManager().canRequestPackageInstalls()) start(a, r);
        else Host.hostEvent("update.failed", "Webby isn't allowed to install apps");
    }

    private static void start(Activity a, JSONObject r) {
        running = true;
        Context app = a.getApplicationContext();
        new Thread(() -> {
            File apk = new File(app.getCacheDir(), "update.apk");
            try {
                String expected = r.optString("sha256").isEmpty() ? "" : fetchText(r.getString("sha256"))
                    .trim().split("\\s+")[0].toLowerCase();
                String actual = download(r.getString("apk"), apk);
                if (!expected.isEmpty() && !expected.equals(actual)) throw new Exception("checksum mismatch");
                Host.hostEvent("update.installing", r.optString("version"));
                commit(app, apk);
            } catch (Exception e) {
                Log.e(TAG, "update", e);
                apk.delete();
                running = false;
                Host.hostEvent("update.failed", e.getMessage() == null ? e.toString() : e.getMessage());
            }
        }).start();
    }

    private static HttpURLConnection open(String url) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(15000);
        c.setReadTimeout(60000);
        c.setInstanceFollowRedirects(true);   // github.com's asset links redirect to its file host
        int status = c.getResponseCode();
        if (status != 200) throw new Exception("HTTP " + status + " for " + url);
        return c;
    }

    private static String fetchText(String url) throws Exception {
        HttpURLConnection c = open(url);
        try (InputStream in = c.getInputStream()) {
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();   // readAllBytes is API 33
            byte[] buf = new byte[4096];
            for (int n; (n = in.read(buf)) > 0; ) out.write(buf, 0, n);
            return out.toString("UTF-8");
        } finally {
            c.disconnect();
        }
    }

    /** Downloads `url` to `to` and returns its SHA-256 (hex). */
    private static String download(String url, File to) throws Exception {
        HttpURLConnection c = open(url);
        long total = c.getContentLengthLong();
        MessageDigest sha = MessageDigest.getInstance("SHA-256");
        try (InputStream in = c.getInputStream(); OutputStream out = new FileOutputStream(to)) {
            byte[] buf = new byte[1 << 16];
            long got = 0;
            int shown = -1;
            for (int n; (n = in.read(buf)) > 0; ) {
                out.write(buf, 0, n);
                sha.update(buf, 0, n);
                got += n;
                int pct = total > 0 ? (int) (got * 100 / total) : -1;
                if (pct != shown) {
                    shown = pct;
                    Host.hostEvent("update.progress", Integer.toString(pct));
                }
            }
        } finally {
            c.disconnect();
        }
        StringBuilder hex = new StringBuilder();
        for (byte b : sha.digest()) hex.append(String.format("%02x", b));
        return hex.toString();
    }

    private static void commit(Context app, File apk) throws Exception {
        PackageInstaller pi = app.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params =
            new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(app.getPackageName());
        params.setSize(apk.length());
        int id = pi.createSession(params);
        try (PackageInstaller.Session s = pi.openSession(id)) {
            try (InputStream in = new FileInputStream(apk); OutputStream out = s.openWrite("webby.apk", 0, apk.length())) {
                byte[] buf = new byte[1 << 16];
                for (int n; (n = in.read(buf)) > 0; ) out.write(buf, 0, n);
                s.fsync(out);
            }
            listen(app);
            Intent status = new Intent(ACTION).setPackage(app.getPackageName());
            int flags = PendingIntent.FLAG_UPDATE_CURRENT
                | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0);
            s.commit(PendingIntent.getBroadcast(app, id, status, flags).getIntentSender());
        }
    }

    /** The installer's answers: first "needs the user" (its confirm screen, which we open), then the result. */
    private static synchronized void listen(Context app) {
        if (receiver != null) return;
        receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent i) {
                int status = i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
                if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                    Intent confirm = i.getParcelableExtra(Intent.EXTRA_INTENT);
                    if (confirm != null) c.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                    return;
                }
                running = false;
                new File(c.getCacheDir(), "update.apk").delete();
                if (status == PackageInstaller.STATUS_SUCCESS) return;   // not reached: the update stops this process
                String msg = i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);
                if (status == PackageInstaller.STATUS_FAILURE_ABORTED) msg = "cancelled";
                else if (status == PackageInstaller.STATUS_FAILURE_CONFLICT
                         || status == PackageInstaller.STATUS_FAILURE_INCOMPATIBLE)
                    msg = "it doesn't fit this install (" + (msg == null ? "conflict" : msg) + ")";
                Host.hostEvent("update.failed", msg == null ? "status " + status : msg);
            }
        };
        IntentFilter filter = new IntentFilter(ACTION);
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
        else app.registerReceiver(receiver, filter);
    }
}
