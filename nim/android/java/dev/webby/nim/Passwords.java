package dev.webby.nim;

import android.app.AlertDialog;
import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.text.InputType;
import android.util.Base64;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.List;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Passwords and passkeys (src/features/passwords.nim on the desktop): the vault key in the Android Keystore, the
 * save / fill / generate bar above the page, the passkey dialog and the Passwords screen.
 */
final class Passwords {
    private Passwords() {}

    private static final String TAG = "webby-nim";
    private static final String KEY_ALIAS = "webby-vault";

    // ---- The vault key: kept in shared preferences, encrypted with a Keystore key that never leaves the device.

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
            if (!prefs(c).edit().putString(j.getString("profile"), Base64.encodeToString(blob, Base64.NO_WRAP)).commit()) return null;
            return "ok";
        } catch (Exception e) {
            Log.e(TAG, "keystore", e);
            return null;
        }
    }

    // ---- The bar above the page

    static void showOffer(MainActivity a, LinearLayout bar, JSONObject o) {
        bar.removeAllViews();
        String kind = o.optString("kind");
        if (kind.equals("none")) {
            bar.setVisibility(View.GONE);
            return;
        }
        String host = o.optString("host");
        String message;
        List<Button> buttons = new ArrayList<>();
        switch (kind) {
            case "saveOffer": {
                String who = o.optString("username").isEmpty() ? "this account" : o.optString("username");
                message = (o.optBoolean("update") ? "Update the saved password for " : "Save the password for ") + who + " on " + host + "?";
                if (!o.optBoolean("update")) buttons.add(button(a, "Never", false, () -> act("never", 0)));
                buttons.add(button(a, "Not now", false, () -> act("dismiss", 0)));
                buttons.add(button(a, o.optBoolean("update") ? "Update" : "Save", true, () -> act("save", 0)));
                break;
            }
            case "generateOffer":
                message = "Use a strong password: " + o.optString("password");
                buttons.add(button(a, "Another", false, () -> act("another", 0)));
                buttons.add(button(a, "No thanks", false, () -> act("dismiss", 0)));
                buttons.add(button(a, "Use", true, () -> act("use", 0)));
                break;
            default: {
                message = "Fill a saved password for " + host;
                JSONArray accounts = o.optJSONArray("accounts");
                for (int i = 0; accounts != null && i < accounts.length(); i++) {
                    JSONObject acc = accounts.optJSONObject(i);
                    int index = acc.optInt("index");
                    String name = acc.optString("username");
                    buttons.add(button(a, name.isEmpty() ? "(no username)" : name, true, () -> act("fill", index)));
                }
                buttons.add(button(a, "Close", false, () -> act("dismiss", 0)));
            }
        }
        TextView text = Ui.text(a, message, 14, Ui.foreground);
        text.setSingleLine(false);
        text.setMaxLines(3);
        bar.addView(text);
        LinearLayout row = new LinearLayout(a);
        row.setGravity(Gravity.END);
        for (Button b : buttons) row.addView(b);
        android.widget.HorizontalScrollView scroll = new android.widget.HorizontalScrollView(a);
        scroll.setHorizontalScrollBarEnabled(false);
        scroll.addView(row);
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        p.gravity = Gravity.END;
        bar.addView(scroll, p);
        bar.setVisibility(View.VISIBLE);
    }

    private static void act(String action, int index) {
        Native.cmd("passwords.offer", "action", action, "index", index);
    }

    private static Button button(Context c, String label, boolean primary, Runnable click) {
        Button b = new Button(c, null, primary ? 0 : android.R.attr.borderlessButtonStyle);
        b.setText(label);
        b.setAllCaps(false);
        if (!primary) b.setTextColor(Ui.accent);
        b.setOnClickListener(v -> click.run());
        return b;
    }

    // ---- Passkeys (passkey_dialog.dart)

    static void passkey(MainActivity a, JSONObject p) {
        int tab = p.optInt("tab");
        String prompt = p.optString("prompt");
        String rpId = p.optString("rpId");
        AlertDialog.Builder b = new AlertDialog.Builder(a).setCancelable(false);
        if (p.optString("type").equals("create")) {
            String userName = p.optString("userName"), display = p.optString("userDisplayName");
            String account = !display.isEmpty() && !display.equals(userName) ? display + " (" + userName + ")" : userName;
            if (p.optBoolean("alreadyRegistered")) {
                b.setTitle("Passkey already saved")
                    .setMessage("This browser already has a passkey for your account on " + rpId + ".");
                b.setPositiveButton("OK", (d, w) -> respond(tab, prompt, true, -1));
            } else {
                b.setTitle("Create a passkey?").setMessage("Save a passkey for " + (account.isEmpty() ? "your account" : account)
                    + " on " + rpId + ". It stays in this browser and signs you in without a password.");
                b.setPositiveButton("Create", (d, w) -> respond(tab, prompt, true, -1));
            }
            b.setNegativeButton("Cancel", (d, w) -> respond(tab, prompt, false, -1));
        } else {
            JSONArray accounts = p.optJSONArray("accounts");
            if (accounts == null || accounts.length() == 0) {
                b.setTitle("No passkeys").setMessage("This browser has no passkeys for " + rpId + ".");
                b.setPositiveButton("OK", (d, w) -> respond(tab, prompt, false, -1));
            } else {
                String[] names = new String[accounts.length()];
                for (int i = 0; i < names.length; i++) {
                    JSONObject acc = accounts.optJSONObject(i);
                    String display = acc.optString("userDisplayName"), name = acc.optString("userName");
                    names[i] = display.isEmpty() ? name : display + "\n" + name;
                }
                b.setTitle("Sign in to " + rpId).setItems(names, (d, i) -> respond(tab, prompt, true, i));
                b.setNegativeButton("Cancel", (d, w) -> respond(tab, prompt, false, -1));
            }
        }
        b.show();
    }

    private static void respond(int tab, String prompt, boolean ok, int account) {
        Native.cmd("passkey.respond", "tab", tab, "prompt", prompt, "ok", ok, "account", account);
    }

    // ---- The Passwords screen

    static void show(MainActivity a) {
        Screen s = new Screen(a, "Passwords and passkeys");
        s.addAction(R.drawable.ic_add, "Add password", v -> edit(a, null, () -> fill(a, s)));
        s.addSearch("Search passwords", () -> fill(a, s));
        fill(a, s);
        s.show();
    }

    private static void fill(MainActivity a, Screen s) {
        JSONObject r = Native.obj("passwords.list", "query", s.query());
        List<View> rows = new ArrayList<>();
        if (r == null) return;
        if (!r.optString("error").isEmpty()) rows.add(s.emptyRow(r.optString("error")));
        JSONArray pw = r.optJSONArray("passwords");
        rows.add(Ui.heading(a, "Passwords"));
        if (pw.length() == 0) rows.add(s.emptyRow(s.query().isEmpty() ? "Passwords you save will show up here." : "No passwords match."));
        for (int i = 0; i < pw.length(); i++) {
            JSONObject p = pw.optJSONObject(i);
            String user = p.optString("username").isEmpty() ? "(no username)" : p.optString("username");
            View row = Ui.row(a, R.drawable.ic_key_outlined, p.optString("host"), user, null);
            row.setOnClickListener(v -> details(a, p, () -> fill(a, s)));
            rows.add(row);
        }
        JSONArray keys = r.optJSONArray("passkeys");
        if (keys.length() > 0) rows.add(Ui.heading(a, "Passkeys"));
        for (int i = 0; i < keys.length(); i++) {
            JSONObject k = keys.optJSONObject(i);
            String id = k.optString("credentialId");
            View del = Ui.iconButton(a, R.drawable.ic_delete_outline, "Delete", v -> Ui.confirm(a,
                "Delete the passkey for " + k.optString("userName") + " on " + k.optString("rpId")
                    + "? You may not be able to sign in there without it.", "Delete", () -> {
                    Native.cmd("passkeys.delete", "credentialId", id);
                    fill(a, s);
                }));
            String name = k.optString("userDisplayName").isEmpty() ? k.optString("userName") : k.optString("userDisplayName");
            rows.add(Ui.row(a, R.drawable.ic_key, k.optString("rpId"), name, del));
        }
        JSONArray never = r.optJSONArray("neverSave");
        if (never.length() > 0) rows.add(Ui.heading(a, "Never saved"));
        for (int i = 0; i < never.length(); i++) {
            String origin = never.optString(i);
            View allow = Ui.iconButton(a, R.drawable.ic_close, "Allow saving", v -> {
                Native.cmd("passwords.allowSaving", "origin", origin);
                fill(a, s);
            });
            rows.add(Ui.row(a, R.drawable.ic_block, origin, null, allow));
        }
        s.setRows(rows);
    }

    private static void details(MainActivity a, JSONObject p, Runnable changed) {
        String[] items = {"Copy username", "Copy password", "Show password", "Edit", "Delete"};
        new AlertDialog.Builder(a).setTitle(p.optString("host") + "\n" + p.optString("username"))
            .setItems(items, (d, i) -> {
                switch (i) {
                    case 0: a.copy(p.optString("username")); Ui.toast(a, "Username copied"); break;
                    case 1: a.copy(p.optString("password")); Ui.toast(a, "Password copied"); break;
                    case 2: new AlertDialog.Builder(a).setTitle(p.optString("host")).setMessage(p.optString("password"))
                        .setPositiveButton("OK", null).show(); break;
                    case 3: edit(a, p, changed); break;
                    case 4: Ui.confirm(a, "Delete the saved password for " + p.optString("username") + " on "
                        + p.optString("host") + "?", "Delete", () -> {
                            Native.cmd("passwords.delete", "id", p.optString("id"));
                            changed.run();
                        }); break;
                }
            }).show();
    }

    private static void edit(MainActivity a, JSONObject p, Runnable changed) {
        LinearLayout form = Ui.form(a);
        form.addView(Ui.label(a, "Site"));
        EditText site = Ui.field(a, p == null ? "" : p.optString("origin"), "https://example.com");
        site.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        form.addView(site);
        form.addView(Ui.label(a, "Username"));
        EditText user = Ui.field(a, p == null ? "" : p.optString("username"), "Username");
        form.addView(user);
        form.addView(Ui.label(a, "Password"));
        EditText pass = Ui.field(a, p == null ? "" : p.optString("password"), "Password");
        pass.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        form.addView(pass);
        Button gen = button(a, "Generate a strong password", false, () -> pass.setText(String.valueOf(Native.cmd("passwords.generate"))));
        form.addView(gen);
        AlertDialog d = new AlertDialog.Builder(a).setTitle(p == null ? "Add password" : "Edit password").setView(form)
            .setPositiveButton("Save", null).setNegativeButton("Cancel", null).create();
        d.setOnShowListener(x -> d.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            JSONObject r = Native.obj("passwords.save", "id", p == null ? "" : p.optString("id"),
                "origin", site.getText().toString().trim(), "username", user.getText().toString(),
                "password", pass.getText().toString());
            if (r != null && r.has("error")) {
                Ui.toast(a, r.optString("error"));
                return;
            }
            d.dismiss();
            changed.run();
        }));
        d.show();
    }
}
