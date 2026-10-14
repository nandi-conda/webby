package dev.webby.nim;

import android.Manifest;
import android.app.AlertDialog;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.Spinner;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Site permissions (the bar asking "site wants to..."), notifications, location and the Site settings sheet, over
 * features/site.nim.
 */
final class Site {
    private Site() {}

    private static final String CHANNEL = "pages";
    static final String EXTRA_NOTIFICATION = "dev.webby.nim.notification";
    private static LocationListener listener;
    private static Runnable afterPermission;

    // ---- The permission bar

    static void showAsk(MainActivity a, LinearLayout bar, JSONObject o) {
        bar.removeAllViews();
        if (o.optString("kind").equals("none")) {
            bar.setVisibility(View.GONE);
            return;
        }
        String kind = o.optString("kind");
        TextView text = Ui.text(a, o.optString("site") + " wants to " + o.optString("request").toLowerCase(), 14, Ui.foreground);
        text.setSingleLine(false);
        bar.addView(text);
        LinearLayout row = new LinearLayout(a);
        row.setGravity(Gravity.END);
        row.addView(button(a, "Never", () -> Native.cmd("permissions.answer", "answer", "never")));
        row.addView(button(a, "This time", () -> allow(a, kind, "once")));
        row.addView(button(a, "Allow", () -> allow(a, kind, "remember")));
        android.widget.HorizontalScrollView scroll = new android.widget.HorizontalScrollView(a);
        scroll.addView(row);
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        p.gravity = Gravity.END;
        bar.addView(scroll, p);
        bar.setVisibility(View.VISIBLE);
    }

    /** Allowing a site also needs Android's permission for it; asked first, and a refusal answers "no". */
    private static void allow(MainActivity a, String kind, String answer) {
        String perm = kind.equals("geolocation") ? Manifest.permission.ACCESS_FINE_LOCATION
            : kind.equals("microphone") ? Manifest.permission.RECORD_AUDIO
            : kind.equals("notifications") && android.os.Build.VERSION.SDK_INT >= 33 ? Manifest.permission.POST_NOTIFICATIONS
            : null;
        withPermission(a, perm, granted -> Native.cmd("permissions.answer", "answer", granted ? answer : "dismiss"));
    }

    interface Granted {
        void done(boolean granted);
    }

    static void withPermission(MainActivity a, String perm, Granted then) {
        if (perm == null || a.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED) {
            then.done(true);
            return;
        }
        String[] perms = perm.equals(Manifest.permission.ACCESS_FINE_LOCATION)
            ? new String[] {perm, Manifest.permission.ACCESS_COARSE_LOCATION} : new String[] {perm};
        afterPermission = () -> then.done(a.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
            || (perm.equals(Manifest.permission.ACCESS_FINE_LOCATION)
                && a.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED));
        a.requestPermissions(perms, 77);
    }

    /** From MainActivity.onRequestPermissionsResult. */
    static void permissionResult() {
        Runnable r = afterPermission;
        afterPermission = null;
        if (r != null) r.run();
    }

    private static Button button(MainActivity a, String label, Runnable click) {
        Button b = new Button(a, null, android.R.attr.borderlessButtonStyle);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextColor(Ui.accent);
        b.setOnClickListener(v -> click.run());
        return b;
    }

    // ---- Notifications

    static void notify(MainActivity a, JSONObject n) {
        NotificationManager nm = a.getSystemService(NotificationManager.class);
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Website notifications", NotificationManager.IMPORTANCE_DEFAULT));
        }
        int id = n.optInt("id");
        Intent open = new Intent(a, MainActivity.class).putExtra(EXTRA_NOTIFICATION, id)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pi = PendingIntent.getActivity(a, id, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        String body = n.optString("body");
        Notification note = new Notification.Builder(a, CHANNEL)
            .setSmallIcon(R.drawable.ic_notifications_outlined)
            .setContentTitle(n.optString("title"))
            .setContentText(body.isEmpty() ? n.optString("site") : body)
            .setSubText(n.optString("site"))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build();
        String tag = n.optString("tag");
        try {
            if (tag.isEmpty()) nm.notify(id, note);
            else nm.notify(tag, 0, note);
        } catch (SecurityException e) {
            // POST_NOTIFICATIONS was taken back
        }
    }

    static void cancel(MainActivity a, JSONObject n) {
        a.getSystemService(NotificationManager.class).cancel(n.optInt("id"));
    }

    static void opened(Intent intent) {
        if (intent == null || !intent.hasExtra(EXTRA_NOTIFICATION)) return;
        Native.cmd("notification.clicked", "id", intent.getIntExtra(EXTRA_NOTIFICATION, 0));
        intent.removeExtra(EXTRA_NOTIFICATION);
    }

    // ---- Location

    static void location(MainActivity a, JSONObject e) {
        LocationManager lm = a.getSystemService(LocationManager.class);
        if (!e.optBoolean("on")) {
            if (listener != null) lm.removeUpdates(listener);
            listener = null;
            return;
        }
        if (listener != null) return;
        withPermission(a, Manifest.permission.ACCESS_FINE_LOCATION, granted -> {
            if (!granted) {
                Native.cmd("location.fix", "error", "Location permission denied", "code", 1);
                return;
            }
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
                        lm.requestLocationUpdates(p, 1000, 0, listener, Looper.getMainLooper());
                        any = true;
                    }
                }
                if (!any && best == null) Native.cmd("location.fix", "error", "Location is off", "code", 2);
            } catch (SecurityException | IllegalArgumentException ex) {
                Native.cmd("location.fix", "error", String.valueOf(ex.getMessage()), "code", 2);
            }
        });
    }

    private static void send(Location l) {
        Native.cmd("location.fix", "lat", l.getLatitude(), "lon", l.getLongitude(),
            "accuracy", (double) l.getAccuracy(), "altitude", l.hasAltitude() ? l.getAltitude() : Double.NaN,
            "heading", l.hasBearing() && l.hasSpeed() && l.getSpeed() > 0 ? (double) l.getBearing() : Double.NaN,
            "speed", l.hasSpeed() ? (double) l.getSpeed() : Double.NaN);
    }

    // ---- Site settings

    static void showSettings(MainActivity a) {
        JSONObject s = Native.obj("site.settings");
        if (s == null || s.optString("origin").isEmpty()) {
            Ui.toast(a, "This page has no site settings");
            return;
        }
        LinearLayout form = Ui.form(a);
        form.addView(Ui.label(a, s.optBoolean("secure") ? "Connection is secure" : "Connection is not secure"));
        String[] choices = {"Ask (default)", "Allow", "Block"};
        String[] values = {"ask", "allow", "block"};
        JSONArray perms = s.optJSONArray("permissions");
        for (int i = 0; i < perms.length(); i++) {
            JSONObject p = perms.optJSONObject(i);
            form.addView(Ui.label(a, p.optString("label")));
            Spinner sp = new Spinner(a);
            sp.setAdapter(new ArrayAdapter<>(a, android.R.layout.simple_spinner_dropdown_item, choices));
            int cur = p.optString("setting").equals("allow") ? 1 : p.optString("setting").equals("block") ? 2 : 0;
            sp.setSelection(cur);
            sp.setOnItemSelectedListener(new android.widget.AdapterView.OnItemSelectedListener() {
                int last = cur;

                public void onItemSelected(android.widget.AdapterView<?> parent, View view, int pos, long id) {
                    if (pos == last) return;
                    last = pos;
                    Native.cmd("site.set", "name", p.optString("name"), "setting", values[pos]);
                }

                public void onNothingSelected(android.widget.AdapterView<?> parent) {}
            });
            form.addView(sp);
        }
        AlertDialog.Builder b = new AlertDialog.Builder(a).setTitle(s.optString("site")).setView(form)
            .setPositiveButton("Done", null)
            .setNeutralButton("Delete site data", (d, w) -> Ui.confirm(a, "Delete the cookies and data "
                + s.optString("site") + " stored in this browser? You'll be signed out of it.", "Delete",
                () -> Native.cmd("site.deleteData")));
        if (s.optBoolean("hasSettings")) b.setNegativeButton("Reset permissions", (d, w) -> Native.cmd("site.reset"));
        b.show();
    }
}
