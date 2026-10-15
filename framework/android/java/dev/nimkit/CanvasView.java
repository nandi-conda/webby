package dev.nimkit;

import android.os.SystemClock;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import org.json.JSONObject;

/**
 * A canvas: a SurfaceView the Nim side fills with pixels (nk_blit), which passes on touches, keys and focus, and
 * talks to the on-screen keyboard for a text field the canvas draws itself (TEXT_FIELD, webby's page inputs).
 */
final class CanvasView extends SurfaceView {
    private final Host host;
    private final int id;
    /** The focused text field ({before, after}) or null. */
    private JSONObject field;
    private long lastTouch;
    private float downX, downY;

    CanvasView(Host host, int id) {
        super(host);
        this.host = host;
        this.id = id;
        setFocusable(true);
        setFocusableInTouchMode(true);
        getHolder().addCallback(new SurfaceHolder.Callback() {
            public void surfaceCreated(SurfaceHolder h) {}
            public void surfaceChanged(SurfaceHolder h, int format, int w, int hh) {
                Native.surface(id, h.getSurface(), w, hh);
            }
            public void surfaceDestroyed(SurfaceHolder h) { Native.surface(id, null, 0, 0); }
        });
        // After the keyboard closes the view can grow without a fresh frame; hand the surface over again at the
        // view's size so the canvas is redrawn to fill it.
        addOnLayoutChangeListener((x, l, top, r, b, ol, ot, or, ob) -> {
            if ((r - l != or - ol || b - top != ob - ot) && getHolder().getSurface().isValid())
                Native.surface(id, getHolder().getSurface(), r - l, b - top);
        });
    }

    @Override
    public boolean onTouchEvent(MotionEvent ev) {
        int kind;
        switch (ev.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: case MotionEvent.ACTION_POINTER_DOWN: kind = Native.POINTER_DOWN; break;
            case MotionEvent.ACTION_UP: case MotionEvent.ACTION_POINTER_UP: kind = Native.POINTER_UP; break;
            case MotionEvent.ACTION_CANCEL: kind = Native.POINTER_CANCEL; break;
            default: kind = Native.POINTER_MOVE;
        }
        if (ev.getActionMasked() == MotionEvent.ACTION_DOWN) {
            requestFocus();
            lastTouch = SystemClock.uptimeMillis();
            downX = ev.getX();
            downY = ev.getY();
        }
        if (kind == Native.POINTER_MOVE) {
            for (int h = 0; h < ev.getHistorySize(); h++)
                for (int i = 0; i < ev.getPointerCount(); i++)
                    Native.event(id, kind, "", ev.getHistoricalX(i, h), ev.getHistoricalY(i, h), ev.getPointerId(i));
            for (int i = 0; i < ev.getPointerCount(); i++)
                Native.event(id, kind, "", ev.getX(i), ev.getY(i), ev.getPointerId(i));
        } else {
            int i = ev.getActionIndex();
            Native.event(id, kind, "", ev.getX(i), ev.getY(i), ev.getPointerId(i));
        }
        // Tapping the field that already has the focus again brings back a keyboard the user put away.
        boolean tap = ev.getActionMasked() == MotionEvent.ACTION_UP && ev.getEventTime() - ev.getDownTime() < 500
            && Math.hypot(ev.getX() - downX, ev.getY() - downY) < 8 * host.density;
        if (tap) postDelayed(() -> { if (field != null) showKeyboard(); }, 300);
        return true;
    }

    @Override
    protected void onFocusChanged(boolean focused, int direction, android.graphics.Rect previous) {
        super.onFocusChanged(focused, direction, previous);
        Native.event(id, Native.FOCUS, "", focused ? 1 : 0, 0, 0);
    }

    // --- Keys: hardware keyboards, and keys the on-screen keyboard sends

    private boolean sendKey(KeyEvent e) {
        int code = Keys.windowsCode(e.getKeyCode());
        int mods = Keys.mods(e);
        int cp = (mods & 3) != 0 ? 0 : e.getUnicodeChar(e.getMetaState());
        if (cp < 0x20) cp = 0;
        if (code == 0 && cp == 0) return false;
        host.keyHandled = false;
        Native.event(id, Native.CANVAS_KEY, e.getAction() == KeyEvent.ACTION_UP ? "up" : "down", code, mods, cp);
        return host.keyHandled;
    }

    private void pressKey(int code, int cp) {
        Native.event(id, Native.CANVAS_KEY, "down", code, 0, cp);
        Native.event(id, Native.CANVAS_KEY, "up", code, 0, 0);
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) return super.onKeyDown(keyCode, event);
        return sendKey(event) || super.onKeyDown(keyCode, event);
    }

    @Override
    public boolean onKeyUp(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) return super.onKeyUp(keyCode, event);
        return sendKey(event) || super.onKeyUp(keyCode, event);
    }

    // --- The on-screen keyboard

    /** TEXT_FIELD: the focused field changed ("" for none); `show` brings the keyboard up. */
    void setField(String json, boolean show) {
        JSONObject next = null;
        try {
            if (!json.isEmpty()) next = new JSONObject(json);
        } catch (org.json.JSONException ignored) {
            // nothing to edit
        }
        boolean had = field != null;
        field = next;
        InputMethodManager imm = getContext().getSystemService(InputMethodManager.class);
        if (next == null) {
            if (had) {
                imm.hideSoftInputFromWindow(getWindowToken(), 0);
                imm.restartInput(this);
            }
            return;
        }
        if (!had) imm.restartInput(this);
        // Only for a field the user just tapped: pages that focus a field by themselves don't pop the keyboard.
        if (show || (!had && SystemClock.uptimeMillis() - lastTouch < 1500)) showKeyboard();
    }

    private void showKeyboard() {
        requestFocus();
        getContext().getSystemService(InputMethodManager.class).showSoftInput(this, 0);
    }

    @Override
    public boolean onCheckIsTextEditor() {
        return field != null;
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo info) {
        if (field == null) return null;
        // No suggestions: keyboards otherwise add spaces and smart punctuation the field never asked for, and
        // compose words in ways it can't show.
        info.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
        info.imeOptions = EditorInfo.IME_ACTION_GO | EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN;
        String before = field.optString("before");
        info.initialSelStart = before.length();
        info.initialSelEnd = before.length();
        return new FieldInput();
    }

    private final class FieldInput extends BaseInputConnection {
        /** UTF-16 length of the composition the keyboard has put in the field so far. */
        private int composing;

        FieldInput() {
            super(CanvasView.this, false);
        }

        private void input(String text, int start, int length) {
            Native.event(id, Native.TEXT_INPUT, text, start, length, 0);
        }

        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            input(text.toString(), -composing, composing);
            composing = 0;
            return true;
        }

        @Override
        public boolean setComposingText(CharSequence text, int newCursorPosition) {
            input(text.toString(), -composing, composing);
            composing = text.length();
            return true;
        }

        @Override
        public boolean finishComposingText() {
            composing = 0;
            return true;
        }

        @Override
        public boolean deleteSurroundingText(int before, int after) {
            if (before > 0) input("", -before, before);
            if (after > 0) input("", 0, after);
            return true;
        }

        @Override
        public boolean sendKeyEvent(KeyEvent event) {
            return sendKey(event);
        }

        @Override
        public boolean performEditorAction(int action) {
            pressKey(0x0D, 0x0D);
            return true;
        }

        @Override
        public CharSequence getTextBeforeCursor(int n, int flags) {
            String s = field == null ? "" : field.optString("before");
            return s.substring(Math.max(0, s.length() - n));
        }

        @Override
        public CharSequence getTextAfterCursor(int n, int flags) {
            String s = field == null ? "" : field.optString("after");
            return s.substring(0, Math.min(n, s.length()));
        }

        @Override
        public CharSequence getSelectedText(int flags) {
            return null;
        }
    }
}
