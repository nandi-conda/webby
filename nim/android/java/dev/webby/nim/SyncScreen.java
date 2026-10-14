package dev.webby.nim;

import android.app.AlertDialog;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/** Sync (sync_page.dart) and Tabs from other devices (device_tabs_page.dart), over features/sync.nim. */
final class SyncScreen {
    private SyncScreen() {}

    /** The screen showing now, refreshed on "syncStatus" events. */
    private static Runnable refresh;

    static void statusChanged(MainActivity a, JSONObject e) {
        if (!e.optString("error").isEmpty()) {
            new AlertDialog.Builder(a).setTitle("Couldn't turn off sync").setMessage(e.optString("error"))
                .setPositiveButton("OK", null).show();
        }
        if (refresh != null) refresh.run();
    }

    private static void track(Screen s, Runnable r) {
        refresh = r;
        s.dialog.setOnDismissListener(d -> {
            if (refresh == r) refresh = null;
        });
    }

    private static TextView para(MainActivity a, String text, boolean dim) {
        TextView t = Ui.text(a, text, 14, dim ? Ui.dim : Ui.foreground);
        t.setSingleLine(false);
        t.setPadding(Ui.dp(a, 16), Ui.dp(a, 6), Ui.dp(a, 16), Ui.dp(a, 6));
        return t;
    }

    private static View buttons(MainActivity a, Button... bs) {
        LinearLayout row = new LinearLayout(a);
        row.setPadding(Ui.dp(a, 12), 0, Ui.dp(a, 12), 0);
        for (Button b : bs) row.addView(b);
        return row;
    }

    private static Button button(MainActivity a, String label, Runnable click) {
        Button b = new Button(a);
        b.setText(label);
        b.setAllCaps(false);
        b.setOnClickListener(v -> click.run());
        return b;
    }

    // ---- Sync

    static void show(MainActivity a) {
        Screen s = new Screen(a, "Sync");
        boolean[] codeShown = {false};
        Runnable fill = new Runnable() {
            public void run() {
                List<View> rows = new ArrayList<>();
                JSONObject st = Native.obj("sync.state");
                if (st == null) return;
                if (st.has("vaultError")) {
                    rows.add(para(a, st.optString("vaultError"), true));
                } else if (!st.optBoolean("on")) {
                    rows.add(Ui.heading(a, "Sync passwords, bookmarks and tabs"));
                    rows.add(para(a, "Everything is encrypted with a sync code before it leaves this device; "
                        + "only your devices can read it.", true));
                    rows.add(buttons(a, button(a, "Turn on sync", () -> setup(a, false, this)),
                        button(a, "I have a sync code", () -> setup(a, true, this))));
                } else {
                    if (!st.optString("lastError").isEmpty()) rows.add(para(a, "Sync isn't working: " + st.optString("lastError"), false));
                    rows.add(para(a, st.optString("status"), false));
                    Button now = button(a, "Sync now", () -> Native.cmd("sync.now"));
                    now.setEnabled(!st.optBoolean("syncing"));
                    rows.add(buttons(a, now, button(a, "Tabs from other devices", () -> showDevices(a))));
                    rows.add(Ui.heading(a, "Add another device"));
                    rows.add(para(a, "In webby on the other device, open Sync, then I have a sync code, and paste this "
                        + "code (or the pairing link). Keep it private: it unlocks your passwords."
                        + (st.optBoolean("webdav") ? " The other device also needs the WebDAV login." : ""), true));
                    if (!codeShown[0]) {
                        rows.add(buttons(a, button(a, "Show sync code", () -> { codeShown[0] = true; run(); })));
                    } else {
                        TextView code = para(a, st.optString("code"), false);
                        code.setTypeface(android.graphics.Typeface.MONOSPACE);
                        code.setTextIsSelectable(true);
                        rows.add(code);
                        String link = st.optString("pairingLink");
                        List<Button> bs = new ArrayList<>();
                        bs.add(button(a, "Copy code", () -> { a.copy(st.optString("code")); Ui.toast(a, "Copied"); }));
                        if (!link.isEmpty()) bs.add(button(a, "Copy pairing link", () -> { a.copy(link); Ui.toast(a, "Copied"); }));
                        bs.add(button(a, "Hide", () -> { codeShown[0] = false; run(); }));
                        rows.add(buttons(a, bs.toArray(new Button[0])));
                    }
                    rows.add(Ui.heading(a, "Turn off"));
                    rows.add(buttons(a, button(a, "Turn off on this device", () -> Native.cmd("sync.off", "erase", false))));
                    rows.add(buttons(a, button(a, "Turn off everywhere and erase", () -> Ui.confirm(a,
                        "The encrypted copy on the server is deleted and your other devices stop syncing. Passwords "
                            + "and bookmarks already on each device stay there.", "Erase",
                        () -> Native.cmd("sync.off", "erase", true)))));
                }
                s.setRows(rows);
            }
        };
        track(s, fill);
        fill.run();
        s.show();
    }

    /** The setup dialog (_SetupDialog): where to sync and, when joining, the code. */
    private static void setup(MainActivity a, boolean join, Runnable done) {
        LinearLayout form = Ui.form(a);
        EditText code = null;
        if (join) {
            form.addView(Ui.label(a, "Sync code from your other device (or the pairing link)"));
            code = Ui.field(a, "", "webby1-…");
            form.addView(code);
        }
        form.addView(Ui.label(a, "Store the encrypted copy on"));
        RadioGroup where = new RadioGroup(a);
        String[] labels = {"Webby sync", "My sync server", "WebDAV"};
        RadioButton[] radios = new RadioButton[3];
        for (int i = 0; i < 3; i++) {
            radios[i] = new RadioButton(a);
            radios[i].setText(labels[i]);
            radios[i].setId(View.generateViewId());
            where.addView(radios[i]);
        }
        radios[0].setChecked(true);
        form.addView(where);
        TextView serverLabel = Ui.label(a, "Server address");
        EditText server = Ui.field(a, "", "https://sync.example.com");
        server.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        TextView userLabel = Ui.label(a, "Username");
        EditText user = Ui.field(a, "", "Username");
        TextView passLabel = Ui.label(a, "Password (an app password is best)");
        EditText pass = Ui.field(a, "", "Password");
        pass.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        for (View v : new View[] {serverLabel, server, userLabel, user, passLabel, pass}) form.addView(v);
        Runnable storageChanged = () -> {
            boolean dav = radios[2].isChecked(), custom = radios[1].isChecked();
            int vis = dav || custom ? View.VISIBLE : View.GONE;
            serverLabel.setVisibility(vis);
            server.setVisibility(vis);
            for (View v : new View[] {userLabel, user, passLabel, pass}) v.setVisibility(dav ? View.VISIBLE : View.GONE);
            serverLabel.setText(dav ? "Folder address" : "Server address (runs sync-server from the webby repo)");
            server.setHint(dav ? "https://cloud.example.com/remote.php/dav/files/me/webby" : "https://sync.example.com");
        };
        where.setOnCheckedChangeListener((g, id) -> storageChanged.run());
        storageChanged.run();
        if (code != null) {
            EditText c = code;
            c.addTextChangedListener(new TextWatcher() {
                public void beforeTextChanged(CharSequence s, int x, int y, int z) {}
                public void onTextChanged(CharSequence s, int x, int y, int z) {}
                public void afterTextChanged(Editable e) {
                    JSONObject p = Native.obj("sync.parsePairing", "text", c.getText().toString());
                    if (p == null) return;
                    String st = p.optString("storage");
                    radios[st.equals("webdav") ? 2 : st.equals("custom") ? 1 : 0].setChecked(true);
                    server.setText(p.optString("server"));
                }
            });
        }
        TextView error = Ui.text(a, "", 13, 0xffc01c28);
        error.setSingleLine(false);
        form.addView(error);
        android.widget.ScrollView scroll = new android.widget.ScrollView(a);
        scroll.addView(form);
        EditText codeField = code;
        AlertDialog d = new AlertDialog.Builder(a).setTitle(join ? "Join sync" : "Turn on sync").setView(scroll)
            .setPositiveButton(join ? "Join" : "Turn on", null).setNegativeButton("Cancel", null).create();
        d.setOnShowListener(x -> d.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String storage = radios[2].isChecked() ? "webdav" : radios[1].isChecked() ? "custom" : "webby";
            JSONObject r = Native.obj("sync.turnOn", "join", join, "code", codeField == null ? "" : codeField.getText().toString(),
                "storage", storage, "server", server.getText().toString(), "username", user.getText().toString(),
                "password", pass.getText().toString());
            if (r != null && !r.optString("error").isEmpty()) {
                error.setText(r.optString("error"));
                return;
            }
            d.dismiss();
            done.run();
        }));
        d.show();
    }

    // ---- Tabs from other devices

    static void showDevices(MainActivity a) {
        Screen s = new Screen(a, "Tabs from other devices");
        s.addAction(R.drawable.ic_refresh, "Refresh", v -> Native.cmd("sync.now"));
        Runnable fill = () -> {
            List<View> rows = new ArrayList<>();
            JSONObject r = Native.obj("devices.list");
            if (r == null) return;
            if (!r.optBoolean("on")) {
                rows.add(Ui.heading(a, "See the tabs open on your other devices"));
                rows.add(para(a, "Tabs travel with your passwords and bookmarks, encrypted with your sync code. "
                    + "Turn on sync here and on your other devices to see their tabs.", true));
                rows.add(buttons(a, button(a, "Set up sync", () -> { s.dismiss(); show(a); })));
                s.setRows(rows);
                return;
            }
            if (!r.optString("lastError").isEmpty()) rows.add(para(a, "Sync isn't working: " + r.optString("lastError"), false));
            JSONArray ds = r.optJSONArray("devices");
            if (ds.length() == 0) {
                rows.add(para(a, "No other devices have shared their tabs yet. They show up here once webby on another "
                    + "device is syncing with the same sync code.", true));
            }
            for (int i = 0; i < ds.length(); i++) {
                JSONObject d = ds.optJSONObject(i);
                JSONArray ts = d.optJSONArray("tabs");
                View head = Ui.row(a, d.optString("platform").equals("android") ? R.drawable.ic_smartphone : R.drawable.ic_computer,
                    d.optString("name"), d.optString("seen"), null);
                head.setOnLongClickListener(v -> {
                    Ui.confirm(a, "Open all " + ts.length() + " tabs from " + d.optString("name") + "?", "Open all", () -> {
                        for (int k = 0; k < ts.length(); k++) a.openInNewTab(ts.optJSONObject(k).optString("url"), false);
                    });
                    return true;
                });
                rows.add(head);
                if (ts.length() == 0) rows.add(para(a, "No open tabs", true));
                for (int k = 0; k < ts.length(); k++) {
                    JSONObject t = ts.optJSONObject(k);
                    String url = t.optString("url");
                    View row = Ui.row(a, R.drawable.ic_public, t.optString("title").isEmpty() ? url : t.optString("title"), url, null);
                    row.setPadding(Ui.dp(a, 40), row.getPaddingTop(), row.getPaddingRight(), row.getPaddingBottom());
                    row.setOnClickListener(v -> { s.dismiss(); a.openInNewTab(url, true); });
                    row.setOnLongClickListener(v -> { a.linkMenu(url, null, null); return true; });
                    rows.add(row);
                }
            }
            rows.add(Ui.heading(a, "This device"));
            int n = r.optInt("shared");
            View me = Ui.row(a, R.drawable.ic_smartphone, r.optString("name"), r.optBoolean("sharing")
                ? "Your other devices see the " + n + (n == 1 ? " tab" : " tabs") + " open here."
                : "Your other devices don't see the tabs open here.", null);
            me.setOnClickListener(v -> {
                LinearLayout form = Ui.form(a);
                EditText name = Ui.field(a, r.optString("name"), "Device name");
                form.addView(name);
                new AlertDialog.Builder(a).setTitle("Name this device").setView(form)
                    .setPositiveButton("Save", (dd, w) -> Native.cmd("devices.rename", "name", name.getText().toString().trim()))
                    .setNegativeButton("Cancel", null).show();
            });
            rows.add(me);
            CheckBox share = new CheckBox(a);
            share.setText("Share this device's tabs");
            share.setTextColor(Ui.foreground);
            share.setChecked(r.optBoolean("sharing"));
            share.setPadding(Ui.dp(a, 8), Ui.dp(a, 8), 0, Ui.dp(a, 8));
            share.setOnCheckedChangeListener((b, on) -> Native.cmd("devices.share", "on", on));
            LinearLayout box = new LinearLayout(a);
            box.setPadding(Ui.dp(a, 12), 0, 0, 0);
            box.addView(share);
            rows.add(box);
            s.setRows(rows);
        };
        track(s, fill);
        fill.run();
        s.show();
        Native.cmd("sync.now");
    }
}
