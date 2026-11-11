/*
 * Copyright (c) 2026-present, the webby developers.
 * Copyright (c) 2022-present, the Ladybird developers (the table, from UI/Qt/WebContentView.cpp).
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "KeyMap.h"

#include <LibWebCommon/UIEvents/KeyCode.h>
#include <QKeyEvent>

unsigned web_key_code(QKeyEvent const& event)
{
    using namespace Web::UIEvents;
    struct Mapping {
        Qt::Key qt_key;
        KeyCode web_key;
    };
    static constexpr Mapping mappings[] = {
        { Qt::Key_0, Key_0 }, { Qt::Key_1, Key_1 }, { Qt::Key_2, Key_2 }, { Qt::Key_3, Key_3 }, { Qt::Key_4, Key_4 },
        { Qt::Key_5, Key_5 }, { Qt::Key_6, Key_6 }, { Qt::Key_7, Key_7 }, { Qt::Key_8, Key_8 }, { Qt::Key_9, Key_9 },
        { Qt::Key_A, Key_A }, { Qt::Key_B, Key_B }, { Qt::Key_C, Key_C }, { Qt::Key_D, Key_D }, { Qt::Key_E, Key_E },
        { Qt::Key_F, Key_F }, { Qt::Key_G, Key_G }, { Qt::Key_H, Key_H }, { Qt::Key_I, Key_I }, { Qt::Key_J, Key_J },
        { Qt::Key_K, Key_K }, { Qt::Key_L, Key_L }, { Qt::Key_M, Key_M }, { Qt::Key_N, Key_N }, { Qt::Key_O, Key_O },
        { Qt::Key_P, Key_P }, { Qt::Key_Q, Key_Q }, { Qt::Key_R, Key_R }, { Qt::Key_S, Key_S }, { Qt::Key_T, Key_T },
        { Qt::Key_U, Key_U }, { Qt::Key_V, Key_V }, { Qt::Key_W, Key_W }, { Qt::Key_X, Key_X }, { Qt::Key_Y, Key_Y },
        { Qt::Key_Z, Key_Z },
        { Qt::Key_F1, Key_F1 }, { Qt::Key_F2, Key_F2 }, { Qt::Key_F3, Key_F3 }, { Qt::Key_F4, Key_F4 },
        { Qt::Key_F5, Key_F5 }, { Qt::Key_F6, Key_F6 }, { Qt::Key_F7, Key_F7 }, { Qt::Key_F8, Key_F8 },
        { Qt::Key_F9, Key_F9 }, { Qt::Key_F10, Key_F10 }, { Qt::Key_F11, Key_F11 }, { Qt::Key_F12, Key_F12 },
        { Qt::Key_Alt, Key_LeftAlt }, { Qt::Key_Ampersand, Key_Ampersand }, { Qt::Key_Apostrophe, Key_Apostrophe },
        { Qt::Key_AsciiCircum, Key_Circumflex }, { Qt::Key_AsciiTilde, Key_Tilde }, { Qt::Key_Asterisk, Key_Asterisk },
        { Qt::Key_At, Key_AtSign }, { Qt::Key_Backslash, Key_Backslash }, { Qt::Key_Backspace, Key_Backspace },
        { Qt::Key_Bar, Key_Pipe }, { Qt::Key_BraceLeft, Key_LeftBrace }, { Qt::Key_BraceRight, Key_RightBrace },
        { Qt::Key_BracketLeft, Key_LeftBracket }, { Qt::Key_BracketRight, Key_RightBracket },
        { Qt::Key_CapsLock, Key_CapsLock }, { Qt::Key_Colon, Key_Colon }, { Qt::Key_Comma, Key_Comma },
        { Qt::Key_Control, Key_LeftControl }, { Qt::Key_Delete, Key_Delete }, { Qt::Key_Dollar, Key_Dollar },
        { Qt::Key_Down, Key_Down }, { Qt::Key_End, Key_End }, { Qt::Key_Equal, Key_Equal }, { Qt::Key_Enter, Key_Return },
        { Qt::Key_Escape, Key_Escape }, { Qt::Key_Exclam, Key_ExclamationPoint }, { Qt::Key_Greater, Key_GreaterThan },
        { Qt::Key_Home, Key_Home }, { Qt::Key_Insert, Key_Insert }, { Qt::Key_Left, Key_Left }, { Qt::Key_Less, Key_LessThan },
        { Qt::Key_Menu, Key_Menu }, { Qt::Key_Meta, Key_LeftSuper }, { Qt::Key_Minus, Key_Minus },
        { Qt::Key_NumberSign, Key_Hashtag }, { Qt::Key_NumLock, Key_NumLock }, { Qt::Key_PageDown, Key_PageDown },
        { Qt::Key_PageUp, Key_PageUp }, { Qt::Key_ParenLeft, Key_LeftParen }, { Qt::Key_ParenRight, Key_RightParen },
        { Qt::Key_Percent, Key_Percent }, { Qt::Key_Period, Key_Period }, { Qt::Key_Plus, Key_Plus },
        { Qt::Key_Print, Key_PrintScreen }, { Qt::Key_Question, Key_QuestionMark }, { Qt::Key_QuoteDbl, Key_DoubleQuote },
        { Qt::Key_QuoteLeft, Key_Backtick }, { Qt::Key_Return, Key_Return }, { Qt::Key_Right, Key_Right },
        { Qt::Key_ScrollLock, Key_ScrollLock }, { Qt::Key_Semicolon, Key_Semicolon }, { Qt::Key_Shift, Key_LeftShift },
        { Qt::Key_Slash, Key_Slash }, { Qt::Key_Space, Key_Space }, { Qt::Key_Super_L, Key_LeftSuper },
        { Qt::Key_Super_R, Key_RightSuper }, { Qt::Key_SysReq, Key_SysRq }, { Qt::Key_Tab, Key_Tab },
        { Qt::Key_Underscore, Key_Underscore }, { Qt::Key_Up, Key_Up },
    };
    for (auto const& mapping : mappings) {
        if (event.key() == mapping.qt_key)
            return mapping.web_key;
    }
    return Key_Invalid;
}

unsigned web_modifiers(Qt::KeyboardModifiers modifiers)
{
    using namespace Web::UIEvents;
    unsigned result = Mod_None;
    if (modifiers & Qt::AltModifier)
        result |= Mod_Alt;
    if (modifiers & Qt::ControlModifier)
        result |= Mod_Ctrl;
    if (modifiers & Qt::ShiftModifier)
        result |= Mod_Shift;
    if (modifiers & Qt::MetaModifier)
        result |= Mod_Super;
    if (modifiers & Qt::KeypadModifier)
        result |= Mod_Keypad;
    return result;
}
