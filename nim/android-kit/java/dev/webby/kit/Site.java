package dev.webby.kit;

import android.Manifest;
import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import dev.nimkit.Host;
import org.json.JSONObject;

/**
 * Pages' location and notifications for nim/src/features/site (geolocation.nim, notifications.nim): Android's
 * LocationManager and NotificationManager, asking for the app's own permission the first time a page needs it.
 * Fixes come back as host events location {lat, lon, accuracy, altitude, heading, speed} or locationError
 * {denied, message}; a tapped notification as notificationClick and a dismissed one as notificationClosed (its id).
 */
final class Site {
    private static final String TAG = "webby";
    private static final String CHANNEL = "pages";
    private static final String DISMISSED = "dev.webby.kit.NOTIFICATION_DISMISSED";
    static final String EXTRA_NOTIFICATION = "dev.webby.kit.notification";
    private static final int PERMISSION_REQUEST = 77;
    private static LocationListener listener;
    private static Runnable afterPermission;
    private static boolean receiving;
    private static final Handler main = new Handler(Looper.getMainLooper());

    private Site() {}

    // --- The app's own permissions

    interface Granted {
        void done(boolean granted);
    }

    private static void withPermission(Activity a, String perm, Granted then) {
        if (perm == null || a.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED) {
            // Later, not inside the hostCall that asked: what follows sends host events back into Nim.
            main.post(() -> then.done(true));
            return;
        }
        boolean location = perm.equals(Manifest.permission.ACCESS_FINE_LOCATION);
        String[] perms = location ? new String[] {perm, Manifest.permission.ACCESS_COARSE_LOCATION} : new String[] {perm};
        Runnable earlier = afterPermission;
        afterPermission = () -> {
            if (earlier != null) earlier.run();
            then.done(a.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
                || (location && a.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED));
        };
        if (earlier == null) a.requestPermissions(perms, PERMISSION_REQUEST);
    }

    /** From WebbyHost.onRequestPermissionsResult. */
    static void permissionResult() {
        Runnable r = afterPermission;
        afterPermission = null;
        if (r != null) r.run();
    }

    // --- Location

    private static void locationError(boolean denied, String message) {
        try {
            Host.hostEvent("locationError", new JSONObject().put("denied", denied).put("message", message).toString());
        } catch (Exception ignored) {
            // not reached
        }
    }

    private static void send(Location l) {
        try {
            JSONObject o = new JSONObject().put("lat", l.getLatitude()).put("lon", l.getLongitude())
                .put("accuracy", (double) l.getAccuracy());
            if (l.hasAltitude()) o.put("altitude", l.getAltitude());
            if (l.hasBearing()) o.put("heading", (double) l.getBearing());
            if (l.hasSpeed()) o.put("speed", (double) l.getSpeed());
            Host.hostEvent("location", o.toString());
        } catch (Exception e) {
            Log.e(TAG, "location", e);
        }
    }

    static String locationStart(Activity a) {
        LocationManager lm = a.getSystemService(LocationManager.class);
        if (lm == null) return "this phone has no location service";
        if (listener != null) return "ok";
        listener = new LocationListener() {
            @Override
            public void onLocationChanged(Location l) {
                send(l);
            }

            @Override
            public void onStatusChanged(String p, int s, Bundle b) {}

            @Override
            public void onProviderEnabled(String p) {}

            @Override
            public void onProviderDisabled(String p) {}
        };
        LocationListener mine = listener;
        withPermission(a, Manifest.permission.ACCESS_FINE_LOCATION, granted -> {
            if (listener != mine) return;   // stopped while Android asked
            if (!granted) {
                listener = null;
                locationError(true, "Webby isn't allowed to use this phone's location");
                return;
            }
            try {
                Location best = null;
                for (String p : lm.getProviders(true)) {
                    Location l = lm.getLastKnownLocation(p);
                    if (l != null && (best == null || l.getTime() > best.getTime())) best = l;
                }
                if (best != null) send(best);
                boolean any = false;
                for (String p : new String[] {LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.FUSED_PROVIDER}) {
                    if (lm.isProviderEnabled(p)) {
                        lm.requestLocationUpdates(p, 1000, 0, mine, Looper.getMainLooper());
                        any = true;
                    }
                }
                if (!any && best == null) {
                    listener = null;
                    locationError(false, "Location is turned off on this phone");
                }
            } catch (SecurityException | IllegalArgumentException e) {
                listener = null;
                lm.removeUpdates(mine);
                locationError(false, String.valueOf(e.getMessage()));
            }
        });
        return "ok";
    }

    static void locationStop(Activity a) {
        if (listener == null) return;
        a.getSystemService(LocationManager.class).removeUpdates(listener);
        listener = null;
    }

    // --- Notifications

    /** {id, title, text}: shown once Android lets the app post notifications. */
    static String notify(Activity a, JSONObject n) {
        String perm = android.os.Build.VERSION.SDK_INT >= 33 ? Manifest.permission.POST_NOTIFICATIONS : null;
        withPermission(a, perm, granted -> {
            if (granted) post(a, n);
            else Host.hostEvent("notificationClosed", String.valueOf(n.optInt("id")));
        });
        return "ok";
    }

    private static void post(Activity a, JSONObject n) {
        NotificationManager nm = a.getSystemService(NotificationManager.class);
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Website notifications", NotificationManager.IMPORTANCE_DEFAULT));
        }
        listenForDismissals(a);
        int id = n.optInt("id");
        Intent open = new Intent(a, WebbyHost.class).putExtra(EXTRA_NOTIFICATION, id).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent tap = PendingIntent.getActivity(a, id, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Intent gone = new Intent(DISMISSED).setPackage(a.getPackageName()).putExtra(EXTRA_NOTIFICATION, id);
        PendingIntent dismiss = PendingIntent.getBroadcast(a, id, gone, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        // The text is "body\nsite" (or just the site), as on the desktop.
        String text = n.optString("text");
        int nl = text.lastIndexOf('\n');
        Notification.Builder b = new Notification.Builder(a, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(n.optString("title"))
            .setContentText(nl >= 0 ? text.substring(0, nl) : text)
            .setContentIntent(tap)
            .setDeleteIntent(dismiss)
            .setAutoCancel(true);
        if (nl >= 0) b.setSubText(text.substring(nl + 1));
        try {
            nm.notify(id, b.build());
        } catch (SecurityException e) {
            Host.hostEvent("notificationClosed", String.valueOf(id));   // the permission was taken back
        }
    }

    static void cancel(Activity a, int id) {
        a.getSystemService(NotificationManager.class).cancel(id);
    }

    private static void listenForDismissals(Activity a) {
        if (receiving) return;
        receiving = true;
        BroadcastReceiver r = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent i) {
                Host.hostEvent("notificationClosed", String.valueOf(i.getIntExtra(EXTRA_NOTIFICATION, 0)));
            }
        };
        IntentFilter f = new IntentFilter(DISMISSED);
        if (android.os.Build.VERSION.SDK_INT >= 33) a.getApplicationContext().registerReceiver(r, f, Context.RECEIVER_NOT_EXPORTED);
        else a.getApplicationContext().registerReceiver(r, f);
    }

    /** A notification tapped: the intent that brought the app up says which. */
    static void opened(Intent intent) {
        if (intent == null || !intent.hasExtra(EXTRA_NOTIFICATION)) return;
        Host.hostEvent("notificationClick", String.valueOf(intent.getIntExtra(EXTRA_NOTIFICATION, 0)));
        intent.removeExtra(EXTRA_NOTIFICATION);
    }
}
