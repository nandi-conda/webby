package dev.nimkit;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.res.ColorStateList;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.inputmethod.InputMethodManager;
import android.widget.ImageView;
import android.widget.PopupMenu;
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
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.ToggleButton;
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
            QUIT = 15, FORGET = 16, ITEMS = 17, SELECTED = 18, RANGE = 19, VALUE = 20, VISIBLE = 21, TOOLTIP = 22,
            CLASSES = 23, ICON = 24, PASSWORD = 25, FOCUS = 26, SELECT_ALL = 27, MOVE = 28, MENU = 29, DIALOG = 30,
            CLOSE_DIALOG = 31, KEY_HANDLED = 32, MAX_CHARS = 33, IMAGE = 34, POPOVER = 35,
            HIDE_POPOVER = 36, COPY_TEXT = 37, PASTE_TEXT = 38, TOAST = 39, TEXT_FIELD = 40, RICH = 41, CHOOSE_FILES = 42,
            REVEAL = 43;
    // Widget kinds (WidgetKind in src/nimkit/core.nim).
    static final int COLUMN = 0, ROW = 1, SCROLL = 2, LABEL = 3, BUTTON = 4, ENTRY = 5, CHECK = 6, CANVAS = 7,
            SLIDER = 8, DROPDOWN = 9, PROGRESS = 10, TOGGLE = 11, ICON_KIND = 12, ITEM = 13, SEPARATOR = 14,
            OVERLAY = 15, SPLIT = 16, HSCROLL = 30;
    /** A progress bar's resolution: ProgressBar counts in ints. */
    static final int PROGRESS_STEPS = 1000;

    static Host current;
    static final Handler main = new Handler(Looper.getMainLooper());
    static final SparseArray<Runnable> timers = new SparseArray<>();

    final SparseArray<View> views = new SparseArray<>();
    final SparseArray<Boolean> expand = new SparseArray<>();
    final SparseArray<int[]> minSize = new SparseArray<>();
    final SparseArray<double[]> ranges = new SparseArray<>();    // slider id -> {min, max, step, value}
    final SparseArray<Integer> shownSelection = new SparseArray<>();  // dropdown id -> the index Nim knows about
    final SparseArray<String> classes = new SparseArray<>();
    final SparseArray<Integer> rich = new SparseArray<>();       // labels: 1 markup, 2 selectable
    final SparseArray<String> icons = new SparseArray<>();       // id -> "size spec" last shown
    final SparseArray<AlertDialog> dialogs = new SparseArray<>();
    final SparseArray<Boolean> pictures = new SparseArray<>();     // icons showing a picture, not their glyph
    final java.util.HashMap<View, Integer> splits = new java.util.HashMap<>();   // split -> its second pane's width (px)
    final java.util.HashSet<View> overlays = new java.util.HashSet<>();
    final SparseArray<android.widget.PopupWindow> popovers = new SparseArray<>();
    boolean syncing;
    boolean keyHandled;          // set by KEY_HANDLED while an ENTRY_KEY event is being handled
    float touchX, touchY;        // the last touch, in content's pixels, for menus with no place given
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
        beforeStart(() -> Native.start(Host.class, getFilesDir().getAbsolutePath(), density));
    }

    /**
     * For apps' Host subclasses: work that must happen before the Nim code runs (say, unpacking files on a worker
     * thread). Call `start` on the main thread when done; the default starts at once.
     */
    protected void beforeStart(Runnable start) {
        start.run();
    }

    /** For apps' Host subclasses: the Nim side's hostCall(name, arg), on the main thread. null: nothing to say. */
    protected String onHostCall(String name, String arg) {
        return null;
    }

    /** Tells the Nim side's hostEventHooks about something (from the main thread, or posted there). */
    public static void hostEvent(String name, String data) {
        if (Looper.myLooper() == Looper.getMainLooper()) Native.hostEvent(name, data);
        else main.post(() -> Native.hostEvent(name, data));
    }

    static String hostCall(String name, String arg) {
        return current == null ? null : current.onHostCall(name, arg);
    }

    interface ResultCallback {
        void done(int code, android.content.Intent data);
    }

    private final SparseArray<ResultCallback> results = new SparseArray<>();
    private int nextRequest = 1;

    /** Starts `intent` for a result, which goes to `callback`; false when no app takes it. */
    boolean startForResult(android.content.Intent intent, ResultCallback callback) {
        int code = nextRequest++;
        results.put(code, callback);
        try {
            startActivityForResult(intent, code);
            return true;
        } catch (android.content.ActivityNotFoundException e) {
            results.remove(code);
            return false;
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, android.content.Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        ResultCallback c = results.get(requestCode);
        results.remove(requestCode);
        if (c != null) c.done(resultCode, data);
    }

    @Override
    public void onBackPressed() {
        keyHandled = false;
        Native.event(0, Native.BACK, "", 0, 0, 0);
        if (!keyHandled) super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        if (current == this) current = null;
        super.onDestroy();
    }

    int px(int dp) { return Math.round(dp * density); }

    /** A rich label's markup (Pango-style on GTK; the same tags are HTML) with links that ask the Nim side first. */
    void setRichText(int id, TextView t, String markup) {
        android.text.Spanned html = android.text.Html.fromHtml(markup, android.text.Html.FROM_HTML_MODE_COMPACT);
        android.text.SpannableStringBuilder b = new android.text.SpannableStringBuilder(html);
        for (android.text.style.URLSpan u : b.getSpans(0, b.length(), android.text.style.URLSpan.class)) {
            int start = b.getSpanStart(u), end = b.getSpanEnd(u), flags = b.getSpanFlags(u);
            String url = u.getURL();
            b.removeSpan(u);
            b.setSpan(new android.text.style.ClickableSpan() {
                @Override
                public void onClick(View w) {
                    keyHandled = false;
                    Native.event(id, Native.LINK, url, 0, 0, 0);
                    if (keyHandled) return;
                    try {
                        startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW,
                                android.net.Uri.parse(url)));
                    } catch (Exception e) {
                        // no app for it
                    }
                }
            }, start, end, flags);
        }
        t.setText(b);
        t.setMovementMethod(android.text.method.LinkMovementMethod.getInstance());
    }

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
                    } else if (v instanceof ToggleButton) {
                        ToggleButton t = (ToggleButton) v;
                        t.setTextOn(text);
                        t.setTextOff(text);
                        t.setText(text);
                    } else if (v instanceof TextView && (rich.get(id, 0) & 1) != 0) {
                        setRichText(id, (TextView) v, text);
                    } else if (v instanceof TextView) ((TextView) v).setText(text);
                    break;
                case PLACEHOLDER: if (v instanceof EditText) ((EditText) v).setHint(text); break;
                case CHECKED: if (v instanceof CompoundButton) ((CompoundButton) v).setChecked(arg != 0); break;
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
                    int index = Integer.parseInt(text) + skip(parent);
                    parent.addView(child, Math.min(index, parent.getChildCount()));
                    relayout(child, arg);
                    break;
                }
                case REMOVE: ((ViewGroup) v).removeView(views.get(arg)); break;
                case ITEMS: if (v instanceof Spinner) {
                    ArrayAdapter<String> a = new ArrayAdapter<>(this, android.R.layout.simple_spinner_item,
                            text.isEmpty() ? new String[0] : text.split("\n", -1));
                    a.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
                    ((Spinner) v).setAdapter(a);
                    select((Spinner) v, id, shownSelection.get(id, -1));
                }
                break;
                case SELECTED: if (v instanceof Spinner) select((Spinner) v, id, arg); break;
                case RANGE: if (v instanceof SeekBar) {
                    String[] p = text.split(" ");
                    double[] r = ranges.get(id, new double[] {0, 1, 0.01, 0});
                    r[0] = Double.parseDouble(p[0]); r[1] = Double.parseDouble(p[1]); r[2] = Double.parseDouble(p[2]);
                    ranges.put(id, r);
                    showValue((SeekBar) v, r);
                }
                break;
                case VALUE:
                    if (v instanceof SeekBar) {
                        double[] r = ranges.get(id, new double[] {0, 1, 0.01, 0});
                        r[3] = Double.parseDouble(text);
                        ranges.put(id, r);
                        showValue((SeekBar) v, r);
                    } else if (v instanceof ProgressBar) {
                        ((ProgressBar) v).setProgress((int) Math.round(Double.parseDouble(text) * PROGRESS_STEPS));
                    } else if (splits.containsKey(v)) {
                        splits.put(v, px((int) Math.round(Double.parseDouble(text))));
                        ViewGroup g = (ViewGroup) v;
                        if (g.getChildCount() > 1) relayout(g.getChildAt(1), 0);
                    }
                    break;
                case FORGET:
                    if (v != null) { splits.remove(v); overlays.remove(v); }
                    views.remove(id); expand.remove(id); minSize.remove(id); ranges.remove(id); shownSelection.remove(id);
                    classes.remove(id); icons.remove(id); pictures.remove(id); rich.remove(id);
                    break;
                case ROOT:
                    content.removeAllViews();
                    if (v.getParent() != null) ((ViewGroup) v.getParent()).removeView(v);
                    content.addView(v, new FrameLayout.LayoutParams(-1, -1));
                    break;
                case VISIBLE: if (v != null) v.setVisibility(arg != 0 ? View.VISIBLE : View.GONE); break;
                case TOOLTIP: if (v != null) v.setTooltipText(text.isEmpty() ? null : text); break;
                case CLASSES:
                    classes.put(id, text);
                    if (v != null) style(v, id);
                    if (v instanceof LinearLayout)   // a "top" row's children change their alignment
                        for (int i = 0; i < ((LinearLayout) v).getChildCount(); i++) {
                            View c = ((LinearLayout) v).getChildAt(i);
                            int at = views.indexOfValue(c);
                            if (at >= 0) relayout(c, views.keyAt(at));
                        }
                    break;
                case ICON: if (v != null) showIcon(v, id, arg, text); break;
                case PASSWORD: if (v instanceof EditText) {
                    EditText e = (EditText) v;
                    boolean hidden = (e.getInputType() & InputType.TYPE_TEXT_VARIATION_PASSWORD) != 0;
                    if (hidden != (arg != 0)) {
                        e.setInputType(InputType.TYPE_CLASS_TEXT | (arg != 0 ? InputType.TYPE_TEXT_VARIATION_PASSWORD : 0));
                        e.setTypeface(android.graphics.Typeface.DEFAULT);
                    }
                }
                break;
                case FOCUS: if (v != null) {
                    v.setFocusableInTouchMode(true);
                    v.requestFocus();
                    if (v instanceof EditText) v.post(() -> ((InputMethodManager) getSystemService(INPUT_METHOD_SERVICE))
                            .showSoftInput(v, 0));
                }
                break;
                case REVEAL: if (v != null) {
                    // After layout, so a tab added just now has its place; scroll views on the way up scroll to it.
                    v.post(() -> v.requestRectangleOnScreen(new android.graphics.Rect(0, 0, v.getWidth(), v.getHeight())));
                }
                break;
                case SELECT_ALL: if (v instanceof EditText) ((EditText) v).selectAll(); break;
                case MOVE: {
                    View child = views.get(arg);
                    ViewGroup parent = (ViewGroup) v;
                    parent.removeView(child);
                    parent.addView(child, Math.min(Integer.parseInt(text) + skip(parent), parent.getChildCount()));
                    relayout(child, arg);
                    break;
                }
                case MENU: menu(v, text); break;
                case DIALOG: dialog(id, text); break;
                case CLOSE_DIALOG: {
                    AlertDialog d = dialogs.get(id);
                    dialogs.remove(id);
                    if (d != null) d.dismiss();
                    break;
                }
                case KEY_HANDLED: keyHandled = true; break;
                case POPOVER: {
                    // A PopupWindow under the anchor. A plain one doesn't take the focus, so the keyboard stays
                    // up; a modal one (text ends in " modal") does, wraps its content and closes on a touch outside.
                    android.widget.PopupWindow pw = popovers.get(id);
                    boolean modal = text.endsWith(" modal");
                    View body = views.get(Integer.parseInt(modal ? text.substring(0, text.length() - 6) : text));
                    View anchor = views.get(arg);
                    if (body == null || anchor == null || !anchor.isAttachedToWindow()) break;
                    if (pw == null) {
                        if (body.getParent() != null) ((ViewGroup) body.getParent()).removeView(body);
                        if (modal) {
                            body.setPadding(px(12), px(12), px(12), px(12));
                            pw = new android.widget.PopupWindow(body, ViewGroup.LayoutParams.WRAP_CONTENT,
                                ViewGroup.LayoutParams.WRAP_CONTENT, true);
                            pw.setOutsideTouchable(true);
                            final int n = id;
                            // Every dismiss reports; the Nim side ignores the ones hidePopover asked for.
                            pw.setOnDismissListener(() -> Native.event(n, Native.POPOVER_CLOSED, "", 0, 0, 0));
                        } else {
                            pw = new android.widget.PopupWindow(body, anchor.getWidth(), ViewGroup.LayoutParams.WRAP_CONTENT, false);
                            pw.setInputMethodMode(android.widget.PopupWindow.INPUT_METHOD_NEEDED);
                        }
                        GradientDrawable bg = new GradientDrawable();
                        bg.setColor(backgroundColor());
                        bg.setCornerRadius(px(8));
                        bg.setStroke(Math.max(1, px(1) / 2), textColor() & 0x30ffffff);
                        pw.setBackgroundDrawable(bg);
                        pw.setElevation(px(6));
                        popovers.put(id, pw);
                    }
                    if (pw.isShowing()) pw.update(anchor, 0, px(4), modal ? -1 : anchor.getWidth(), -1);
                    else pw.showAsDropDown(anchor, 0, px(4));
                    break;
                }
                case HIDE_POPOVER: {
                    android.widget.PopupWindow pw = popovers.get(id);
                    if (pw != null) pw.dismiss();
                    break;
                }
                case MAX_CHARS: if (v instanceof TextView) {
                    TextView t = (TextView) v;
                    t.setSingleLine(arg > 0);
                    t.setEllipsize(arg > 0 ? android.text.TextUtils.TruncateAt.END : null);
                    // `arg` is characters, as GTK's max-width-chars (about half an em each); an em is an M.
                    t.setMaxEms(arg > 0 ? (arg + 1) / 2 : Integer.MAX_VALUE);
                }
                break;
                case IMAGE: if (v instanceof ImageView) {
                    if (text.isEmpty()) {
                        if (pictures.get(id) == null) break;
                        pictures.remove(id);
                        String icon = icons.get(id);
                        icons.remove(id);   // shows the glyph again
                        if (icon != null && !icon.isEmpty()) {
                            int space = icon.indexOf(' ');
                            showIcon(v, id, Integer.parseInt(icon.substring(0, space)), icon.substring(space + 1));
                        }
                    } else {
                        byte[] b = Base64.decode(text, Base64.DEFAULT);
                        android.graphics.Bitmap bm = android.graphics.BitmapFactory.decodeByteArray(b, 0, b.length);
                        if (bm != null) {
                            ImageView img = (ImageView) v;
                            img.setImageBitmap(bm);
                            String icon = icons.get(id, "");
                            int size = icon.isEmpty() ? 16 : Integer.parseInt(icon.substring(0, icon.indexOf(' ')));
                            img.setScaleType(ImageView.ScaleType.FIT_CENTER);
                            img.setMaxWidth(px(size)); img.setMaxHeight(px(size));
                            img.setAdjustViewBounds(true);
                            img.setLayoutParams(img.getLayoutParams() == null
                                    ? new ViewGroup.LayoutParams(px(size), px(size)) : sized(img.getLayoutParams(), px(size)));
                            icons.put(id, icon.isEmpty() ? "" : icon);
                            pictures.put(id, true);
                        }
                    }
                }
                break;
                case TITLE: setTitle(text); break;
                case TOAST: android.widget.Toast.makeText(this, text, android.widget.Toast.LENGTH_LONG).show(); break;
                case RICH:
                    rich.put(id, arg);
                    if (v instanceof TextView) ((TextView) v).setTextIsSelectable((arg & 2) != 0);
                    break;
                case CHOOSE_FILES: Files.choose(this, id, text); break;
                case TEXT_FIELD: if (v instanceof CanvasView) ((CanvasView) v).setField(text, arg != 0); break;
                case COPY_TEXT: {
                    android.content.ClipboardManager cm = getSystemService(android.content.ClipboardManager.class);
                    if (cm != null) cm.setPrimaryClip(android.content.ClipData.newPlainText("text", text));
                    break;
                }
                case PASTE_TEXT: {
                    android.content.ClipboardManager cm = getSystemService(android.content.ClipboardManager.class);
                    CharSequence s = null;
                    if (cm != null && cm.hasPrimaryClip() && cm.getPrimaryClip().getItemCount() > 0)
                        s = cm.getPrimaryClip().getItemAt(0).coerceToText(this);
                    final String clip = s == null ? "" : s.toString();
                    final int n = id;
                    main.post(() -> Native.event(n, Native.PASTE_TEXT, clip, 0, 0, 0));
                    break;
                }
                case QUIT: finish(); break;
            }
        } finally {
            syncing = false;
        }
    }

    /** A SeekBar counts whole steps from 0; r is {min, max, step, value}. */
    static void showValue(SeekBar s, double[] r) {
        double step = r[2] > 0 ? r[2] : (r[1] - r[0]) / 100;
        s.setMax((int) Math.max(1, Math.round((r[1] - r[0]) / step)));
        s.setProgress((int) Math.round((r[3] - r[0]) / step));
    }

    /** Spinner reports selections later, from layout, including ones we make: remember which one Nim already knows
     * so only the user's picks go back as events. */
    void select(Spinner s, int id, int index) {
        // A Spinner with choices always shows one; with none chosen it shows the first, which isn't the user's pick.
        shownSelection.put(id, index < 0 && s.getCount() > 0 ? 0 : index);
        if (index >= 0 && index < s.getCount()) s.setSelection(index, false);
    }

    /** Layout params for `v` from its parent's direction and its expand flag: it fills across, and takes the spare
     * room along when expanded. */
    void relayout(View v, int id) {
        if (!(v.getParent() instanceof ViewGroup)) return;
        ViewGroup parent = (ViewGroup) v.getParent();
        boolean grow = Boolean.TRUE.equals(expand.get(id));
        if (splits.containsKey(parent)) {
            // The first pane takes the room the second (a fixed width, no divider on touch screens) leaves.
            boolean first = parent.indexOfChild(v) == 0;
            v.setLayoutParams(first ? new LinearLayout.LayoutParams(0, -1, 1)
                                    : new LinearLayout.LayoutParams(splits.get(parent), -1, 0));
        } else if (overlays.contains(parent)) {
            boolean base = parent.indexOfChild(v) == 0;
            FrameLayout.LayoutParams p = base ? new FrameLayout.LayoutParams(-1, -1) : new FrameLayout.LayoutParams(-2, -2);
            if (!base) p.gravity = Gravity.BOTTOM | Gravity.START;
            v.setLayoutParams(p);
        } else if (parent instanceof LinearLayout) {
            boolean vertical = ((LinearLayout) parent).getOrientation() == LinearLayout.VERTICAL;
            LinearLayout.LayoutParams p = vertical
                    ? new LinearLayout.LayoutParams(-1, grow ? 0 : -2, grow ? 1 : 0)
                    : new LinearLayout.LayoutParams(grow ? 0 : -2, -2, grow ? 1 : 0);
            if (!vertical) {
                // A "top" row (addClass) lines its children up at their tops: a list bullet beside wrapped text.
                int at = views.indexOfValue(parent);
                boolean top = at >= 0 && java.util.Arrays.asList(classes.get(views.keyAt(at), "").split(" ")).contains("top");
                p.gravity = top ? Gravity.TOP : Gravity.CENTER_VERTICAL;
            }
            if (!vertical && v instanceof SurfaceView) p.height = -1;
            if (isSeparator(v)) {
                if (vertical) p.height = Math.max(1, px(1) / 2); else { p.width = Math.max(1, px(1) / 2); p.height = -1; }
                p.setMargins(0, vertical ? px(4) : 0, 0, vertical ? px(4) : 0);
            }
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
                e.setOnKeyListener((x, code, ev) -> {
                    if (ev.getAction() != KeyEvent.ACTION_DOWN) return false;
                    int vk = Keys.windowsCode(code);
                    if (vk == 0) return false;
                    keyHandled = false;
                    Native.event(id, Native.ENTRY_KEY, "", vk, Keys.mods(ev), ev.getUnicodeChar(ev.getMetaState()));
                    return keyHandled;
                });
                e.setOnFocusChangeListener((x, has) -> Native.event(id, Native.FOCUS, "", has ? 1 : 0, 0, 0));
                return e;
            }
            case CHECK: {
                CheckBox c = new CheckBox(this);
                c.setOnCheckedChangeListener((x, on) -> {
                    if (!syncing) Native.event(id, Native.TOGGLE, "", on ? 1 : 0, 0, 0);
                });
                return c;
            }
            case TOGGLE: {
                ToggleButton t = new ToggleButton(this);
                t.setAllCaps(false);
                t.setOnCheckedChangeListener((x, on) -> {
                    if (!syncing) Native.event(id, Native.TOGGLE, "", on ? 1 : 0, 0, 0);
                });
                return t;
            }
            case SLIDER: {
                SeekBar s = new SeekBar(this);
                s.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                    public void onProgressChanged(SeekBar b, int progress, boolean fromUser) {
                        if (!fromUser || syncing) return;
                        double[] r = ranges.get(id, new double[] {0, 1, 0.01, 0});
                        double step = r[2] > 0 ? r[2] : (r[1] - r[0]) / 100;
                        r[3] = Math.min(r[1], r[0] + progress * step);
                        Native.event(id, Native.VALUE, "", (float) r[3], 0, 0);
                    }
                    public void onStartTrackingTouch(SeekBar b) {}
                    public void onStopTrackingTouch(SeekBar b) {}
                });
                return s;
            }
            case DROPDOWN: {
                Spinner s = new Spinner(this);
                s.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
                    public void onItemSelected(AdapterView<?> parent, View view, int position, long rowId) {
                        if (shownSelection.get(id, -1) == position) return;
                        shownSelection.put(id, position);
                        Native.event(id, Native.SELECT, "", position, 0, 0);
                    }
                    public void onNothingSelected(AdapterView<?> parent) {}
                });
                return s;
            }
            case PROGRESS: {
                ProgressBar p = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
                p.setMax(PROGRESS_STEPS);
                return p;
            }
            case ICON_KIND: return new ImageView(this);
            case OVERLAY: {
                FrameLayout f = new FrameLayout(this);
                overlays.add(f);
                return f;
            }
            case SPLIT: {
                LinearLayout l = new LinearLayout(this) {
                    @Override
                    protected void onMeasure(int w, int h) {
                        // On a phone-sized window the second pane, when it shows, takes the whole width: next to it
                        // the first would be too narrow to use.
                        int width = MeasureSpec.getSize(w);
                        if (getChildCount() > 1) {
                            View first = getChildAt(0), second = getChildAt(1);
                            boolean alone = second.getVisibility() == View.VISIBLE && width < px(600);
                            LinearLayout.LayoutParams p = (LinearLayout.LayoutParams) second.getLayoutParams();
                            int want = alone ? width : splits.getOrDefault(this, px(360));
                            if (p.width != want) { p.width = want; second.setLayoutParams(p); }
                            int firstVis = alone ? View.GONE : View.VISIBLE;
                            if (first.getVisibility() != firstVis) first.setVisibility(firstVis);
                        }
                        super.onMeasure(w, h);
                    }
                };
                l.setOrientation(LinearLayout.HORIZONTAL);
                splits.put(l, px(360));
                return l;
            }
            case HSCROLL: {
                android.widget.HorizontalScrollView s = new android.widget.HorizontalScrollView(this);
                s.setHorizontalScrollBarEnabled(false);
                return s;
            }
            case ITEM: {
                LinearLayout l = new LinearLayout(this);
                l.setOrientation(LinearLayout.HORIZONTAL);
                l.setGravity(Gravity.CENTER_VERTICAL);
                l.setClickable(true);
                l.setFocusable(true);
                l.setMinimumHeight(px(40));
                l.setBackground(ripple(0));
                l.setOnClickListener(x -> Native.event(id, Native.CLICK, "", 0, 0, 0));
                l.setOnLongClickListener(x -> { Native.event(id, Native.CONTEXT, "", 0, 0, 0); return true; });
                l.setOnGenericMotionListener((x, ev) -> {
                    if (ev.getActionMasked() == MotionEvent.ACTION_BUTTON_PRESS) {
                        if (ev.getActionButton() == MotionEvent.BUTTON_SECONDARY) {
                            Native.event(id, Native.CONTEXT, "", 0, 0, 0); return true;
                        }
                        if (ev.getActionButton() == MotionEvent.BUTTON_TERTIARY) {
                            Native.event(id, Native.MIDDLE, "", 0, 0, 0); return true;
                        }
                    }
                    return false;
                });
                return l;
            }
            case SEPARATOR: {
                View line = new View(this);
                line.setBackgroundColor(textColor() & 0x30ffffff);
                line.setMinimumHeight(1);
                line.setMinimumWidth(1);
                return line;
            }
            case CANVAS: return new CanvasView(this, id);
        }
        throw new IllegalArgumentException("kind " + kind);
    }

    /** Views at the start of `parent` that aren't Nim's children (an item's icon). */
    static int skip(ViewGroup parent) {
        return parent.getChildCount() > 0 && "nk-item-icon".equals(parent.getChildAt(0).getTag()) ? 1 : 0;
    }

    static boolean isSeparator(View v) { return v.getClass() == View.class; }

    int textColor() {
        android.content.res.TypedArray a = obtainStyledAttributes(new int[] {android.R.attr.textColorPrimary});
        int c = a.getColor(0, 0xff000000);
        a.recycle();
        return c;
    }

    int backgroundColor() {
        android.content.res.TypedArray a = obtainStyledAttributes(new int[] {android.R.attr.colorBackground});
        int c = a.getColor(0, 0xffffffff);
        a.recycle();
        return c;
    }

    int accentColor() {
        android.content.res.TypedArray a = obtainStyledAttributes(new int[] {android.R.attr.colorAccent});
        int c = a.getColor(0, 0xff3367d6);
        a.recycle();
        return c;
    }

    /** A pressed-state ripple over `fill` (0: transparent), with rounded corners. */
    Drawable ripple(int fill) {
        GradientDrawable shape = new GradientDrawable();
        shape.setCornerRadius(px(8));
        shape.setColor(fill);
        GradientDrawable mask = new GradientDrawable();
        mask.setCornerRadius(px(8));
        mask.setColor(0xffffffff);
        return new RippleDrawable(ColorStateList.valueOf(textColor() & 0x30ffffff), shape, mask);
    }

    /** The style names of addClass (src/nimkit/core.nim) that mean something here. */
    void style(View v, int id) {
        java.util.List<String> c = java.util.Arrays.asList(classes.get(id, "").split(" "));
        if (v instanceof TextView && !(v instanceof EditText)) {
            TextView t = (TextView) v;
            boolean button = v instanceof Button;
            t.setTextSize(c.contains("heading") ? 20 : c.contains("small") ? 13 : button ? 14 : 16);
            int face = (c.contains("heading") || c.contains("bold")) ? android.graphics.Typeface.BOLD : 0;
            t.setTypeface(c.contains("mono") ? android.graphics.Typeface.MONOSPACE : android.graphics.Typeface.DEFAULT, face);
            if (c.contains("error")) t.setTextColor(0xffd93025);
            else if (!button) t.setTextColor(textColor());
            t.setAlpha(c.contains("dim") ? 0.6f : 1f);
            if (c.contains("centered") && !button) t.setGravity(Gravity.CENTER);
            if (button) {
                if (c.contains("flat")) {
                    t.setBackground(ripple(0));
                    t.setMinWidth(px(40)); t.setMinimumWidth(px(40)); t.setMinHeight(px(40)); t.setMinimumHeight(px(40));
                    t.setPadding(px(8), px(8), px(8), px(8));
                } else if (c.contains("suggested") || c.contains("destructive")) {
                    t.setBackground(ripple(c.contains("destructive") ? 0xffd93025 : accentColor()));
                    t.setTextColor(0xffffffff);
                    t.setPadding(px(16), px(8), px(16), px(8));
                }
            }
        } else if (v instanceof ImageView) {
            v.setAlpha(c.contains("dim") ? 0.6f : 1f);
        } else if (v instanceof LinearLayout && Boolean.TRUE.equals(v.isClickable())) {
            v.setBackground(ripple(c.contains("selected") ? (textColor() & 0x20ffffff) : 0));
        } else if (c.contains("card") && v instanceof LinearLayout) {
            GradientDrawable g = new GradientDrawable();
            g.setCornerRadius(px(12));
            g.setStroke(Math.max(1, px(1) / 2), textColor() & 0x30ffffff);
            v.setBackground(g);
        }
        String icon = icons.get(id);
        if (icon != null && !icon.isEmpty()) {
            int space = icon.indexOf(' ');
            showIcon(v, id, Integer.parseInt(icon.substring(0, space)), icon.substring(space + 1), true);
        }
    }

    void showIcon(View v, int id, int size, String spec) { showIcon(v, id, size, spec, false); }

    static ViewGroup.LayoutParams sized(ViewGroup.LayoutParams p, int size) {
        p.width = size;
        p.height = size;
        return p;
    }

    /** An icon's glyph, or the icon at the start of a button or item. `spec` is "em pathdata", empty for none. */
    void showIcon(View v, int id, int size, String spec, boolean force) {
        String key = spec.isEmpty() ? "" : size + " " + spec;
        if (!force && key.equals(icons.get(id, ""))) return;
        icons.put(id, key);
        if (Boolean.TRUE.equals(pictures.get(id))) return;   // a picture shows instead (IMAGE)
        java.util.List<String> c = java.util.Arrays.asList(classes.get(id, "").split(" "));
        int color = c.contains("error") ? 0xffd93025
                : c.contains("suggested") || c.contains("destructive") ? 0xffffffff : textColor();
        Drawable d = spec.isEmpty() ? null : new Glyph(spec, px(size), color);
        if (v instanceof ImageView) {
            ((ImageView) v).setImageDrawable(d);
        } else if (v instanceof TextView) {
            TextView t = (TextView) v;
            t.setCompoundDrawablesRelative(d, null, null, null);
            t.setCompoundDrawablePadding(t.getText().length() > 0 ? px(8) : 0);
        } else if (v instanceof LinearLayout) {
            // An item's icon goes first, in a view of its own that isn't one of Nim's children.
            LinearLayout l = (LinearLayout) v;
            View first = l.getChildCount() > 0 ? l.getChildAt(0) : null;
            ImageView img = first instanceof ImageView && "nk-item-icon".equals(first.getTag()) ? (ImageView) first : null;
            if (d == null) { if (img != null) l.removeView(img); return; }
            if (img == null) {
                img = new ImageView(this);
                img.setTag("nk-item-icon");
                l.addView(img, 0);
            }
            img.setImageDrawable(d);
        }
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent ev) {
        if (ev.getActionMasked() == MotionEvent.ACTION_DOWN) {
            int[] at = new int[2];
            content.getLocationInWindow(at);
            touchX = ev.getX() - at[0];
            touchY = ev.getY() - at[1];
        }
        return super.dispatchTouchEvent(ev);
    }

    /** A pop-up menu (MENU): at x, y in `anchor`'s pixels, under `anchor`, or where the screen was last touched. */
    void menu(View anchor, String json) {
        try {
            JSONObject q = new JSONObject(json);
            double x = q.optDouble("x", -1), y = q.optDouble("y", -1);
            float px = touchX, py = touchY;
            int[] at = new int[2], base = new int[2];
            content.getLocationInWindow(base);
            if (anchor != null && anchor.isAttachedToWindow()) {
                anchor.getLocationInWindow(at);
                px = at[0] - base[0] + (x >= 0 ? (float) x : 0);
                py = at[1] - base[1] + (y >= 0 ? (float) y : anchor.getHeight());
            }
            // PopupMenu opens under a view: put a 1-pixel one at the spot.
            View spot = new View(this);
            FrameLayout.LayoutParams p = new FrameLayout.LayoutParams(1, 1);
            p.leftMargin = Math.round(px);
            p.topMargin = Math.round(py);
            content.addView(spot, p);
            PopupMenu m = new PopupMenu(this, spot);
            m.getMenu().setGroupDividerEnabled(true);
            fill(m.getMenu(), q.getJSONArray("items"), new int[] {0});
            m.setOnMenuItemClickListener(item -> {
                Native.event(item.getItemId(), Native.MENU_ACTION, "", 0, 0, 0);
                return true;
            });
            m.setOnDismissListener(x2 -> content.post(() -> content.removeView(spot)));
            spot.post(m::show);
        } catch (Exception e) {
            Log.w("nimkit", "menu", e);
        }
    }

    void fill(android.view.Menu menu, JSONArray items, int[] group) throws Exception {
        for (int i = 0; i < items.length(); i++) {
            JSONObject it = items.getJSONObject(i);
            if (it.optBoolean("separator")) { group[0]++; continue; }
            String label = it.optString("label");
            JSONArray sub = it.optJSONArray("submenu");
            if (sub != null) {
                android.view.SubMenu s = menu.addSubMenu(group[0], it.getInt("id"), i, label);
                fill(s, sub, new int[] {0});
                continue;
            }
            android.view.MenuItem m = menu.add(group[0], it.getInt("id"), i, label);
            m.setEnabled(it.optBoolean("enabled", true));
            int checked = it.optInt("checked", -1);
            if (checked >= 0) { m.setCheckable(true); m.setChecked(checked == 1); }
        }
    }

    /** A modal dialog (DIALOG): the Nim content view and up to three buttons, reported by index. */
    void dialog(int n, String json) {
        try {
            JSONObject q = new JSONObject(json);
            AlertDialog.Builder b = new AlertDialog.Builder(this);
            if (!q.optString("title").isEmpty()) b.setTitle(q.optString("title"));
            View body = views.get(q.optInt("content"));
            if (body != null) {
                if (body.getParent() != null) ((ViewGroup) body.getParent()).removeView(body);
                FrameLayout frame = new FrameLayout(this);
                frame.setPadding(px(24), px(8), px(24), 0);
                frame.addView(body, new FrameLayout.LayoutParams(-1, -2));
                b.setView(frame);
            }
            JSONArray buttons = q.getJSONArray("buttons");
            int count = Math.min(buttons.length(), 3);
            int[] which = new int[count];   // AlertDialog's button -> our index
            for (int i = 0; i < count; i++) {
                int index = buttons.length() - count + i;
                String label = buttons.getString(index);
                android.content.DialogInterface.OnClickListener l =
                        (d, w) -> Native.event(n, Native.DIALOG_RESULT, "", index, 0, 0);
                if (i == count - 1) { b.setPositiveButton(label, l); which[i] = AlertDialog.BUTTON_POSITIVE; }
                else if (i == 0) { b.setNegativeButton(label, l); which[i] = AlertDialog.BUTTON_NEGATIVE; }
                else { b.setNeutralButton(label, l); which[i] = AlertDialog.BUTTON_NEUTRAL; }
            }
            b.setOnDismissListener(d -> {
                if (dialogs.get(n) != null) {
                    dialogs.remove(n);
                    Native.event(n, Native.DIALOG_RESULT, "", -1, 0, 0);
                }
            });
            AlertDialog d = b.create();
            dialogs.put(n, d);
            d.show();
            int destructive = q.optInt("destructive", -1);
            for (int i = 0; i < count; i++)
                if (buttons.length() - count + i == destructive) {
                    Button btn = d.getButton(which[i]);
                    if (btn != null) btn.setTextColor(0xffd93025);
                }
        } catch (Exception e) {
            Log.w("nimkit", "dialog", e);
        }
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
