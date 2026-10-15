package dev.nimkit;

import android.app.Activity;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.TextWatcher;
import android.util.Base64;
import android.util.Log;
import android.util.SparseArray;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * The one Activity of a nimkit app: it holds the native views the Nim side asks for (op), passes their events back
 * (Native.event), and runs timers and HTTP requests for it. Nothing here is app-specific; the app's library name
 * comes from the manifest's <meta-data android:name="nimkit.lib">.
 */
public class Host extends Activity {
    // Ops from nk_op (src/nimkit/backend/android.nim).
    static final int CREATE = 0, TEXT = 1, PLACEHOLDER = 2, CHECKED = 3, ENABLED = 4, EXPAND = 5, SPACING = 6,
            PADDING = 7, MIN_SIZE = 8, ADD = 9, REMOVE = 10, ROOT = 11, TITLE = 12, TIMER = 13, UNTIMER = 14,
            QUIT = 15, FORGET = 16;
    // Widget kinds (WidgetKind in src/nimkit/core.nim).
    static final int COLUMN = 0, ROW = 1, SCROLL = 2, LABEL = 3, BUTTON = 4, ENTRY = 5, CHECK = 6, CANVAS = 7;

    static Host current;
    static final Handler main = new Handler(Looper.getMainLooper());
    static final SparseArray<Runnable> timers = new SparseArray<>();

    final SparseArray<View> views = new SparseArray<>();
    final SparseArray<Boolean> expand = new SparseArray<>();
    final SparseArray<int[]> minSize = new SparseArray<>();
    boolean syncing;
    FrameLayout content;
    float density;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        current = this;
        density = getResources().getDisplayMetrics().density;
        content = new FrameLayout(this);
        setContentView(content);
        try {
            String lib = getPackageManager().getActivityInfo(getComponentName(), android.content.pm.PackageManager.GET_META_DATA)
                    .metaData.getString("nimkit.lib");
            System.loadLibrary(lib);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
        Native.start(Host.class, getFilesDir().getAbsolutePath(), density);
    }

    @Override
    protected void onDestroy() {
        if (current == this) current = null;
        super.onDestroy();
    }

    int px(int dp) { return Math.round(dp * density); }

    // --- Ops from Nim

    static void op(int op, int id, int arg, String text) {
        switch (op) {
            case TIMER: {
                Runnable r = () -> { timers.remove(id); Native.timer(id); };
                timers.put(id, r);
                main.postDelayed(r, arg);
                return;
            }
            case UNTIMER: {
                Runnable r = timers.get(id);
                if (r != null) main.removeCallbacks(r);
                timers.remove(id);
                return;
            }
        }
        if (current != null) current.apply(op, id, arg, text);
    }

    void apply(int op, int id, int arg, String text) {
        View v = views.get(id);
        syncing = true;
        try {
            switch (op) {
                case CREATE: views.put(id, make(id, arg)); break;
                case TEXT:
                    if (v instanceof EditText) {
                        if (!((EditText) v).getText().toString().equals(text)) ((EditText) v).setText(text);
                    } else if (v instanceof TextView) ((TextView) v).setText(text);
                    break;
                case PLACEHOLDER: if (v instanceof EditText) ((EditText) v).setHint(text); break;
                case CHECKED: if (v instanceof CheckBox) ((CheckBox) v).setChecked(arg != 0); break;
                case ENABLED: if (v != null) v.setEnabled(arg != 0); break;
                case EXPAND: expand.put(id, arg != 0); if (v != null) relayout(v, id); break;
                case SPACING:
                    if (v instanceof LinearLayout) {
                        LinearLayout l = (LinearLayout) v;
                        GradientDrawable gap = new GradientDrawable();
                        gap.setSize(px(arg), px(arg));
                        gap.setColor(0);
                        l.setDividerDrawable(gap);
                        l.setShowDividers(LinearLayout.SHOW_DIVIDER_MIDDLE);
                    }
                    break;
                case PADDING: if (v != null) v.setPadding(px(arg), px(arg), px(arg), px(arg)); break;
                case MIN_SIZE:
                    minSize.put(id, new int[] {arg, Integer.parseInt(text)});
                    if (v != null) { v.setMinimumWidth(px(arg)); v.setMinimumHeight(px(Integer.parseInt(text))); }
                    break;
                case ADD: {
                    View child = views.get(arg);
                    ViewGroup parent = (ViewGroup) v;
                    if (child.getParent() != null) ((ViewGroup) child.getParent()).removeView(child);
                    int index = Integer.parseInt(text);
                    parent.addView(child, Math.min(index, parent.getChildCount()));
                    relayout(child, arg);
                    break;
                }
                case REMOVE: ((ViewGroup) v).removeView(views.get(arg)); break;
                case FORGET: views.remove(id); expand.remove(id); minSize.remove(id); break;
                case ROOT:
                    content.removeAllViews();
                    if (v.getParent() != null) ((ViewGroup) v.getParent()).removeView(v);
                    content.addView(v, new FrameLayout.LayoutParams(-1, -1));
                    break;
                case TITLE: setTitle(text); break;
                case QUIT: finish(); break;
            }
        } finally {
            syncing = false;
        }
    }

    /** Layout params for `v` from its parent's direction and its expand flag: it fills across, and takes the spare
     * room along when expanded. */
    void relayout(View v, int id) {
        if (!(v.getParent() instanceof ViewGroup)) return;
        ViewGroup parent = (ViewGroup) v.getParent();
        boolean grow = Boolean.TRUE.equals(expand.get(id));
        if (parent instanceof LinearLayout) {
            boolean vertical = ((LinearLayout) parent).getOrientation() == LinearLayout.VERTICAL;
            LinearLayout.LayoutParams p = vertical
                    ? new LinearLayout.LayoutParams(-1, grow ? 0 : -2, grow ? 1 : 0)
                    : new LinearLayout.LayoutParams(grow ? 0 : -2, -2, grow ? 1 : 0);
            if (!vertical) p.gravity = Gravity.CENTER_VERTICAL;
            if (!vertical && v instanceof SurfaceView) p.height = -1;
            v.setLayoutParams(p);
        } else {
            v.setLayoutParams(new FrameLayout.LayoutParams(-1, -2));
        }
    }

    View make(int id, int kind) {
        switch (kind) {
            case COLUMN: case ROW: {
                LinearLayout l = new LinearLayout(this);
                l.setOrientation(kind == COLUMN ? LinearLayout.VERTICAL : LinearLayout.HORIZONTAL);
                return l;
            }
            case SCROLL: {
                ScrollView s = new ScrollView(this);
                s.setFillViewport(true);
                return s;
            }
            case LABEL: {
                TextView t = new TextView(this);
                t.setTextSize(16);
                return t;
            }
            case BUTTON: {
                Button b = new Button(this);
                b.setAllCaps(false);
                b.setOnClickListener(x -> Native.event(id, Native.CLICK, "", 0, 0, 0));
                return b;
            }
            case ENTRY: {
                EditText e = new EditText(this);
                e.setSingleLine(true);
                e.setImeOptions(EditorInfo.IME_ACTION_DONE);
                e.addTextChangedListener(new TextWatcher() {
                    public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
                    public void onTextChanged(CharSequence s, int a, int b, int c) {}
                    public void afterTextChanged(Editable s) {
                        if (!syncing) Native.event(id, Native.CHANGE, s.toString(), 0, 0, 0);
                    }
                });
                e.setOnEditorActionListener((x, action, ev) -> {
                    Native.event(id, Native.SUBMIT, e.getText().toString(), 0, 0, 0);
                    return false;
                });
                return e;
            }
            case CHECK: {
                CheckBox c = new CheckBox(this);
                c.setOnCheckedChangeListener((x, on) -> {
                    if (!syncing) Native.event(id, Native.TOGGLE, "", on ? 1 : 0, 0, 0);
                });
                return c;
            }
            case CANVAS: {
                SurfaceView s = new SurfaceView(this);
                s.getHolder().addCallback(new SurfaceHolder.Callback() {
                    public void surfaceCreated(SurfaceHolder h) {}
                    public void surfaceChanged(SurfaceHolder h, int format, int w, int hh) {
                        Native.surface(id, h.getSurface(), w, hh);
                    }
                    public void surfaceDestroyed(SurfaceHolder h) { Native.surface(id, null, 0, 0); }
                });
                s.setOnTouchListener((x, ev) -> {
                    int kind2;
                    switch (ev.getActionMasked()) {
                        case MotionEvent.ACTION_DOWN: case MotionEvent.ACTION_POINTER_DOWN: kind2 = Native.POINTER_DOWN; break;
                        case MotionEvent.ACTION_UP: case MotionEvent.ACTION_POINTER_UP: kind2 = Native.POINTER_UP; break;
                        case MotionEvent.ACTION_CANCEL: kind2 = Native.POINTER_CANCEL; break;
                        default: kind2 = Native.POINTER_MOVE;
                    }
                    if (kind2 == Native.POINTER_MOVE) {
                        for (int i = 0; i < ev.getPointerCount(); i++)
                            Native.event(id, kind2, "", ev.getX(i), ev.getY(i), ev.getPointerId(i));
                    } else {
                        int i = ev.getActionIndex();
                        Native.event(id, kind2, "", ev.getX(i), ev.getY(i), ev.getPointerId(i));
                    }
                    return true;
                });
                return s;
            }
        }
        throw new IllegalArgumentException("kind " + kind);
    }

    // --- HTTP for Nim: a request as JSON {method, url, headers: [[k, v]], body (base64)}, answered with a
    // HTTP_DONE event whose text is {status, reason, headers, body (base64), error}.

    static void http(int id, String json) {
        new Thread(() -> {
            JSONObject reply = new JSONObject();
            try {
                JSONObject q = new JSONObject(json);
                HttpURLConnection c = (HttpURLConnection) new URL(q.getString("url")).openConnection();
                c.setRequestMethod(q.getString("method"));
                c.setConnectTimeout(15000);
                c.setReadTimeout(30000);
                JSONArray hs = q.optJSONArray("headers");
                for (int i = 0; hs != null && i < hs.length(); i++)
                    c.setRequestProperty(hs.getJSONArray(i).getString(0), hs.getJSONArray(i).getString(1));
                byte[] body = Base64.decode(q.optString("body", ""), Base64.DEFAULT);
                if (body.length > 0) {
                    c.setDoOutput(true);
                    try (OutputStream o = c.getOutputStream()) { o.write(body); }
                }
                int status = c.getResponseCode();
                InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream();
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                if (in != null) {
                    byte[] buf = new byte[16384];
                    for (int n; (n = in.read(buf)) > 0; ) out.write(buf, 0, n);
                    in.close();
                }
                JSONArray rh = new JSONArray();
                for (Map.Entry<String, List<String>> h : c.getHeaderFields().entrySet()) {
                    if (h.getKey() == null) continue;
                    for (String value : h.getValue()) rh.put(new JSONArray().put(h.getKey().toLowerCase()).put(value));
                }
                reply.put("status", status).put("reason", c.getResponseMessage() == null ? "" : c.getResponseMessage())
                        .put("headers", rh).put("body", Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP));
                c.disconnect();
            } catch (Exception e) {
                try { reply.put("status", 0).put("error", String.valueOf(e.getMessage())); } catch (Exception ignored) {}
                Log.w("nimkit", "http", e);
            }
            String text = reply.toString();
            main.post(() -> Native.event(id, Native.HTTP_DONE, text, 0, 0, 0));
        }).start();
    }
}
