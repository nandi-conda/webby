package dev.webby.kit;

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
import android.os.Bundle;
import android.system.Os;
import android.util.Base64;
import android.util.Log;
import android.widget.Toast;
import dev.nimkit.Host;
import org.json.JSONObject;

/**
 * webby on Android: nimkit's generic Host (framework/android/java) running the same Nim front end as the desktop
 * (nim/webby.nim, as libwebbykit.so), whose chrome is a nimkit widget tree. This subclass only adds what is
 * webby's own on Android: Ladybird's files unpacked before the Nim code starts (LadybirdRuntime), links opened
 * from other apps, and the few platform calls the Nim side makes with hostCall (onHostCall).
 */
public class WebbyHost extends Host {
    private static final String TAG = "webby";
    private static boolean prepared;
    private static String launchUrl = "";

    @Override
    protected void onCreate(Bundle state) {
        if (state == null && (getIntent().getFlags() & Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0) {
            launchUrl = viewedUrl(getIntent());
        }
        super.onCreate(state);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        String url = viewedUrl(intent);
        if (!url.isEmpty()) hostEvent("openUrl", url);
    }

    private static String viewedUrl(Intent intent) {
        if (intent == null || !Intent.ACTION_VIEW.equals(intent.getAction()) || intent.getData() == null) return "";
        return intent.getData().toString();
    }

    private String colorScheme() {
        int night = getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK;
        return night == android.content.res.Configuration.UI_MODE_NIGHT_YES ? "dark" : "light";
    }

    @Override
    public void onConfigurationChanged(android.content.res.Configuration config) {
        super.onConfigurationChanged(config);
        if (prepared) hostEvent("colorScheme", colorScheme());
    }

    @Override
    protected void beforeStart(Runnable start) {
        if (prepared) {
            start.run();
            return;
        }
        try {
            LadybirdRuntime.setEnvironment(this);
        } catch (Exception e) {
            fatal("Could not set up Ladybird: " + e);
            return;
        }
        new Thread(() -> {
            try {
                String prefix = LadybirdRuntime.prepare(this);
                Os.setenv("WEBBY_LADYBIRD_PREFIX", prefix, true);
                runOnUiThread(() -> {
                    Log.i(TAG, "Ladybird prepared at " + prefix);
                    prepared = true;
                    start.run();
                });
            } catch (Exception e) {
                Log.e(TAG, "prepare", e);
                runOnUiThread(() -> fatal("Could not set up Ladybird: " + e));
            }
        }).start();
    }

    private void fatal(String message) {
        new AlertDialog.Builder(this).setMessage(message).setPositiveButton("OK", null).show();
    }

    @Override
    protected String onHostCall(String name, String arg) {
        try {
            switch (name) {
                case "launchUrl": {
                    String url = launchUrl;
                    launchUrl = "";
                    return url;
                }
                case "pinApp": return pinApp(new JSONObject(arg));
                case "keystoreGet": {
                    // "key:" and the key ("key:" alone: none yet), so a failure ("") can't pass for no key
                    String key = Services.keystoreGet(this, arg);
                    return key == null ? null : "key:" + key;
                }
                case "keystorePut": return Services.keystorePut(this, arg);
                case "httpStream":
                    Services.stream(new JSONObject(arg));
                    return "ok";
                case "httpStreamCancel":
                    Services.cancelStream(Integer.parseInt(arg));
                    return "ok";
                case "device": return android.os.Build.MODEL;
                case "colorScheme": return colorScheme();
                case "toast":
                    Toast.makeText(this, arg, Toast.LENGTH_SHORT).show();
                    return "ok";
                default: return null;
            }
        } catch (Exception e) {
            Log.e(TAG, "hostCall " + name, e);
            return null;
        }
    }

    // --- Installed web apps (features/pwa.nim): a pinned home screen shortcut that opens the app's start URL

    /** {name, url, id, icon (base64 PNG, may be empty), color}. */
    private String pinApp(JSONObject e) {
        ShortcutManager sm = getSystemService(ShortcutManager.class);
        if (sm == null || !sm.isRequestPinShortcutSupported()) {
            Toast.makeText(this, "This home screen can't add shortcuts", Toast.LENGTH_SHORT).show();
            return "unsupported";
        }
        String name = e.optString("name");
        Intent open = new Intent(Intent.ACTION_VIEW, Uri.parse(e.optString("url")), this, WebbyHost.class)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        Bitmap icon = null;
        byte[] bytes = Base64.decode(e.optString("icon"), Base64.DEFAULT);
        if (bytes.length > 0) icon = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (icon == null) icon = letterIcon(name, e.optString("color"));
        ShortcutInfo info = new ShortcutInfo.Builder(this, "app:" + e.optString("id"))
            .setShortLabel(name.isEmpty() ? "Web app" : name)
            .setIcon(Icon.createWithBitmap(icon))
            .setIntent(open)
            .build();
        sm.requestPinShortcut(info, null);
        return "ok";
    }

    /** The app's first letter on its background color, for apps without a bitmap icon. */
    private static Bitmap letterIcon(String name, String color) {
        Bitmap b = Bitmap.createBitmap(192, 192, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        int bg = 0xff3f6fb5;
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
