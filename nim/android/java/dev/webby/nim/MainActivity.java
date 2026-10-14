package dev.webby.nim;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.text.TextUtils;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.BaseAdapter;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageButton;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.PopupMenu;
import android.widget.ProgressBar;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * The Android shell of webby-nim: a toolbar (back, URL field, tabs, reload, menu) over the page. Everything behind the
 * widgets is libwebbynim.so; it reports changes through the static on* methods below (on the main thread).
 */
public final class MainActivity extends Activity {
    private static final String TAG = "webby-nim";
    private static MainActivity current;
    private static boolean started;
    private static String pendingUrl;

    private PageView page;
    private EditText urlField;
    private ImageButton backButton, reloadButton;
    private TextView tabsButton;
    private ProgressBar progress;
    private boolean dark;
    private int foreground, background, fieldBackground;

    private JSONObject state = new JSONObject();
    private final List<JSONObject> tabs = new ArrayList<>();
    private int active = -1;
    private AlertDialog tabsDialog;
    private TabsAdapter tabsAdapter;
    private Omnibox omnibox;
    private LinearLayout passwordBar;

    interface ResultCallback {
        void done(int resultCode, Intent data);
    }

    private final android.util.SparseArray<ResultCallback> results = new android.util.SparseArray<>();
    private int nextRequest = 1;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        current = this;
        try {
            LadybirdRuntime.setEnvironment(this);
        } catch (Exception e) {
            Log.e(TAG, "environment", e);
        }
        dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        Ui.setDark(dark);
        foreground = Ui.foreground;
        background = Ui.background;
        fieldBackground = Ui.fieldBackground;
        getWindow().setStatusBarColor(background);
        getWindow().setNavigationBarColor(background);
        if (!dark) {
            getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        }
        buildViews();
        if (!(savedInstanceState != null || (getIntent().getFlags() & Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0)) {
            pendingUrl = viewedUrl(getIntent());
        }
        if (started) {
            Native.init(MainActivity.class, "", "", density(), dark ? 1 : 0);
            Native.colorScheme(dark ? 2 : 1);
            return;
        }
        Handler main = new Handler(Looper.getMainLooper());
        new Thread(() -> {
            try {
                String prefix = LadybirdRuntime.prepare(this);
                main.post(() -> start(prefix));
            } catch (Exception e) {
                Log.e(TAG, "prepare", e);
                main.post(() -> fatal("Could not set up Ladybird: " + e));
            }
        }).start();
    }

    private void start(String prefix) {
        Log.i(TAG, "Ladybird prepared at " + prefix);
        String profile = getFilesDir().getPath() + "/profile";
        int r = Native.init(MainActivity.class, prefix, profile, density(), dark ? 1 : 0);
        if (r != 0) {
            fatal("Ladybird did not start (" + r + ")");
            return;
        }
        started = true;
    }

    private void fatal(String message) {
        new AlertDialog.Builder(this).setMessage(message).setPositiveButton("OK", null).show();
    }

    private float density() {
        return getResources().getDisplayMetrics().density;
    }

    private int dp(float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
    }

    // ---- Views

    private ImageButton iconButton(int icon, String description, View.OnClickListener click) {
        ImageButton b = new ImageButton(this);
        b.setImageResource(icon);
        b.setColorFilter(foreground);
        b.setContentDescription(description);
        TypedValue ripple = new TypedValue();
        getTheme().resolveAttribute(android.R.attr.selectableItemBackgroundBorderless, ripple, true);
        b.setBackgroundResource(ripple.resourceId);
        b.setOnClickListener(click);
        b.setLayoutParams(new LinearLayout.LayoutParams(dp(44), dp(44)));
        return b;
    }

    private void buildViews() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(background);

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(dp(4), dp(4), dp(4), dp(4));

        backButton = iconButton(R.drawable.ic_arrow_back, "Back", v -> Native.nav(Native.BACK));
        bar.addView(backButton);

        urlField = new EditText(this);
        urlField.setSingleLine(true);
        urlField.setHint("Search or enter address");
        urlField.setTextColor(foreground);
        urlField.setHintTextColor((foreground & 0x00ffffff) | 0x88000000);
        urlField.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        urlField.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        urlField.setImeOptions(EditorInfo.IME_ACTION_GO | EditorInfo.IME_FLAG_NO_EXTRACT_UI);
        urlField.setSelectAllOnFocus(true);
        urlField.setEllipsize(TextUtils.TruncateAt.END);
        GradientDrawable pill = new GradientDrawable();
        pill.setColor(fieldBackground);
        pill.setCornerRadius(dp(22));
        urlField.setBackground(pill);
        urlField.setPadding(dp(16), 0, dp(16), 0);
        LinearLayout.LayoutParams fieldParams = new LinearLayout.LayoutParams(0, dp(44), 1);
        fieldParams.setMargins(dp(4), 0, dp(4), 0);
        urlField.setLayoutParams(fieldParams);
        urlField.setOnEditorActionListener((v, action, event) -> {
            String text = urlField.getText().toString().trim();
            if (text.isEmpty()) return true;
            Native.load(text);
            leaveUrlField();
            return true;
        });
        urlField.setOnFocusChangeListener((v, focused) -> {
            if (!focused) {
                omnibox.hide();
                showUrl();
            }
        });
        bar.addView(urlField);

        tabsButton = new TextView(this);
        tabsButton.setGravity(Gravity.CENTER);
        tabsButton.setTextColor(foreground);
        tabsButton.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        tabsButton.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);
        GradientDrawable box = new GradientDrawable();
        box.setStroke(dp(2), foreground);
        box.setCornerRadius(dp(4));
        tabsButton.setBackground(box);
        LinearLayout.LayoutParams tabsParams = new LinearLayout.LayoutParams(dp(24), dp(24));
        tabsParams.setMargins(dp(10), 0, dp(10), 0);
        tabsButton.setLayoutParams(tabsParams);
        tabsButton.setContentDescription("Tabs");
        tabsButton.setOnClickListener(v -> showTabs());
        bar.addView(tabsButton);

        reloadButton = iconButton(R.drawable.ic_refresh, "Reload", v -> Native.nav(Native.RELOAD_OR_STOP));
        bar.addView(reloadButton);
        bar.addView(iconButton(R.drawable.ic_more_vert, "More", this::showMenu));
        root.addView(bar);

        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setIndeterminate(true);
        progress.setVisibility(View.INVISIBLE);
        root.addView(progress, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3)));

        passwordBar = new LinearLayout(this);
        passwordBar.setOrientation(LinearLayout.VERTICAL);
        passwordBar.setPadding(dp(16), dp(8), dp(8), dp(4));
        passwordBar.setBackgroundColor(fieldBackground);
        passwordBar.setVisibility(View.GONE);
        root.addView(passwordBar);

        page = new PageView(this);
        FrameLayout pageFrame = new FrameLayout(this);
        pageFrame.addView(page);
        omnibox = new Omnibox(this, urlField, pageFrame);
        root.addView(pageFrame, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        setContentView(root);
        page.requestFocus();
    }

    private void hideKeyboard(View v) {
        getSystemService(InputMethodManager.class).hideSoftInputFromWindow(v.getWindowToken(), 0);
    }

    private void showUrl() {
        if (!urlField.hasFocus()) omnibox.setText(state.optString("url"));
    }

    /** Back to the page after the URL field was used. */
    void leaveUrlField() {
        omnibox.hide();
        urlField.clearFocus();
        hideKeyboard(urlField);
        page.requestFocus();
    }

    /** startActivityForResult with a callback; false if nothing can handle the intent. */
    boolean startForResult(Intent intent, ResultCallback callback) {
        int code = nextRequest++;
        results.put(code, callback);
        try {
            startActivityForResult(intent, code);
            return true;
        } catch (android.content.ActivityNotFoundException e) {
            results.remove(code);
            Ui.toast(this, "No app can do that");
            return false;
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        ResultCallback cb = results.get(requestCode);
        results.remove(requestCode);
        if (cb != null) cb.done(resultCode, data);
    }

    void importBookmarks(Runnable done) {
        Files.readText(this, "text/html", html -> {
            JSONObject r = Native.obj("bookmarks.importHtml", "html", html);
            int n = r == null ? 0 : r.optInt("count");
            Ui.toast(this, n == 1 ? "Imported 1 bookmark" : "Imported " + n + " bookmarks");
            if (done != null) done.run();
        });
    }

    void exportBookmarks() {
        JSONObject r = Native.obj("bookmarks.exportHtml");
        if (r != null) Files.writeText(this, "bookmarks.html", "text/html", r.optString("html"));
    }

    private void showMenu(View anchor) {
        PopupMenu menu = new PopupMenu(this, anchor);
        boolean onPage = !state.optString("url").isEmpty();
        menu.getMenu().add(0, 1, 0, "New tab");
        menu.getMenu().add(0, 2, 0, "Forward").setEnabled(state.optBoolean("canForward"));
        menu.getMenu().add(0, 6, 0, state.optBoolean("bookmarked") ? "Edit bookmark" : "Bookmark this page").setEnabled(onPage);
        menu.getMenu().add(0, 7, 0, "Bookmarks");
        menu.getMenu().add(0, 8, 0, "History");
        menu.getMenu().add(0, 10, 0, "Passwords and passkeys");
        menu.getMenu().add(0, 3, 0, "Share").setEnabled(onPage);
        menu.getMenu().add(0, 4, 0, "Copy link").setEnabled(onPage);
        menu.getMenu().add(0, 9, 0, "Clear browsing data");
        menu.getMenu().add(0, 5, 0, "Close tab");
        menu.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case 1: newTab(); break;
                case 2: Native.nav(Native.FORWARD); break;
                case 3: share(state.optString("url")); break;
                case 4: copy(state.optString("url")); break;
                case 5: if (active >= 0) Native.closeTab(active); break;
                case 6: BookmarksScreen.bookmarkPage(this); break;
                case 7: BookmarksScreen.show(this); break;
                case 8: HistoryScreen.show(this); break;
                case 9: HistoryScreen.clearBrowsingData(this, null); break;
                case 10: Passwords.show(this); break;
            }
            return true;
        });
        menu.show();
    }

    private void newTab() {
        Native.newTab("", true);
        urlField.requestFocus();
        omnibox.setText("");
        getSystemService(InputMethodManager.class).showSoftInput(urlField, 0);
    }

    JSONObject state() {
        return state;
    }

    /** Opens a page from History, Bookmarks and the like: in this tab when it's blank, else in a new one. */
    void openUrl(String url) {
        if (state.optString("url").isEmpty()) Native.load(url);
        else Native.newTab(url, true);
    }

    void openInNewTab(String url, boolean focus) {
        if (focus) Native.newTab(url, true);
        else Native.contextAction("openInNewTab", url);
    }

    /** A long-press menu for a link in a list: open in a new tab, copy, share, and one extra action. */
    void linkMenu(String url, Runnable extra, String extraLabel) {
        List<String> labels = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        labels.add("Open in new tab"); actions.add(() -> openInNewTab(url, false));
        labels.add("Copy link"); actions.add(() -> copy(url));
        labels.add("Share"); actions.add(() -> share(url));
        if (extra != null) { labels.add(extraLabel); actions.add(extra); }
        new AlertDialog.Builder(this).setTitle(url)
            .setItems(labels.toArray(new String[0]), (d, i) -> actions.get(i).run()).show();
    }

    void share(String url) {
        if (url.isEmpty()) return;
        Intent send = new Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, url);
        startActivity(Intent.createChooser(send, null));
    }

    void copy(String text) {
        getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("webby", text));
    }

    // ---- Tabs

    private final class TabsAdapter extends BaseAdapter {
        @Override
        public int getCount() {
            return tabs.size();
        }

        @Override
        public Object getItem(int i) {
            return tabs.get(i);
        }

        @Override
        public long getItemId(int i) {
            return tabs.get(i).optLong("id");
        }

        @Override
        public View getView(int i, View convert, ViewGroup parent) {
            JSONObject tab = tabs.get(i);
            LinearLayout row = new LinearLayout(MainActivity.this);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(dp(16), dp(4), dp(4), dp(4));
            if (i == active) row.setBackgroundColor(fieldBackground);
            LinearLayout text = new LinearLayout(MainActivity.this);
            text.setOrientation(LinearLayout.VERTICAL);
            TextView title = new TextView(MainActivity.this);
            String t = tab.optString("title");
            title.setText(t.isEmpty() ? tab.optString("url") : t);
            title.setSingleLine(true);
            title.setEllipsize(TextUtils.TruncateAt.END);
            title.setTextColor(foreground);
            title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
            TextView url = new TextView(MainActivity.this);
            url.setText(tab.optString("url"));
            url.setSingleLine(true);
            url.setEllipsize(TextUtils.TruncateAt.END);
            url.setTextColor((foreground & 0x00ffffff) | 0x99000000);
            url.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            text.addView(title);
            text.addView(url);
            row.addView(text, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            final int index = i;
            row.addView(iconButton(R.drawable.ic_close, "Close tab", v -> Native.closeTab(index)));
            row.setOnClickListener(v -> {
                Native.selectTab(index);
                if (tabsDialog != null) tabsDialog.dismiss();
            });
            return row;
        }
    }

    private void showTabs() {
        tabsAdapter = new TabsAdapter();
        ListView list = new ListView(this);
        list.setAdapter(tabsAdapter);
        list.setDivider(null);
        tabsDialog = new AlertDialog.Builder(this)
            .setTitle(tabs.size() == 1 ? "1 tab" : tabs.size() + " tabs")
            .setView(list)
            .setPositiveButton("New tab", (d, w) -> newTab())
            .setNegativeButton("Close", null)
            .create();
        tabsDialog.setOnDismissListener(d -> {
            tabsDialog = null;
            tabsAdapter = null;
        });
        tabsDialog.show();
        if (active >= 0) list.setSelection(active);
    }

    // ---- From libwebbynim.so

    static void onState(String json) {
        MainActivity a = current;
        if (a == null) return;
        try {
            a.applyState(new JSONObject(json));
        } catch (JSONException e) {
            Log.e(TAG, "state", e);
        }
    }

    private void applyState(JSONObject s) throws JSONException {
        state = s;
        tabs.clear();
        JSONArray list = s.getJSONArray("tabs");
        for (int i = 0; i < list.length(); i++) tabs.add(list.getJSONObject(i));
        active = s.getInt("active");
        tabsButton.setText(tabs.size() > 99 ? ":D" : String.valueOf(tabs.size()));
        backButton.setEnabled(s.optBoolean("canBack"));
        backButton.setAlpha(s.optBoolean("canBack") ? 1f : 0.38f);
        boolean loading = s.optBoolean("loading");
        reloadButton.setImageResource(loading ? R.drawable.ic_close : R.drawable.ic_refresh);
        reloadButton.setContentDescription(loading ? "Stop" : "Reload");
        progress.setVisibility(loading ? View.VISIBLE : View.INVISIBLE);
        showUrl();
        if (tabsDialog != null) {
            tabsDialog.setTitle(tabs.size() == 1 ? "1 tab" : tabs.size() + " tabs");
            tabsAdapter.notifyDataSetChanged();
        }
        // A link the app was opened with waits for the saved tabs, or restoring them would switch away from it.
        if (pendingUrl != null && s.optBoolean("ready")) {
            String url = pendingUrl;
            pendingUrl = null;
            Native.newTab(url, true);
        }
    }

    /** Features' events: {"event": name, ...}. */
    static void onEvent(String json) {
        MainActivity a = current;
        if (a == null) return;
        try {
            JSONObject e = new JSONObject(json);
            switch (e.optString("event")) {
                case "filePicker": Files.pick(a, e); break;
                case "passwordOffer": Passwords.showOffer(a, a.passwordBar, e); break;
                case "passkey": Passwords.passkey(a, e); break;
                default: Log.w(TAG, "unknown event " + e.optString("event"));
            }
        } catch (JSONException ex) {
            Log.e(TAG, "event", ex);
        }
    }

    /** The vault key (src/features/passwords/keyring.nim): "" when none is saved, null when the Keystore failed. */
    static String keystoreGet(String profile) {
        MainActivity a = current;
        return a == null ? null : Passwords.keystoreGet(a, profile);
    }

    static String keystorePut(String json) {
        MainActivity a = current;
        return a == null ? null : Passwords.keystorePut(a, json);
    }

    static void onIme(String json) {
        MainActivity a = current;
        if (a == null) return;
        JSONObject field = null;
        if (!json.isEmpty()) {
            try {
                field = new JSONObject(json);
            } catch (JSONException e) {
                Log.e(TAG, "ime", e);
            }
        }
        a.page.setField(field);
    }

    static void onClipboard(String text) {
        MainActivity a = current;
        if (a != null) a.copy(text);
    }

    /** Hands the system clipboard to the page before a paste (Ctrl+V), or pastes into the long-pressed field. */
    static void pasteFromClipboard(boolean intoField) {
        MainActivity a = current;
        if (a == null) return;
        ClipData clip = a.getSystemService(ClipboardManager.class).getPrimaryClip();
        String text = clip != null && clip.getItemCount() > 0 ? String.valueOf(clip.getItemAt(0).coerceToText(a)) : "";
        if (intoField) Native.paste(text);
        else Native.contextAction("setClipboard", text);
    }

    static void onDialog(String json) {
        MainActivity a = current;
        if (a == null) return;
        try {
            a.showDialog(new JSONObject(json));
        } catch (JSONException e) {
            Log.e(TAG, "dialog", e);
        }
    }

    private void showDialog(JSONObject d) {
        int tab = d.optInt("tab");
        long id = d.optLong("id");
        String type = d.optString("type");
        AlertDialog.Builder b = new AlertDialog.Builder(this).setMessage(d.optString("message")).setCancelable(false);
        EditText input = null;
        if (type.equals("prompt")) {
            input = new EditText(this);
            input.setText(d.optString("default"));
            FrameLayout frame = new FrameLayout(this);
            frame.setPadding(dp(20), 0, dp(20), 0);
            frame.addView(input);
            b.setView(frame);
        }
        final EditText field = input;
        b.setPositiveButton("OK", (x, w) -> Native.dialogRespond(tab, id, true, field != null ? field.getText().toString() : ""));
        if (!type.equals("alert")) b.setNegativeButton("Cancel", (x, w) -> Native.dialogRespond(tab, id, false, ""));
        b.show();
    }

    static void onContextMenu(String json) {
        MainActivity a = current;
        if (a == null) return;
        try {
            a.showContextMenu(new JSONObject(json));
        } catch (JSONException e) {
            Log.e(TAG, "menu", e);
        }
    }

    private void showContextMenu(JSONObject m) {
        String link = m.optString("link"), image = m.optString("image"), selection = m.optString("selection");
        boolean editable = m.optBoolean("editable"), password = m.optBoolean("password");
        List<String> labels = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        if (isWebUrl(link)) {
            labels.add("Open in new tab"); actions.add(() -> Native.contextAction("openInNewTab", link));
            labels.add("Copy link"); actions.add(() -> copy(link));
            labels.add("Share link"); actions.add(() -> share(link));
        }
        if (isWebUrl(image)) {
            labels.add("Open image in new tab"); actions.add(() -> Native.contextAction("openInNewTab", image));
            labels.add("Copy image address"); actions.add(() -> copy(image));
        }
        if (!selection.isEmpty() && !password) {
            labels.add("Copy"); actions.add(() -> copy(selection));
            if (editable) { labels.add("Cut"); actions.add(() -> { copy(selection); Native.contextAction("cut", ""); }); }
        }
        if (editable) {
            labels.add("Paste"); actions.add(() -> pasteFromClipboard(true));
        }
        labels.add("Select all"); actions.add(() -> Native.contextAction("selectAll", ""));
        String title = !link.isEmpty() ? link : !image.isEmpty() ? image : null;
        AlertDialog.Builder b = new AlertDialog.Builder(this);
        if (title != null) b.setTitle(title);
        b.setItems(labels.toArray(new String[0]), (d, i) -> actions.get(i).run());
        b.show();
    }

    private static boolean isWebUrl(String url) {
        return url.startsWith("http://") || url.startsWith("https://") || url.startsWith("data:")
            || url.startsWith("file:") || url.startsWith("about:");
    }

    // ---- Activity

    private static String viewedUrl(Intent intent) {
        return intent != null && Intent.ACTION_VIEW.equals(intent.getAction()) ? intent.getDataString() : null;
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        String url = viewedUrl(intent);
        if (url == null) return;
        if (started && state.optBoolean("ready")) Native.newTab(url, true);
        else pendingUrl = url;
    }

    @Override
    public void onBackPressed() {
        if (state.optBoolean("canBack")) Native.nav(Native.BACK);
        else moveTaskToBack(true);
    }

    @Override
    protected void onResume() {
        super.onResume();
        Native.visible(true);
    }

    @Override
    protected void onPause() {
        super.onPause();
        Native.visible(false);
    }

    @Override
    public void onTrimMemory(int level) {
        super.onTrimMemory(level);
        Native.trimMemory(level);
    }

    @Override
    public void onConfigurationChanged(Configuration config) {
        super.onConfigurationChanged(config);
        boolean nowDark = (config.uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        if (nowDark != dark) recreate();
    }

    @Override
    protected void onDestroy() {
        if (current == this) current = null;
        super.onDestroy();
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        // Ctrl+L / Ctrl+T / Ctrl+W on a hardware keyboard.
        if (event.getAction() == KeyEvent.ACTION_DOWN && event.isCtrlPressed()) {
            switch (event.getKeyCode()) {
                case KeyEvent.KEYCODE_L: urlField.requestFocus(); return true;
                case KeyEvent.KEYCODE_T: newTab(); return true;
                case KeyEvent.KEYCODE_W: if (active >= 0) Native.closeTab(active); return true;
            }
        }
        return super.dispatchKeyEvent(event);
    }
}
