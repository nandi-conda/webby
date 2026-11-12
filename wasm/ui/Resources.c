/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Resources.h"

// C23 #embed; CMakeLists.txt passes fonts/ and Ladybird's Base/res/themes as --embed-dir.
static unsigned char const theme[] = {
#embed <Default.ini>
};
static unsigned char const sans[] = {
#embed <LiberationSans-Regular.ttf>
};
static unsigned char const sans_bold[] = {
#embed <LiberationSans-Bold.ttf>
};
static unsigned char const serif[] = {
#embed <LiberationSerif-Regular.ttf>
};
static unsigned char const mono[] = {
#embed <LiberationMono-Regular.ttf>
};

struct WebbyBuiltinResource const webby_builtin_theme = { "Default.ini", theme, sizeof(theme) };
struct WebbyBuiltinResource const webby_builtin_fonts[] = {
    { "LiberationSans-Regular.ttf", sans, sizeof(sans) },
    { "LiberationSans-Bold.ttf", sans_bold, sizeof(sans_bold) },
    { "LiberationSerif-Regular.ttf", serif, sizeof(serif) },
    { "LiberationMono-Regular.ttf", mono, sizeof(mono) },
};
size_t const webby_builtin_font_count = sizeof(webby_builtin_fonts) / sizeof(webby_builtin_fonts[0]);
