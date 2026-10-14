package dev.webby.nim;

import android.app.AlertDialog;
import android.view.View;
import android.widget.EditText;
import android.widget.LinearLayout;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/** Saved sessions (sessions_page.dart): save the open tabs, restore, rename, delete (src/features/tabs/sessions.nim). */
final class SessionsScreen {
    private SessionsScreen() {}

    private static Runnable refresh;

    static void changed() {
        if (refresh != null) refresh.run();
    }

    static void show(MainActivity a) {
        Screen s = new Screen(a, "Sessions");
        s.addAction(R.drawable.ic_delete_sweep_outlined, "Delete all sessions", v -> Ui.confirm(a,
            "Delete all saved sessions?", "Delete all", () -> Native.cmd("sessions.deleteAll")));
        Runnable fill = () -> {
            JSONObject r = Native.obj("sessions.list");
            if (r == null) return;
            List<View> rows = new ArrayList<>();
            if (!r.optString("error").isEmpty()) rows.add(s.emptyRow(r.optString("error")));
            int open = r.optInt("openTabs");
            View save = Ui.row(a, R.drawable.ic_add, "Save open tabs as a session",
                open == 1 ? "1 tab" : open + " tabs", null);
            save.setOnClickListener(v -> saveDialog(a, r.optString("defaultName"), false));
            rows.add(save);
            View closeAll = Ui.row(a, R.drawable.ic_layers_outlined, "Close all tabs and save as a session",
                "Pinned tabs stay open", null);
            closeAll.setOnClickListener(v -> saveDialog(a, r.optString("defaultName"), true));
            rows.add(closeAll);
            JSONArray list = r.optJSONArray("sessions");
            if (list.length() == 0) rows.add(s.emptyRow("Sessions you save will show up here."));
            for (int i = 0; i < list.length(); i++) {
                JSONObject ses = list.optJSONObject(i);
                String id = ses.optString("id");
                JSONArray ts = ses.optJSONArray("tabs");
                View head = Ui.row(a, R.drawable.ic_layers, ses.optString("name"),
                    ses.optString("created") + " · " + (ts.length() == 1 ? "1 tab" : ts.length() + " tabs"),
                    Ui.iconButton(a, R.drawable.ic_more_vert, "More", v -> sessionMenu(a, ses)));
                head.setOnClickListener(v -> {
                    s.dismiss();
                    Native.cmd("sessions.restore", "id", id, "index", -1);
                });
                rows.add(head);
                for (int k = 0; k < ts.length(); k++) {
                    JSONObject t = ts.optJSONObject(k);
                    int index = k;
                    String url = t.optString("url");
                    View row = Ui.row(a, 0, t.optString("title").isEmpty() ? url : t.optString("title"), url,
                        Ui.iconButton(a, R.drawable.ic_close, "Remove from session",
                            v -> Native.cmd("sessions.removeTab", "id", id, "index", index)));
                    row.setPadding(Ui.dp(a, 56), row.getPaddingTop(), row.getPaddingRight(), row.getPaddingBottom());
                    row.setOnClickListener(v -> {
                        s.dismiss();
                        Native.cmd("sessions.restore", "id", id, "index", index);
                    });
                    rows.add(row);
                }
            }
            s.setRows(rows);
        };
        refresh = fill;
        s.dialog.setOnDismissListener(d -> {
            if (refresh == fill) refresh = null;
        });
        fill.run();
        s.show();
    }

    private static void sessionMenu(MainActivity a, JSONObject ses) {
        String id = ses.optString("id");
        String[] items = {"Restore all", "Rename", "Delete"};
        new AlertDialog.Builder(a).setTitle(ses.optString("name")).setItems(items, (d, i) -> {
            switch (i) {
                case 0: Native.cmd("sessions.restore", "id", id, "index", -1); break;
                case 1: {
                    LinearLayout form = Ui.form(a);
                    EditText name = Ui.field(a, ses.optString("name"), "Name");
                    form.addView(name);
                    new AlertDialog.Builder(a).setTitle("Rename session").setView(form)
                        .setPositiveButton("Rename", (x, w) -> Native.cmd("sessions.rename", "id", id, "name", name.getText().toString()))
                        .setNegativeButton("Cancel", null).show();
                    break;
                }
                case 2: Ui.confirm(a, "Delete “" + ses.optString("name") + "”?", "Delete",
                    () -> Native.cmd("sessions.delete", "id", id)); break;
            }
        }).show();
    }

    static void saveDialog(MainActivity a, String defaultName, boolean closeAll) {
        LinearLayout form = Ui.form(a);
        EditText name = Ui.field(a, defaultName, "Name");
        name.selectAll();
        form.addView(name);
        new AlertDialog.Builder(a).setTitle(closeAll ? "Close all tabs and save" : "Save open tabs").setView(form)
            .setPositiveButton("Save", (d, w) -> {
                if (!Boolean.TRUE.equals(Native.cmd("sessions.saveOpen", "name", name.getText().toString(), "closeAll", closeAll))) {
                    Ui.toast(a, "No pages to save");
                } else {
                    Ui.toast(a, "Session saved");
                }
            })
            .setNegativeButton("Cancel", null).show();
    }
}
