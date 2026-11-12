/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Resources.h"

// Summarize's page scripts, the Nim front end's as they are, and the side panel's page (C23 #embed; CMakeLists.txt
// passes nim/src/scripts and this directory as --embed-dir), each NUL-terminated.
char const webby_builtin_page_text_js[] = {
#embed <page_text.js>
    , 0
};
char const webby_builtin_jump_to_text_js[] = {
#embed <jump_to_text.js>
    , 0
};
char const webby_builtin_ask_selection_js[] = {
#embed <ask_selection.js>
    , 0
};
char const webby_builtin_summary_panel_html[] = {
#embed <summary-panel.html>
    , 0
};
