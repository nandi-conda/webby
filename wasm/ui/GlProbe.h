/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Whether latha-gui's GL works for this store: a context made and dropped at once, as WebGL would make one. The
// chrome asks its own and the engine worker's (ToEngine::HasGl): when only the chrome has GL, the engine runs in it.

#pragma once

#include <EGL/egl.h>

namespace WebbyUI {

inline bool gl_works()
{
    static int works = -1;
    if (works >= 0)
        return works;
    works = 0;
    auto display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, nullptr, nullptr))
        return false;
    EGLConfig config {};
    EGLint n = 0;
    EGLint const config_attribs[] = { EGL_NONE };
    eglChooseConfig(display, config_attribs, &config, 1, &n);
    EGLint const attribs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    auto context = eglCreateContext(display, config, EGL_NO_CONTEXT, attribs);
    if (context == EGL_NO_CONTEXT)
        return false;
    eglDestroyContext(display, context);
    works = 1;
    return true;
}

}
