package dev.webby.nim;

import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.ShortcutInfo;
import android.content.pm.ShortcutManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.drawable.Icon;
import android.net.Uri;
import android.util.Base64;
import android.widget.EditText;
import android.widget.LinearLayout;
import org.json.JSONObject;

/** Install app (features/pwa.nim): a pinned home screen shortcut that opens the web app's start URL in Webby. */
final class WebApps {
    private WebApps() {}

    static void install(MainActivity a, String name) {
        LinearLayout form = Ui.form(a);
        EditText field = Ui.field(a, name, "Name");
        form.addView(field);
        form.addView(Ui.label(a, "Adds the app to your home screen."));
        new AlertDialog.Builder(a).setTitle("Install app").setView(form)
            .setPositiveButton("Install", (d, w) -> Native.cmd("pwa.install", "name", field.getText().toString()))
            .setNegativeButton("Cancel", null).show();
    }

    /** {name, url, id, icon (base64 bytes, may be empty), color}. */
    static void pin(MainActivity a, JSONObject e) {
        ShortcutManager sm = a.getSystemService(ShortcutManager.class);
        if (sm == null || !sm.isRequestPinShortcutSupported()) {
            Ui.toast(a, "This home screen can't add shortcuts");
            return;
        }
        String name = e.optString("name");
        Intent open = new Intent(Intent.ACTION_VIEW, Uri.parse(e.optString("url")), a, MainActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        Bitmap icon = null;
        byte[] bytes = Base64.decode(e.optString("icon"), Base64.DEFAULT);
        if (bytes.length > 0) icon = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (icon == null) icon = letterIcon(name, e.optString("color"));
        ShortcutInfo info = new ShortcutInfo.Builder(a, "app:" + e.optString("id"))
            .setShortLabel(name.isEmpty() ? "Web app" : name)
            .setIcon(Icon.createWithBitmap(icon))
            .setIntent(open)
            .build();
        try {
            sm.requestPinShortcut(info, null);
        } catch (Exception ex) {
            Ui.toast(a, "Could not add the shortcut");
        }
    }

    /** The app's first letter on its background color, for apps without a bitmap icon. */
    private static Bitmap letterIcon(String name, String color) {
        Bitmap b = Bitmap.createBitmap(192, 192, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        int bg = Ui.accent;
        try {
            if (!color.isEmpty()) bg = Color.parseColor(color);
        } catch (IllegalArgumentException ignored) {
            // a CSS color Android can't parse
        }
        p.setColor(bg);
        c.drawCircle(96, 96, 96, p);
        p.setColor(Color.luminance(bg) > 0.5f ? Color.BLACK : Color.WHITE);
        p.setTextSize(96);
        p.setTextAlign(Paint.Align.CENTER);
        String letter = name.isEmpty() ? "W" : name.substring(0, name.offsetByCodePoints(0, 1)).toUpperCase();
        c.drawText(letter, 96, 96 - (p.descent() + p.ascent()) / 2, p);
        return b;
    }
}
