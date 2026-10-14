package dev.webby.nim;

import android.app.Activity;
import android.app.AlertDialog;
import android.view.View;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.Spinner;
import android.widget.ArrayAdapter;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/** The History screen (src/features/history.nim on the desktop): visits by day, search, remove, clear. */
final class HistoryScreen {
    private HistoryScreen() {}

    private static final String[] RANGES = {"Last hour", "Last 24 hours", "Last 7 days", "Last 4 weeks", "All time"};
    private static final long[] RANGE_SECONDS = {3600, 86400, 7 * 86400, 28 * 86400, 0};

    static void show(MainActivity a) {
        Screen s = new Screen(a, "History");
        s.addAction(R.drawable.ic_delete_sweep_outlined, "Clear browsing data", v -> clearBrowsingData(a, () -> fill(a, s)));
        s.addSearch("Search history", () -> fill(a, s));
        fill(a, s);
        s.show();
    }

    private static void fill(MainActivity a, Screen s) {
        JSONObject r = Native.obj("history.list", "query", s.query());
        List<View> rows = new ArrayList<>();
        if (r == null || r.optBoolean("empty")) {
            rows.add(s.emptyRow(s.query().trim().isEmpty() ? "Pages you visit will show up here." : "No history matches."));
            s.setRows(rows);
            return;
        }
        JSONArray list = r.optJSONArray("rows");
        for (int i = 0; i < list.length(); i++) {
            JSONObject row = list.optJSONObject(i);
            if (row.has("heading")) {
                rows.add(Ui.heading(a, row.optString("heading")));
                continue;
            }
            String url = row.optString("url");
            String sub = row.optString("time") + "  " + (row.optString("site").isEmpty() ? url : row.optString("site"));
            if (row.optInt("count") > 1) sub += "  ×" + row.optInt("count");
            JSONArray ids = row.optJSONArray("ids");
            View remove = Ui.iconButton(a, R.drawable.ic_close, "Remove from history", v -> {
                Native.cmd("history.remove", "ids", ids);
                fill(a, s);
            });
            View v = Ui.row(a, R.drawable.ic_public, row.optString("title"), sub, remove);
            v.setOnClickListener(x -> {
                s.dismiss();
                a.openUrl(url);
            });
            v.setOnLongClickListener(x -> {
                a.linkMenu(url, () -> {
                    Native.cmd("history.remove", "ids", ids);
                    fill(a, s);
                }, "Remove from history");
                return true;
            });
            rows.add(v);
        }
        if (r.optBoolean("more")) rows.add(s.emptyRow("Older visits aren't listed; search to find them."));
        s.setRows(rows);
    }

    /** Chrome's "Clear browsing data": a time range and what to clear. */
    static void clearBrowsingData(Activity a, Runnable done) {
        LinearLayout form = Ui.form(a);
        form.addView(Ui.label(a, "Time range"));
        Spinner range = new Spinner(a);
        range.setAdapter(new ArrayAdapter<>(a, android.R.layout.simple_spinner_dropdown_item, RANGES));
        range.setSelection(RANGES.length - 1);
        form.addView(range);
        CheckBox cookies = check(a, form, "Cookies and other site data", "Signs you out of most sites.");
        CheckBox cache = check(a, form, "Cached images and files", "Pages may load more slowly next time.");
        CheckBox history = check(a, form, "Browsing history", "Clears History and address bar suggestions.");
        new AlertDialog.Builder(a).setTitle("Clear browsing data").setView(form)
            .setPositiveButton("Clear data", (d, w) -> {
                Native.cmd("clearBrowsingData", "seconds", RANGE_SECONDS[range.getSelectedItemPosition()],
                    "siteData", cookies.isChecked(), "cache", cache.isChecked(), "history", history.isChecked());
                if (done != null) done.run();
                Ui.toast(a, "Cleared");
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    private static CheckBox check(Activity a, LinearLayout form, String label, String detail) {
        CheckBox c = new CheckBox(a);
        c.setText(label);
        c.setChecked(true);
        c.setTextColor(Ui.foreground);
        form.addView(c);
        android.widget.TextView d = Ui.text(a, detail, 12, Ui.dim);
        d.setSingleLine(false);
        d.setPadding(Ui.dp(a, 32), 0, 0, Ui.dp(a, 4));
        form.addView(d);
        return c;
    }
}
