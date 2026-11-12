/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Resources.h"

// The Nim front end's page scripts, shared as they are (C23 #embed; CMakeLists.txt passes nim/src/scripts as
// --embed-dir), each NUL-terminated.
char const webby_builtin_passwords_js[] = {
#embed <passwords.js>
    , 0
};
