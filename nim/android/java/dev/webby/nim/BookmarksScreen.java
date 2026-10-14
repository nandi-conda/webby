package dev.webby.nim;

import android.app.AlertDialog;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.Spinner;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Bookmarks (src/features/bookmarks.nim on the desktop): the Bookmarks screen browses the two roots and their
 * folders; the star in the menu bookmarks the page and opens the editor; bookmarks.html imports and exports.
 */
final class BookmarksScreen {
    private BookmarksScreen() {}

    static void show(MainActivity a) {
        Screen s = new Screen(a, "Bookmarks");
        String[] folder = {""};
        s.addAction(R.drawable.ic_create_new_folder_outlined, "New folder", v -> newFolder(a, folder[0], () -> fill(a, s, folder)));
        s.addAction(R.drawable.ic_more_vert, "More", v -> {
            android.widget.PopupMenu m = new android.widget.PopupMenu(a, v);
            m.getMenu().add(0, 1, 0, "Import bookmarks");
            m.getMenu().add(0, 2, 0, "Export bookmarks");
            m.setOnMenuItemClickListener(item -> {
                if (item.getItemId() == 1) a.importBookmarks(() -> fill(a, s, folder));
                else a.exportBookmarks();
                return true;
            });
            m.show();
        });
        fill(a, s, folder);
        s.show();
    }

    private static void fill(MainActivity a, Screen s, String[] folder) {
        JSONObject r = Native.obj("bookmarks.list", "folder", folder[0]);
        if (r == null) return;
        JSONObject f = r.optJSONObject("folder");
        if (f == null && !folder[0].isEmpty()) {
            // The folder went away (deleted here or by sync).
            folder[0] = "";
            fill(a, s, folder);
            return;
        }
        s.setTitle(f == null ? "Bookmarks" : f.optString("title"));
        String parent = r.optString("parent");
        s.setOnBack(f == null ? null : () -> {
            folder[0] = parent;
            fill(a, s, folder);
        });
        List<View> rows = new ArrayList<>();
        JSONArray items = r.optJSONArray("items");
        if (items.length() == 0) rows.add(s.emptyRow("No bookmarks here yet."));
        for (int i = 0; i < items.length(); i++) {
            JSONObject b = items.optJSONObject(i);
            String id = b.optString("id");
            boolean isFolder = b.optBoolean("isFolder");
            View v;
            if (isFolder) {
                int n = b.optInt("count");
                v = Ui.row(a, R.drawable.ic_folder_outlined, b.optString("title"), n == 1 ? "1 item" : n + " items", null);
                v.setOnClickListener(x -> {
                    folder[0] = id;
                    fill(a, s, folder);
                });
            } else {
                String url = b.optString("url");
                v = Ui.row(a, R.drawable.ic_public, b.optString("title"), url, null);
                v.setOnClickListener(x -> {
                    s.dismiss();
                    a.openUrl(url);
                });
            }
            boolean root = f == null;
            v.setOnLongClickListener(x -> {
                if (root) return false;
                itemMenu(a, b, () -> fill(a, s, folder));
                return true;
            });
            rows.add(v);
        }
        s.setRows(rows);
    }

    private static void itemMenu(MainActivity a, JSONObject b, Runnable changed) {
        String id = b.optString("id");
        List<String> labels = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        if (b.optBoolean("isFolder")) {
            labels.add("Open all in new tabs");
            actions.add(() -> {
                JSONArray links = Native.arr("bookmarks.links", "folder", id);
                for (int i = 0; i < links.length(); i++) a.openInNewTab(links.optString(i), false);
                Ui.toast(a, links.length() == 1 ? "Opened 1 tab" : "Opened " + links.length() + " tabs");
            });
        } else {
            String url = b.optString("url");
            labels.add("Open in new tab"); actions.add(() -> a.openInNewTab(url, false));
            labels.add("Copy link"); actions.add(() -> a.copy(url));
            labels.add("Share"); actions.add(() -> a.share(url));
        }
        labels.add("Edit"); actions.add(() -> edit(a, id, changed));
        labels.add("Delete"); actions.add(() -> Ui.confirm(a, "Delete “" + b.optString("title") + "”"
            + (b.optBoolean("isFolder") ? " and everything in it?" : "?"), "Delete", () -> {
                Native.cmd("bookmarks.remove", "id", id);
                changed.run();
            }));
        new AlertDialog.Builder(a).setTitle(b.optString("title"))
            .setItems(labels.toArray(new String[0]), (d, i) -> actions.get(i).run()).show();
    }

    private static void newFolder(MainActivity a, String parent, Runnable changed) {
        LinearLayout form = Ui.form(a);
        EditText name = Ui.field(a, "", "Folder name");
        form.addView(name);
        new AlertDialog.Builder(a).setTitle("New folder").setView(form)
            .setPositiveButton("Create", (d, w) -> {
                String t = name.getText().toString().trim();
                Native.cmd("bookmarks.add", "folder", true, "title", t.isEmpty() ? "New folder" : t, "parent", parent);
                changed.run();
            })
            .setNegativeButton("Cancel", null).show();
    }

    /** The editor: name, address (links only) and folder. */
    static void edit(MainActivity a, String id, Runnable changed) {
        JSONObject found = findNode(id);
        if (found == null) return;
        boolean isFolder = found.optBoolean("isFolder");
        LinearLayout form = Ui.form(a);
        form.addView(Ui.label(a, "Name"));
        EditText name = Ui.field(a, isFolder ? found.optString("title") : found.optString("name"), "Name");
        form.addView(name);
        EditText url = null;
        if (!isFolder) {
            form.addView(Ui.label(a, "Address"));
            url = Ui.field(a, found.optString("url"), "Address");
            url.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI);
            form.addView(url);
        }
        form.addView(Ui.label(a, "Folder"));
        JSONArray folders = Native.arr("bookmarks.folders");
        List<String> names = new ArrayList<>();
        List<String> ids = new ArrayList<>();
        int selected = 0;
        for (int i = 0; i < folders.length(); i++) {
            JSONObject f = folders.optJSONObject(i);
            if (f.optString("id").equals(id)) continue;
            StringBuilder indent = new StringBuilder();
            for (int d = 0; d < f.optInt("depth"); d++) indent.append("    ");
            if (f.optString("id").equals(found.optString("parent"))) selected = names.size();
            names.add(indent + f.optString("title"));
            ids.add(f.optString("id"));
        }
        Spinner folder = new Spinner(a);
        folder.setAdapter(new ArrayAdapter<>(a, android.R.layout.simple_spinner_dropdown_item, names));
        folder.setSelection(selected);
        form.addView(folder);
        EditText urlField = url;
        new AlertDialog.Builder(a).setTitle(isFolder ? "Edit folder" : "Edit bookmark").setView(form)
            .setPositiveButton("Save", (d, w) -> {
                Native.cmd("bookmarks.update", "id", id, "title", name.getText().toString().trim(),
                    "url", urlField == null ? "" : urlField.getText().toString().trim(),
                    "parent", ids.isEmpty() ? "" : ids.get(folder.getSelectedItemPosition()));
                if (changed != null) changed.run();
            })
            .setNeutralButton("Delete", (d, w) -> {
                Native.cmd("bookmarks.remove", "id", id);
                if (changed != null) changed.run();
            })
            .setNegativeButton("Cancel", null).show();
    }

    /** A bookmark or folder by id, with its parent's id (walks the folders the Nim side lists). */
    private static JSONObject findNode(String id) {
        List<String> queue = new ArrayList<>();
        queue.add("");
        while (!queue.isEmpty()) {
            String f = queue.remove(0);
            JSONObject r = Native.obj("bookmarks.list", "folder", f);
            if (r == null) continue;
            JSONArray items = r.optJSONArray("items");
            for (int i = 0; i < items.length(); i++) {
                JSONObject b = items.optJSONObject(i);
                if (b.optString("id").equals(id)) {
                    try {
                        b.put("parent", f);
                    } catch (org.json.JSONException e) {
                        // not reached
                    }
                    return b;
                }
                if (b.optBoolean("isFolder")) queue.add(b.optString("id"));
            }
        }
        return null;
    }

    /** The menu's star: bookmarks the page (if it isn't yet) and opens the editor. */
    static void bookmarkPage(MainActivity a) {
        boolean was = a.state().optBoolean("bookmarked");
        JSONObject b = Native.obj("bookmarks.bookmarkPage");
        if (b == null) return;
        if (!was) Ui.toast(a, "Bookmarked in " + (b.optString("parentPath").isEmpty() ? "Bookmarks bar" : b.optString("parentPath")));
        edit(a, b.optString("id"), null);
    }
}
