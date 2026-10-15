package dev.nimkit;

import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.drawable.Drawable;

/** An app icon (registerIcons in src/nimkit/core.nim): SVG path data of absolute M, L, H, V, C and Z commands in an
 * em square, filled in one colour at the drawable's bounds. */
final class Glyph extends Drawable {
    final Path path = new Path();
    final Path scaled = new Path();
    final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    final float em;
    final int size;

    /** `spec` is "em pathdata"; `size` the side in pixels. */
    Glyph(String spec, int size, int color) {
        int space = spec.indexOf(' ');
        em = Float.parseFloat(spec.substring(0, space));
        this.size = size;
        parse(spec.substring(space + 1));
        paint.setColor(color);
        paint.setStyle(Paint.Style.FILL);
        path.setFillType(Path.FillType.WINDING);
        setBounds(0, 0, size, size);
    }

    void parse(String d) {
        float[] nums = new float[6];
        char cmd = 'M';
        int i = 0, n = d.length();
        float x = 0, y = 0;
        while (i < n) {
            char ch = d.charAt(i);
            if (Character.isLetter(ch)) { cmd = ch; i++; if (cmd == 'Z' || cmd == 'z') path.close(); continue; }
            if (ch == ' ' || ch == ',' || ch == '\n') { i++; continue; }
            int count = cmd == 'C' ? 6 : (cmd == 'H' || cmd == 'V') ? 1 : 2;
            for (int k = 0; k < count; k++) {
                while (i < n && (d.charAt(i) == ' ' || d.charAt(i) == ',')) i++;
                int start = i;
                if (i < n && (d.charAt(i) == '-' || d.charAt(i) == '+')) i++;
                boolean dot = false;
                while (i < n) {
                    char c = d.charAt(i);
                    if (Character.isDigit(c)) i++;
                    else if (c == '.' && !dot) { dot = true; i++; }
                    else if ((c == 'e' || c == 'E')) { i++; if (i < n && (d.charAt(i) == '-' || d.charAt(i) == '+')) i++; }
                    else break;
                }
                nums[k] = start == i ? 0 : Float.parseFloat(d.substring(start, i));
            }
            switch (cmd) {
                case 'M': x = nums[0]; y = nums[1]; path.moveTo(x, y); cmd = 'L'; break;
                case 'L': x = nums[0]; y = nums[1]; path.lineTo(x, y); break;
                case 'H': x = nums[0]; path.lineTo(x, y); break;
                case 'V': y = nums[0]; path.lineTo(x, y); break;
                case 'C':
                    path.cubicTo(nums[0], nums[1], nums[2], nums[3], nums[4], nums[5]);
                    x = nums[4]; y = nums[5];
                    break;
                default: i++;
            }
        }
    }

    @Override public int getIntrinsicWidth() { return size; }
    @Override public int getIntrinsicHeight() { return size; }

    @Override public void draw(Canvas c) {
        Matrix m = new Matrix();
        float s = Math.min(getBounds().width(), getBounds().height()) / em;
        m.setScale(s, s);
        m.postTranslate(getBounds().left, getBounds().top);
        path.transform(m, scaled);
        c.drawPath(scaled, paint);
    }

    @Override public void setAlpha(int a) { paint.setAlpha(a); }
    @Override public void setColorFilter(ColorFilter f) { paint.setColorFilter(f); }
    @Override public int getOpacity() { return PixelFormat.TRANSLUCENT; }
}
