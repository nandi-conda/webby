package dev.webby.nim;

import android.content.Context;
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
 * The page: a SurfaceView that libwebbynim.so draws Ladybird's frames into, which passes touches and keys to it and
 * talks to the on-screen keyboard for the page's focused text field.
 */
final class PageView extends SurfaceView implements SurfaceHolder.Callback {
    /** The page's focused text field (webby_view_ime_state), or null. */
    private JSONObject field;
    private long lastTouch;
    private float downX, downY;

    PageView(Context context) {
        super(context);
        getHolder().addCallback(this);
        setFocusable(true);
        setFocusableInTouchMode(true);
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        Native.setSurface(holder.getSurface());
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        Native.resize(width, height);
        Native.setSurface(holder.getSurface());
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        Native.setSurface(null);
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        int action;
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: action = Native.DOWN; break;
            case MotionEvent.ACTION_UP: action = Native.UP; break;
            case MotionEvent.ACTION_MOVE: action = Native.MOVE; break;
            case MotionEvent.ACTION_CANCEL: action = Native.CANCEL; break;
            default: return true;   // other fingers
        }
        if (action == Native.DOWN) {
            requestFocus();
            lastTouch = SystemClock.uptimeMillis();
            downX = event.getX();
            downY = event.getY();
        }
        int id = event.getPointerId(0);
        if (action == Native.MOVE) {
            for (int i = 0; i < event.getHistorySize(); i++) {
                Native.touch(action, id, event.getHistoricalX(0, i), event.getHistoricalY(0, i), event.getHistoricalEventTime(i));
            }
        }
        Native.touch(action, id, event.getX(0), event.getY(0), event.getEventTime());
        // Tapping the field that already has focus again brings back a keyboard the user put away.
        boolean tap = action == Native.UP && event.getEventTime() - event.getDownTime() < 500
            && Math.hypot(event.getX() - downX, event.getY() - downY) < 8 * getResources().getDisplayMetrics().density;
        if (tap) postDelayed(() -> { if (field != null) showKeyboard(); }, 300);
        return true;
    }

    @Override
    protected void onFocusChanged(boolean focused, int direction, android.graphics.Rect previous) {
        super.onFocusChanged(focused, direction, previous);
        Native.setFocus(focused);
    }

    // ---- Keys (hardware keyboards, and keys the on-screen keyboard sends)

    private static int modifiers(KeyEvent e) {
        int m = 0;
        if (e.isAltPressed()) m |= 1;
        if (e.isCtrlPressed()) m |= 2;
        if (e.isShiftPressed()) m |= 4;
        if (e.isMetaPressed()) m |= 8;
        return m;
    }

    /** Android key code to Ladybird's (the Windows virtual-key codes); 0 if there is none. */
    static int ladybirdKey(int code) {
        if (code >= KeyEvent.KEYCODE_A && code <= KeyEvent.KEYCODE_Z) return 0x41 + code - KeyEvent.KEYCODE_A;
        if (code >= KeyEvent.KEYCODE_0 && code <= KeyEvent.KEYCODE_9) return 0x30 + code - KeyEvent.KEYCODE_0;
        if (code >= KeyEvent.KEYCODE_F1 && code <= KeyEvent.KEYCODE_F12) return 0x70 + code - KeyEvent.KEYCODE_F1;
        switch (code) {
            case KeyEvent.KEYCODE_DEL: return 0x08;
            case KeyEvent.KEYCODE_TAB: return 0x09;
            case KeyEvent.KEYCODE_ENTER: case KeyEvent.KEYCODE_NUMPAD_ENTER: return 0x0D;
            case KeyEvent.KEYCODE_ESCAPE: return 0x1B;
            case KeyEvent.KEYCODE_SPACE: return 0x20;
            case KeyEvent.KEYCODE_PAGE_UP: return 0x21;
            case KeyEvent.KEYCODE_PAGE_DOWN: return 0x22;
            case KeyEvent.KEYCODE_MOVE_END: return 0x23;
            case KeyEvent.KEYCODE_MOVE_HOME: return 0x24;
            case KeyEvent.KEYCODE_DPAD_LEFT: return 0x25;
            case KeyEvent.KEYCODE_DPAD_UP: return 0x26;
            case KeyEvent.KEYCODE_DPAD_RIGHT: return 0x27;
            case KeyEvent.KEYCODE_DPAD_DOWN: return 0x28;
            case KeyEvent.KEYCODE_FORWARD_DEL: return 0x2E;
            case KeyEvent.KEYCODE_SHIFT_LEFT: return 0x10;
            case KeyEvent.KEYCODE_CTRL_LEFT: return 0x11;
            case KeyEvent.KEYCODE_ALT_LEFT: return 0x12;
            default: return 0;
        }
    }

    boolean sendKey(KeyEvent e) {
        int code = ladybirdKey(e.getKeyCode());
        boolean down = e.getAction() == KeyEvent.ACTION_DOWN;
        int mods = modifiers(e);
        int cp = (mods & 3) != 0 ? 0 : e.getUnicodeChar(e.getMetaState());
        if (code == 0x0D) cp = down ? 0x0A : 0;
        if (cp < 0x20 && code != 0x0D) cp = 0;
        if (code == 0 && cp == 0) return false;
        if (down && (mods & 2) != 0 && code == 0x56) MainActivity.pasteFromClipboard(false);   // Ctrl+V
        Native.key(down, code, cp, mods);
        return true;
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

    private void pressKey(int code, int codePoint) {
        Native.key(true, code, codePoint, 0);
        Native.key(false, code, 0, 0);
    }

    // ---- On-screen keyboard

    /** The page's focused field changed (null: none). Opens the keyboard when a tap focused a field. */
    void setField(JSONObject next) {
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
        // Only for a field the user just tapped; pages that focus a field by themselves don't pop the keyboard.
        if (!had && SystemClock.uptimeMillis() - lastTouch < 1500) showKeyboard();
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
        // No suggestions: keyboards otherwise add spaces and smart punctuation the page never asked for, and compose
        // words in ways the page can't show. The Flutter app does the same ("visible password").
        info.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
        info.imeOptions = EditorInfo.IME_ACTION_GO | EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN;
        String before = field.optString("before");
        info.initialSelStart = before.length();
        info.initialSelEnd = before.length();
        return new PageInput();
    }

    private final class PageInput extends BaseInputConnection {
        /** UTF-16 length of the composition the keyboard has put in the page so far. */
        private int composing;

        PageInput() {
            super(PageView.this, false);
        }

        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            Native.imeCommit(text.toString(), -composing, composing);
            composing = 0;
            return true;
        }

        @Override
        public boolean setComposingText(CharSequence text, int newCursorPosition) {
            Native.imeCommit(text.toString(), -composing, composing);
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
            if (before > 0) Native.imeCommit("", -before, before);
            if (after > 0) Native.imeCommit("", 0, after);
            return true;
        }

        @Override
        public boolean sendKeyEvent(KeyEvent event) {
            return sendKey(event);
        }

        @Override
        public boolean performEditorAction(int action) {
            pressKey(0x0D, 0x0A);
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
