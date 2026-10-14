package dev.webby.nim;

import android.app.Activity;
import android.app.Dialog;
import android.graphics.drawable.ColorDrawable;
import android.text.Editable;
import android.text.TextWatcher;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.BaseAdapter;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;

/**
 * A full-screen page over the browser (History, Bookmarks, Passwords...): a header with a back arrow, a title and
 * action buttons, an optional search field, and a list of rows the feature fills with {@link #setRows}.
 */
class Screen {
    final Activity activity;
    final Dialog dialog;
    private final TextView title;
    private final LinearLayout actions;
    private final LinearLayout top;
    private final ListView list;
    private final List<View> rows = new ArrayList<>();
    private final Adapter adapter = new Adapter();
    private Runnable onBack;
    EditText search;

    Screen(Activity a, String titleText) {
        activity = a;
        dialog = new Dialog(a, android.R.style.Theme_DeviceDefault_DayNight);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout root = new LinearLayout(a);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Ui.background);

        LinearLayout header = new LinearLayout(a);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(dp(4), dp(4), dp(4), dp(4));
        header.addView(Ui.iconButton(a, R.drawable.ic_arrow_back, "Back", v -> back()));
        title = Ui.text(a, titleText, 20, Ui.foreground);
        title.setPadding(dp(12), 0, 0, 0);
        header.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        actions = new LinearLayout(a);
        header.addView(actions);
        root.addView(header);

        top = new LinearLayout(a);
        top.setOrientation(LinearLayout.VERTICAL);
        root.addView(top);

        list = new ListView(a);
        list.setDivider(null);
        list.setAdapter(adapter);
        root.addView(list, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        dialog.setContentView(root);
        Window w = dialog.getWindow();
        w.setBackgroundDrawable(new ColorDrawable(Ui.background));
        w.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT);
        w.setStatusBarColor(Ui.background);
        w.setNavigationBarColor(Ui.background);
        w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE | WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN);
        if (!Ui.dark) {
            w.getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        }
        dialog.setOnKeyListener((d, code, e) -> {
            if (code == android.view.KeyEvent.KEYCODE_BACK && e.getAction() == android.view.KeyEvent.ACTION_UP) {
                back();
                return true;
            }
            return false;
        });
    }

    int dp(float v) {
        return Ui.dp(activity, v);
    }

    void setTitle(String s) {
        title.setText(s);
    }

    /** What the back arrow (and the back key) does instead of closing, e.g. going up a folder; null closes. */
    void setOnBack(Runnable r) {
        onBack = r;
    }

    private void back() {
        if (onBack != null) onBack.run();
        else dismiss();
    }

    void addAction(int icon, String description, View.OnClickListener click) {
        actions.addView(Ui.iconButton(activity, icon, description, click));
    }

    void addSearch(String hint, Runnable changed) {
        search = new EditText(activity);
        search.setSingleLine(true);
        search.setHint(hint);
        search.setTextColor(Ui.foreground);
        search.setHintTextColor(Ui.dim);
        search.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        search.setBackground(Ui.pill(activity));
        search.setPadding(dp(16), 0, dp(16), 0);
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(44));
        p.setMargins(dp(12), 0, dp(12), dp(8));
        search.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
            public void onTextChanged(CharSequence s, int a, int b, int c) {}
            public void afterTextChanged(Editable s) {
                changed.run();
            }
        });
        top.addView(search, p);
    }

    String query() {
        return search == null ? "" : search.getText().toString();
    }

    void addTop(View v) {
        top.addView(v);
    }

    void setRows(List<View> newRows) {
        rows.clear();
        rows.addAll(newRows);
        adapter.notifyDataSetChanged();
    }

    /** A centered dim line for an empty list. */
    View emptyRow(String text) {
        TextView t = Ui.text(activity, text, 14, Ui.dim);
        t.setSingleLine(false);
        t.setGravity(Gravity.CENTER);
        t.setPadding(dp(24), dp(48), dp(24), dp(24));
        return t;
    }

    void show() {
        dialog.show();
    }

    void dismiss() {
        dialog.dismiss();
    }

    private final class Adapter extends BaseAdapter {
        @Override
        public int getCount() {
            return rows.size();
        }

        @Override
        public Object getItem(int i) {
            return rows.get(i);
        }

        @Override
        public long getItemId(int i) {
            return i;
        }

        @Override
        public int getViewTypeCount() {
            return 1;
        }

        @Override
        public int getItemViewType(int i) {
            // Every row is its own view: no recycling.
            return IGNORE_ITEM_VIEW_TYPE;
        }

        @Override
        public View getView(int i, View convert, ViewGroup parent) {
            View v = rows.get(i);
            if (v.getParent() instanceof ViewGroup && v.getParent() != parent) ((ViewGroup) v.getParent()).removeView(v);
            return v;
        }
    }
}
