package dev.webby.nim;

import android.app.Activity;
import android.content.Context;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;

/** Find in page (⋮ > Find in page): a bar above the page with the query, "n of m", previous/next and close. The
 * search runs in libwebbynim.so (features/find.nim); its result comes back in the state as "find". */
final class FindBar {
    private FindBar() {}

    private static LinearLayout bar;
    private static EditText query;
    private static TextView count;

    static boolean showing() {
        return bar != null && bar.getParent() != null;
    }

    static void show(Activity a) {
        if (!showing()) {
            // The window's root: toolbar, bars, then the page last; the find bar goes right above the page.
            ViewGroup root = (ViewGroup) ((ViewGroup) a.findViewById(android.R.id.content)).getChildAt(0);
            root.addView(build(a), root.getChildCount() - 1);
            // Starts the search (empty for now), so the state carries "find" while the bar shows.
            Native.cmd("find.find", "query", "");
        }
        query.requestFocus();
        query.selectAll();
        InputMethodManager imm = (InputMethodManager) a.getSystemService(Context.INPUT_METHOD_SERVICE);
        imm.showSoftInput(query, InputMethodManager.SHOW_IMPLICIT);
    }

    static void close() {
        if (!showing()) return;
        InputMethodManager imm = (InputMethodManager) bar.getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        imm.hideSoftInputFromWindow(query.getWindowToken(), 0);
        ((ViewGroup) bar.getParent()).removeView(bar);
        Native.cmd("find.end");
    }

    /** The state from libwebbynim.so: "find" is [active match, match count] while a search is on. */
    static void update(JSONObject state) {
        if (!showing()) return;
        JSONArray find = state.optJSONArray("find");
        if (find == null) {
            // Another tab came forward, which ends the search.
            close();
            return;
        }
        int current = find.optInt(0), total = find.optInt(1);
        String q = query.getText().toString();
        count.setText(q.isEmpty() ? "" : total == 0 ? "No matches" : current + " of " + total);
    }

    private static View build(Activity a) {
        bar = new LinearLayout(a);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(Ui.dp(a, 8), 0, 0, 0);
        bar.setBackgroundColor(Ui.background);
        query = new EditText(a);
        query.setSingleLine(true);
        query.setHint("Find in page");
        query.setTextColor(Ui.foreground);
        query.setImeOptions(EditorInfo.IME_ACTION_SEARCH);
        query.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) {}
            @Override public void afterTextChanged(Editable s) {
                Native.cmd("find.find", "query", s.toString());
            }
        });
        query.setOnEditorActionListener((v, actionId, event) -> {
            if (actionId == EditorInfo.IME_ACTION_SEARCH
                || (event != null && event.getKeyCode() == KeyEvent.KEYCODE_ENTER && event.getAction() == KeyEvent.ACTION_DOWN)) {
                Native.cmd("find.next");
                return true;
            }
            return false;
        });
        bar.addView(query, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        count = Ui.text(a, "", 14, Ui.dim);
        count.setPadding(Ui.dp(a, 8), 0, Ui.dp(a, 4), 0);
        bar.addView(count);
        bar.addView(Ui.iconButton(a, R.drawable.ic_keyboard_arrow_up, "Previous match", v -> Native.cmd("find.previous")));
        bar.addView(Ui.iconButton(a, R.drawable.ic_keyboard_arrow_down, "Next match", v -> Native.cmd("find.next")));
        bar.addView(Ui.iconButton(a, R.drawable.ic_close, "Close", v -> close()));
        return bar;
    }
}
