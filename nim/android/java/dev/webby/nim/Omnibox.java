package dev.webby.nim;

import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import org.json.JSONArray;
import org.json.JSONObject;

/** Address bar suggestions (src/features/omnibox.nim on the desktop): a list over the page while the URL is edited. */
final class Omnibox {
    private final MainActivity activity;
    private final EditText field;
    private final ScrollView panel;
    private final LinearLayout list;
    private boolean setting;

    Omnibox(MainActivity a, EditText urlField, FrameLayout pageFrame) {
        activity = a;
        field = urlField;
        panel = new ScrollView(a);
        panel.setBackgroundColor(Ui.background);
        panel.setElevation(Ui.dp(a, 4));
        list = new LinearLayout(a);
        list.setOrientation(LinearLayout.VERTICAL);
        panel.addView(list);
        panel.setVisibility(View.GONE);
        pageFrame.addView(panel, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        field.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
            public void onTextChanged(CharSequence s, int a, int b, int c) {}
            public void afterTextChanged(Editable s) {
                if (!setting) update();
            }
        });
    }

    /** Sets the field's text without asking for suggestions. */
    void setText(String text) {
        setting = true;
        field.setText(text);
        setting = false;
    }

    void hide() {
        panel.setVisibility(View.GONE);
        list.removeAllViews();
    }

    void update() {
        String text = field.getText().toString();
        if (!field.hasFocus() || text.trim().isEmpty()) {
            hide();
            return;
        }
        JSONArray found = Native.arr("suggest", "text", text);
        list.removeAllViews();
        for (int i = 0; i < found.length(); i++) {
            JSONObject s = found.optJSONObject(i);
            String kind = s.optString("kind"), url = s.optString("url"), title = s.optString("title");
            int icon = kind.equals("bookmark") ? R.drawable.ic_star_border : kind.equals("tab") ? R.drawable.ic_tab : R.drawable.ic_history;
            View row = Ui.row(activity, icon, title.isEmpty() ? url : title,
                kind.equals("tab") ? "Switch to tab · " + url : url, null);
            row.setOnClickListener(v -> {
                hide();
                if (!(kind.equals("tab") && Boolean.TRUE.equals(Native.cmd("switchToTab", "url", url)))) Native.load(url);
                activity.leaveUrlField();
            });
            list.addView(row);
        }
        panel.setVisibility(found.length() > 0 ? View.VISIBLE : View.GONE);
        panel.scrollTo(0, 0);
    }
}
