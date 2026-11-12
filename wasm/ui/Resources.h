/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// What webby.wasm carries inside so that it runs with nothing opened to it: Ladybird's default theme and the
// Liberation fonts (fonts/README).
struct WebbyBuiltinResource {
    char const* name;
    unsigned char const* data;
    size_t size;
};

extern struct WebbyBuiltinResource const webby_builtin_theme;
extern struct WebbyBuiltinResource const webby_builtin_fonts[];
extern size_t const webby_builtin_font_count;

#ifdef __cplusplus
}
#endif
