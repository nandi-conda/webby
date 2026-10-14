package dev.webby.nim;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.InputType;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.LinearLayout;
import android.widget.TextView;

/** The shell's colors and small widget helpers, shared by the activity and the feature screens. */
final class Ui {
    private Ui() {}

    static boolean dark;
    static int foreground, background, fieldBackground, dim, accent;

    static void setDark(boolean isDark) {
        dark = isDark;
        foreground = dark ? 0xffe6e1e5 : 0xff1c1b1f;
        background = dark ? 0xff1c1b1f : 0xfffffbfe;
        fieldBackground = dark ? 0xff2b2930 : 0xffece6f0;
        dim = (foreground & 0x00ffffff) | 0x99000000;
        accent = dark ? 0xffd0bcff : 0xff6750a4;
    }

    static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, c.getResources().getDisplayMetrics()));
    }

    static ImageButton iconButton(Context c, int icon, String description, View.OnClickListener click) {
        ImageButton b = new ImageButton(c);
        b.setImageResource(icon);
        b.setColorFilter(foreground);
        b.setContentDescription(description);
        TypedValue ripple = new TypedValue();
        c.getTheme().resolveAttribute(android.R.attr.selectableItemBackgroundBorderless, ripple, true);
        b.setBackgroundResource(ripple.resourceId);
        b.setOnClickListener(click);
        b.setLayoutParams(new LinearLayout.LayoutParams(dp(c, 44), dp(c, 44)));
        return b;
    }

    static TextView text(Context c, String s, float sp, int color) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        t.setSingleLine(true);
        t.setEllipsize(TextUtils.TruncateAt.END);
        return t;
    }

    static TextView heading(Context c, String s) {
        TextView t = text(c, s, 13, accent);
        t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setPadding(dp(c, 16), dp(c, 16), dp(c, 16), dp(c, 6));
        return t;
    }

    static GradientDrawable pill(Context c) {
        GradientDrawable pill = new GradientDrawable();
        pill.setColor(fieldBackground);
        pill.setCornerRadius(dp(c, 22));
        return pill;
    }

    static void selectable(View v) {
        TypedValue ripple = new TypedValue();
        v.getContext().getTheme().resolveAttribute(android.R.attr.selectableItemBackground, ripple, true);
        v.setBackgroundResource(ripple.resourceId);
    }

    /** A row: an optional icon, a title and a dimmer second line, and an optional trailing button. */
    static LinearLayout row(Context c, int icon, String title, String subtitle, View trailing) {
        LinearLayout row = new LinearLayout(c);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(dp(c, 16), dp(c, 8), trailing != null ? dp(c, 4) : dp(c, 16), dp(c, 8));
        row.setMinimumHeight(dp(c, 56));
        if (icon != 0) {
            android.widget.ImageView i = new android.widget.ImageView(c);
            i.setImageResource(icon);
            i.setColorFilter(dim);
            LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(dp(c, 24), dp(c, 24));
            p.setMargins(0, 0, dp(c, 16), 0);
            row.addView(i, p);
        }
        LinearLayout texts = new LinearLayout(c);
        texts.setOrientation(LinearLayout.VERTICAL);
        texts.addView(text(c, title, 15, foreground));
        if (subtitle != null && !subtitle.isEmpty()) texts.addView(text(c, subtitle, 12, dim));
        row.addView(texts, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        if (trailing != null) row.addView(trailing);
        selectable(row);
        return row;
    }

    static EditText field(Context c, String value, String hint) {
        EditText e = new EditText(c);
        e.setSingleLine(true);
        e.setText(value);
        e.setHint(hint);
        e.setInputType(InputType.TYPE_CLASS_TEXT);
        return e;
    }

    /** A vertical box with dialog padding, for AlertDialog.setView. */
    static LinearLayout form(Context c) {
        LinearLayout box = new LinearLayout(c);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(c, 20), dp(c, 8), dp(c, 20), 0);
        return box;
    }

    static TextView label(Context c, String s) {
        TextView t = text(c, s, 12, dim);
        t.setPadding(0, dp(c, 8), 0, 0);
        return t;
    }

    static void confirm(Activity a, String message, String action, Runnable then) {
        new AlertDialog.Builder(a).setMessage(message)
            .setPositiveButton(action, (d, w) -> then.run())
            .setNegativeButton("Cancel", null)
            .show();
    }

    static void toast(Context c, String s) {
        android.widget.Toast.makeText(c, s, android.widget.Toast.LENGTH_SHORT).show();
    }
}
