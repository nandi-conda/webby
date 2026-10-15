package dev.nimkit;

import android.view.Surface;

/** The app's Nim code (lib<app>.so, framework/android/glue.c). Every call must come from the main thread. */
final class Native {
    private Native() {}

    // Event kinds for event(); they match nk_event in src/nimkit/backend/android.nim.
    static final int CLICK = 0, CHANGE = 1, SUBMIT = 2, TOGGLE = 3, POINTER_DOWN = 4, POINTER_MOVE = 5,
            POINTER_UP = 6, POINTER_CANCEL = 7, HTTP_DONE = 8, VALUE = 9, SELECT = 10;

    /** Runs the app's Nim code (first time) or rebuilds its views (a new Activity); `host` gets the op() calls. */
    static native void start(Class<?> host, String dataDir, float density);

    static native void event(int id, int kind, String text, float x, float y, int pointer);

    /** A canvas's surface came (non-null, `width` x `height` pixels) or went (null). */
    static native void surface(int id, Surface surface, int width, int height);

    static native void timer(int id);
}
