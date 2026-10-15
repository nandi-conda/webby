package dev.webby.nim;

import android.app.AlertDialog;
import android.text.Html;
import android.text.Spannable;
import android.text.SpannableStringBuilder;
import android.text.method.LinkMovementMethod;
import android.text.style.ClickableSpan;
import android.text.style.URLSpan;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Summarize (summarize.dart's panel): the page's summary from DeepSeek as it streams in, follow-up questions under
 * it, and the API key dialog. features/summarize.nim does the work and sends "summary" events with its state.
 */
final class SummaryScreen {
    private SummaryScreen() {}

    private static final String ANCHOR = "webby-anchor:";
    private static Screen screen;
    private static EditText field;
    private static View send;
    private static int lastQuestions = -1;

    /** The menu item: asks for the key first if there is none. */
    static void open(MainActivity a) {
        JSONObject k = Native.obj("summarize.key");
        if (k != null && !k.optBoolean("hasKey")) {
            settings(a, () -> open(a));
            return;
        }
        if (screen == null) build(a);
        Native.cmd("summarize.start", "fresh", false);
    }

    private static void build(MainActivity a) {
        Screen s = new Screen(a, "Summary");
        s.addAction(R.drawable.ic_copy, "Copy summary", v -> {
            Object t = s.dialog.getWindow().getDecorView().getTag();
            if (t instanceof String && !((String) t).isEmpty()) {
                a.copy((String) t);
            }
        });
        s.addAction(R.drawable.ic_refresh, "Summarize again", v -> Native.cmd("summarize.start", "fresh", true));
        s.addAction(R.drawable.ic_tune, "Summarize settings", v -> settings(a, null));

        LinearLayout bottom = new LinearLayout(a);
        bottom.setGravity(Gravity.CENTER_VERTICAL);
        bottom.setPadding(s.dp(12), s.dp(6), s.dp(4), s.dp(8));
        EditText f = new EditText(a);
        f.setHint("Ask about this page");
        f.setTextColor(Ui.foreground);
        f.setHintTextColor(Ui.dim);
        f.setBackground(Ui.pill(a));
        f.setPadding(s.dp(16), s.dp(10), s.dp(16), s.dp(10));
        f.setSingleLine(true);
        f.setImeOptions(EditorInfo.IME_ACTION_SEND);
        f.setOnEditorActionListener((v, id, e) -> {
            ask();
            return true;
        });
        bottom.addView(f, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        View sendButton = Ui.iconButton(a, R.drawable.ic_send, "Ask", v -> ask());
        bottom.addView(sendButton);
        s.addBottom(bottom);
        s.dialog.setOnDismissListener(d -> {
            if (screen == s) {
                screen = null;
                field = null;
                send = null;
                lastQuestions = -1;
                Native.cmd("summarize.close");
            }
        });
        screen = s;
        field = f;
        send = sendButton;
        s.show();
    }

    private static void ask() {
        if (field == null) return;
        String q = field.getText().toString().trim();
        if (q.isEmpty() || !send.isEnabled()) return;
        field.setText("");
        Native.cmd("summarize.ask", "text", q);
    }

    /** A "summary" event: the whole state of the summary shown. */
    static void update(MainActivity a, JSONObject e) {
        Screen s = screen;
        if (s == null) return;
        if (!e.optBoolean("open")) {
            s.dismiss();
            return;
        }
        s.setTitle(e.optBoolean("selection") ? "Summary of selection" : "Summary");
        s.dialog.getWindow().getDecorView().setTag(e.optString("text"));
        boolean canAsk = e.optBoolean("canAsk");
        field.setEnabled(e.optBoolean("hasKey") && !e.optString("text").trim().isEmpty() && !e.optBoolean("running"));
        send.setEnabled(canAsk);
        send.setAlpha(canAsk ? 1f : 0.4f);

        List<View> rows = new ArrayList<>();
        TextView title = Ui.text(a, e.optString("title"), 17, Ui.foreground);
        title.setSingleLine(false);
        title.setTypeface(null, android.graphics.Typeface.BOLD);
        rows.add(pad(s, title, 8));
        if (!e.optString("url").isEmpty()) rows.add(pad(s, Ui.text(a, e.optString("url"), 13, Ui.dim), 2));
        if (!e.optString("saved").isEmpty()) {
            TextView saved = Ui.text(a, e.optString("saved"), 13, Ui.dim);
            saved.setSingleLine(false);
            rows.add(pad(s, saved, 6));
        }
        if (!e.optString("error").isEmpty()) {
            rows.add(pad(s, wrapped(a, e.optString("error"), 0xffd32f2f), 12));
        } else if (e.optString("html").isEmpty() && e.optBoolean("running")) {
            rows.add(pad(s, wrapped(a, "Reading the page…", Ui.dim), 12));
        } else {
            rows.add(pad(s, markdown(a, s, e.optString("html")), 12));
        }
        JSONArray qs = e.optJSONArray("questions");
        for (int i = 0; qs != null && i < qs.length(); i++) {
            JSONObject q = qs.optJSONObject(i);
            TextView qt = wrapped(a, q.optString("question"), Ui.foreground);
            qt.setTypeface(null, android.graphics.Typeface.BOLD);
            qt.setBackground(Ui.pill(a));
            qt.setPadding(s.dp(12), s.dp(8), s.dp(12), s.dp(8));
            rows.add(pad(s, qt, 16));
            if (!q.optString("html").isEmpty()) rows.add(pad(s, markdown(a, s, q.optString("html")), 8));
            else if (q.optBoolean("running")) rows.add(pad(s, wrapped(a, "Thinking…", Ui.dim), 8));
            if (!q.optString("error").isEmpty()) rows.add(pad(s, wrapped(a, q.optString("error"), 0xffd32f2f), 8));
        }
        if (e.optBoolean("busy")) {
            View stop = Ui.row(a, R.drawable.ic_close, "Stop", null, null);
            stop.setOnClickListener(v -> Native.cmd("summarize.stop"));
            rows.add(stop);
        }
        View spacer = new View(a);
        spacer.setMinimumHeight(s.dp(24));
        rows.add(spacer);
        s.setRows(rows);
        int n = qs == null ? 0 : qs.length();
        if (n != lastQuestions) {
            if (n > 0) s.scrollToEnd();
            lastQuestions = n;
        }
    }

    private static View pad(Screen s, View v, int top) {
        LinearLayout box = new LinearLayout(s.activity);
        box.setPadding(s.dp(16), s.dp(top), s.dp(16), 0);
        box.addView(v, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return box;
    }

    private static TextView wrapped(MainActivity a, String text, int color) {
        TextView t = Ui.text(a, text, 15, color);
        t.setSingleLine(false);
        return t;
    }

    /** Rendered markdown (HTML from markdown.nim) with its links: page anchors jump to the words, others open. */
    private static TextView markdown(MainActivity a, Screen s, String html) {
        TextView t = wrapped(a, "", Ui.foreground);
        t.setLineSpacing(0, 1.3f);
        t.setTextIsSelectable(true);
        SpannableStringBuilder b = new SpannableStringBuilder(Html.fromHtml(html, Html.FROM_HTML_MODE_COMPACT));
        while (b.length() > 0 && Character.isWhitespace(b.charAt(b.length() - 1))) b.delete(b.length() - 1, b.length());
        for (URLSpan u : b.getSpans(0, b.length(), URLSpan.class)) {
            String url = u.getURL();
            int start = b.getSpanStart(u), end = b.getSpanEnd(u);
            b.removeSpan(u);
            b.setSpan(new ClickableSpan() {
                @Override
                public void onClick(View v) {
                    if (url.startsWith(ANCHOR)) {
                        if (Boolean.TRUE.equals(Native.cmd("summarize.jump", "words", url.substring(ANCHOR.length())))) {
                            s.dismiss();
                        } else {
                            Ui.toast(a, "The tab shows another page now");
                        }
                    } else {
                        s.dismiss();
                        a.openUrl(url);
                    }
                }
            }, start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        t.setText(b);
        t.setMovementMethod(LinkMovementMethod.getInstance());
        t.setLinkTextColor(Ui.accent);
        return t;
    }

    /** The DeepSeek API key: entered, replaced or removed; kept in the vault, synced unless unticked. */
    static void settings(MainActivity a, Runnable then) {
        JSONObject k = Native.obj("summarize.key");
        if (k == null) return;
        if (!k.optBoolean("vault")) {
            Ui.toast(a, "Unlock the password vault first (Passwords and passkeys)");
            return;
        }
        boolean hasKey = k.optBoolean("hasKey");
        LinearLayout form = Ui.form(a);
        form.addView(Ui.label(a, hasKey ? "New API key (one is saved)" : "DeepSeek API key"));
        EditText key = Ui.field(a, "", "sk-…");
        key.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD);
        form.addView(key);
        CheckBox show = new CheckBox(a);
        show.setText("Show key");
        show.setTextColor(Ui.foreground);
        show.setOnCheckedChangeListener((v, on) -> {
            key.setInputType(android.text.InputType.TYPE_CLASS_TEXT
                | (on ? android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD : android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD));
            key.setSelection(key.getText().length());
        });
        form.addView(show);
        CheckBox sync = new CheckBox(a);
        sync.setText("Sync this key to my other devices");
        sync.setTextColor(Ui.foreground);
        sync.setChecked(k.optBoolean("sync", true));
        form.addView(sync);
        TextView info = Ui.text(a, "Create a key at platform.deepseek.com. It is kept encrypted in the password "
            + "vault; when it syncs, it travels end-to-end encrypted like your passwords. Summarize sends the page's "
            + "text to DeepSeek.", 13, Ui.dim);
        info.setSingleLine(false);
        form.addView(info);
        AlertDialog.Builder b = new AlertDialog.Builder(a).setTitle("Summarize with DeepSeek").setView(form)
            .setPositiveButton("Save", (d, w) -> {
                String v = key.getText().toString().trim();
                // With a key saved, Save with the field empty just changes whether it syncs.
                if (v.isEmpty() && !hasKey) return;
                JSONObject r = v.isEmpty() ? Native.obj("summarize.key", "sync", sync.isChecked())
                    : Native.obj("summarize.key", "key", v, "sync", sync.isChecked());
                if (r != null && !r.optString("error").isEmpty()) Ui.toast(a, r.optString("error"));
                else if (then != null) then.run();
            })
            .setNegativeButton("Cancel", null);
        if (hasKey) b.setNeutralButton("Remove key",
            (d, w) -> Native.cmd("summarize.key", "key", "", "sync", sync.isChecked()));
        b.show();
    }
}
