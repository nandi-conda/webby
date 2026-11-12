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
// nim/src/scripts/passwords.js (PageScripts.c), as text.
extern char const webby_builtin_passwords_js[];
// Summarize (SummaryScripts.c): nim/src/scripts/page_text.js, jump_to_text.js and ask_selection.js, and the side
// panel's page (summary-panel.html), as text.
extern char const webby_builtin_page_text_js[];
extern char const webby_builtin_jump_to_text_js[];
extern char const webby_builtin_ask_selection_js[];
extern char const webby_builtin_summary_panel_html[];

#ifdef __cplusplus
}
#endif
