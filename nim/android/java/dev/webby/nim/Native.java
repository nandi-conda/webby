package dev.webby.nim;

import android.view.Surface;

/** libwebbynim.so (src/glue.c, src/webby_android.nim). Every call must come from the main thread. */
final class Native {
    static {
        System.loadLibrary("webbynim");
    }

    private Native() {}

    /** Starts Ladybird (once per process); `activity` receives the on* callbacks. 0 on success. */
    static native int init(Class<?> activity, String prefix, String profile, float density, int dark);

    static native void setSurface(Surface surface);

    /** The page area's size in pixels. */
    static native void resize(int width, int height);

    static native void newTab(String url, boolean focus);

    static native void closeTab(int index);

    static native void selectTab(int index);

    /** A URL or search words, from the URL field. */
    static native void load(String text);

    static final int BACK = 0, FORWARD = 1, RELOAD_OR_STOP = 2, RELOAD = 3;

    static native void nav(int what);

    static final int DOWN = 0, UP = 1, MOVE = 2, CANCEL = 3;

    static native void touch(int action, int pointer, float x, float y, long timeMs);

    /** A key in Ladybird's key codes (Web::UIEvents::KeyCode) and modifiers (1 Alt, 2 Ctrl, 4 Shift, 8 Super). */
    static native void key(boolean down, int code, int codePoint, int modifiers);

    /** Inserts `text` at the caret of the page's text field, first replacing `length` UTF-16 units from `start`
     * (relative to the caret). */
    static native void imeCommit(String text, int start, int length);

    static native void dialogRespond(int tab, long id, boolean ok, String text);

    static native void setFocus(boolean focused);

    /** 1 light, 2 dark. */
    static native void colorScheme(int scheme);

    static native void trimMemory(int level);

    static native void visible(boolean visible);

    static native void save();

    /** Puts `text` on the page's clipboard and pastes it into the field that was long-pressed. */
    static native void paste(String text);

    /** "openInNewTab" / "open" with a URL, or a context menu script action ("selectAll", "cut"). */
    static native void contextAction(String action, String arg);
}
