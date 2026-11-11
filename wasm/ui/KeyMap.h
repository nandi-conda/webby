/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <Qt>

class QKeyEvent;

// The LibWeb UIEvents::KeyCode of a Qt key event (Key_Invalid if it has none).
unsigned web_key_code(QKeyEvent const&);
// LibWeb's UIEvents::KeyModifier bits for Qt's modifiers.
unsigned web_modifiers(Qt::KeyboardModifiers);
