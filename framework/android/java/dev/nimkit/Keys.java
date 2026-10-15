package dev.nimkit;

import android.view.KeyEvent;

/** Android key codes as the Windows virtual-key codes KeyEvent.code uses (src/nimkit/core.nim). */
final class Keys {
    private Keys() {}

    static int windowsCode(int k) {
        if (k >= KeyEvent.KEYCODE_A && k <= KeyEvent.KEYCODE_Z) return 'A' + (k - KeyEvent.KEYCODE_A);
        if (k >= KeyEvent.KEYCODE_0 && k <= KeyEvent.KEYCODE_9) return '0' + (k - KeyEvent.KEYCODE_0);
        if (k >= KeyEvent.KEYCODE_F1 && k <= KeyEvent.KEYCODE_F12) return 0x70 + (k - KeyEvent.KEYCODE_F1);
        switch (k) {
            case KeyEvent.KEYCODE_ENTER: case KeyEvent.KEYCODE_NUMPAD_ENTER: return 0x0D;
            case KeyEvent.KEYCODE_ESCAPE: return 0x1B;
            case KeyEvent.KEYCODE_TAB: return 0x09;
            case KeyEvent.KEYCODE_DEL: return 0x08;           // Backspace
            case KeyEvent.KEYCODE_FORWARD_DEL: return 0x2E;
            case KeyEvent.KEYCODE_SPACE: return 0x20;
            case KeyEvent.KEYCODE_DPAD_LEFT: return 0x25;
            case KeyEvent.KEYCODE_DPAD_UP: return 0x26;
            case KeyEvent.KEYCODE_DPAD_RIGHT: return 0x27;
            case KeyEvent.KEYCODE_DPAD_DOWN: return 0x28;
            case KeyEvent.KEYCODE_PAGE_UP: return 0x21;
            case KeyEvent.KEYCODE_PAGE_DOWN: return 0x22;
            case KeyEvent.KEYCODE_MOVE_END: return 0x23;
            case KeyEvent.KEYCODE_MOVE_HOME: return 0x24;
            case KeyEvent.KEYCODE_INSERT: return 0x2D;
            default: return 0;
        }
    }

    /** modAlt 1, modCtrl 2, modShift 4, modSuper 8. */
    static int mods(KeyEvent e) {
        return (e.isAltPressed() ? 1 : 0) | (e.isCtrlPressed() ? 2 : 0) | (e.isShiftPressed() ? 4 : 0)
                | (e.isMetaPressed() ? 8 : 0);
    }
}
