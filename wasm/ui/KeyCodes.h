/*
 * Copyright (c) 2018-2020, Andreas Kling <andreas@ladybird.org>
 * Copyright (c) 2024, Andrew Kaster <akaster@serenityos.org>
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// LibWeb's UIEvents key codes and modifier bits (what webby:engine's key-down / key-up take), copied from Ladybird's
// Libraries/LibWebCommon/UIEvents/KeyCode.h at ../../LADYBIRD_COMMIT, so that the UI component (shell/) builds without
// a Ladybird tree. The engine build (CMakeLists.txt) stops if the ENUMERATE_KEY_CODES block below no longer appears
// in Ladybird's header word for word: copy it again then.

#pragma once

namespace Web::UIEvents {

// clang-format off
#define ENUMERATE_KEY_CODES                                          \
    __ENUMERATE_KEY_CODE(Invalid, "Invalid", 0x00)                   \
    __ENUMERATE_KEY_CODE(Backspace, "Backspace", 0x08)               \
    __ENUMERATE_KEY_CODE(Tab, "Tab", 0x09)                           \
    __ENUMERATE_KEY_CODE(Return, "Return", 0x0D)                     \
    __ENUMERATE_KEY_CODE(LeftShift, "LeftShift", 0x10)               \
    __ENUMERATE_KEY_CODE(RightShift, "RightShift", 0xB0)             \
    __ENUMERATE_KEY_CODE(LeftControl, "LeftControl", 0x11)           \
    __ENUMERATE_KEY_CODE(RightControl, "RightControl", 0xB1)         \
    __ENUMERATE_KEY_CODE(LeftAlt, "LeftAlt", 0x12)                   \
    __ENUMERATE_KEY_CODE(RightAlt, "RightAlt", 0xB2)                 \
    __ENUMERATE_KEY_CODE(AltGr, "AltGr", 0xE1)                       \
    __ENUMERATE_KEY_CODE(PauseBreak, "PauseBreak", 0x13)             \
    __ENUMERATE_KEY_CODE(CapsLock, "CapsLock", 0x14)                 \
    __ENUMERATE_KEY_CODE(Escape, "Escape", 0x1B)                     \
    __ENUMERATE_KEY_CODE(Space, "Space", 0x20)                       \
    __ENUMERATE_KEY_CODE(PageUp, "PageUp", 0x21)                     \
    __ENUMERATE_KEY_CODE(PageDown, "PageDown", 0x22)                 \
    __ENUMERATE_KEY_CODE(End, "End", 0x23)                           \
    __ENUMERATE_KEY_CODE(Home, "Home", 0x24)                         \
    __ENUMERATE_KEY_CODE(Left, "Left", 0x25)                         \
    __ENUMERATE_KEY_CODE(Up, "Up", 0x26)                             \
    __ENUMERATE_KEY_CODE(Right, "Right", 0x27)                       \
    __ENUMERATE_KEY_CODE(Down, "Down", 0x28)                         \
    __ENUMERATE_KEY_CODE(PrintScreen, "PrintScreen", 0x2A)           \
    __ENUMERATE_KEY_CODE(SysRq, "SysRq", 0x2C)                       \
    __ENUMERATE_KEY_CODE(Delete, "Delete", 0x2E)                     \
    __ENUMERATE_KEY_CODE(0, "0", 0x30)                               \
    __ENUMERATE_KEY_CODE(1, "1", 0x31)                               \
    __ENUMERATE_KEY_CODE(2, "2", 0x32)                               \
    __ENUMERATE_KEY_CODE(3, "3", 0x33)                               \
    __ENUMERATE_KEY_CODE(4, "4", 0x34)                               \
    __ENUMERATE_KEY_CODE(5, "5", 0x35)                               \
    __ENUMERATE_KEY_CODE(6, "6", 0x36)                               \
    __ENUMERATE_KEY_CODE(7, "7", 0x37)                               \
    __ENUMERATE_KEY_CODE(8, "8", 0x38)                               \
    __ENUMERATE_KEY_CODE(9, "9", 0x39)                               \
    __ENUMERATE_KEY_CODE(A, "A", 0x41)                               \
    __ENUMERATE_KEY_CODE(B, "B", 0x42)                               \
    __ENUMERATE_KEY_CODE(C, "C", 0x43)                               \
    __ENUMERATE_KEY_CODE(D, "D", 0x44)                               \
    __ENUMERATE_KEY_CODE(E, "E", 0x45)                               \
    __ENUMERATE_KEY_CODE(F, "F", 0x46)                               \
    __ENUMERATE_KEY_CODE(G, "G", 0x47)                               \
    __ENUMERATE_KEY_CODE(H, "H", 0x48)                               \
    __ENUMERATE_KEY_CODE(I, "I", 0x49)                               \
    __ENUMERATE_KEY_CODE(J, "J", 0x4A)                               \
    __ENUMERATE_KEY_CODE(K, "K", 0x4B)                               \
    __ENUMERATE_KEY_CODE(L, "L", 0x4C)                               \
    __ENUMERATE_KEY_CODE(M, "M", 0x4D)                               \
    __ENUMERATE_KEY_CODE(N, "N", 0x4E)                               \
    __ENUMERATE_KEY_CODE(O, "O", 0x4F)                               \
    __ENUMERATE_KEY_CODE(P, "P", 0x50)                               \
    __ENUMERATE_KEY_CODE(Q, "Q", 0x51)                               \
    __ENUMERATE_KEY_CODE(R, "R", 0x52)                               \
    __ENUMERATE_KEY_CODE(S, "S", 0x53)                               \
    __ENUMERATE_KEY_CODE(T, "T", 0x54)                               \
    __ENUMERATE_KEY_CODE(U, "U", 0x55)                               \
    __ENUMERATE_KEY_CODE(V, "V", 0x56)                               \
    __ENUMERATE_KEY_CODE(W, "W", 0x57)                               \
    __ENUMERATE_KEY_CODE(X, "X", 0x58)                               \
    __ENUMERATE_KEY_CODE(Y, "Y", 0x59)                               \
    __ENUMERATE_KEY_CODE(Z, "Z", 0x5A)                               \
    __ENUMERATE_KEY_CODE(RightParen, ")", 0x60)                      \
    __ENUMERATE_KEY_CODE(ExclamationPoint, "!", 0x61)                \
    __ENUMERATE_KEY_CODE(AtSign, "@", 0x62)                          \
    __ENUMERATE_KEY_CODE(Hashtag, "#", 0x63)                         \
    __ENUMERATE_KEY_CODE(Dollar, "$", 0x64)                          \
    __ENUMERATE_KEY_CODE(Percent, "%", 0x65)                         \
    __ENUMERATE_KEY_CODE(Circumflex, "^", 0x66)                      \
    __ENUMERATE_KEY_CODE(Ampersand, "&", 0x67)                       \
    __ENUMERATE_KEY_CODE(Asterisk, "*", 0x68)                        \
    __ENUMERATE_KEY_CODE(LeftParen, "(", 0x69)                       \
    __ENUMERATE_KEY_CODE(Plus, "+", 0x6A)                            \
    __ENUMERATE_KEY_CODE(Minus, "-", 0x6B)                           \
    __ENUMERATE_KEY_CODE(Slash, "/", 0x6C)                           \
    __ENUMERATE_KEY_CODE(Comma, ",", 0x6D)                           \
    __ENUMERATE_KEY_CODE(Period, ".", 0x6E)                          \
    __ENUMERATE_KEY_CODE(Colon, ":", 0x6F)                           \
    __ENUMERATE_KEY_CODE(F1, "F1", 0x70)                             \
    __ENUMERATE_KEY_CODE(F2, "F2", 0x71)                             \
    __ENUMERATE_KEY_CODE(F3, "F3", 0x72)                             \
    __ENUMERATE_KEY_CODE(F4, "F4", 0x73)                             \
    __ENUMERATE_KEY_CODE(F5, "F5", 0x74)                             \
    __ENUMERATE_KEY_CODE(F6, "F6", 0x75)                             \
    __ENUMERATE_KEY_CODE(F7, "F7", 0x76)                             \
    __ENUMERATE_KEY_CODE(F8, "F8", 0x77)                             \
    __ENUMERATE_KEY_CODE(F9, "F9", 0x78)                             \
    __ENUMERATE_KEY_CODE(F10, "F10", 0x79)                           \
    __ENUMERATE_KEY_CODE(F11, "F11", 0x7A)                           \
    __ENUMERATE_KEY_CODE(F12, "F12", 0x7B)                           \
    __ENUMERATE_KEY_CODE(DoubleQuote, "\"", 0x7C)                    \
    __ENUMERATE_KEY_CODE(Apostrophe, "'", 0x7D)                      \
    __ENUMERATE_KEY_CODE(Insert, "Insert", 0x7E)                     \
    __ENUMERATE_KEY_CODE(Semicolon, ";", 0x7F)                       \
    __ENUMERATE_KEY_CODE(LessThan, "<", 0x80)                        \
    __ENUMERATE_KEY_CODE(Equal, "=", 0x81)                           \
    __ENUMERATE_KEY_CODE(GreaterThan, ">", 0x82)                     \
    __ENUMERATE_KEY_CODE(QuestionMark, "?", 0x83)                    \
    __ENUMERATE_KEY_CODE(LeftBracket, "[", 0x84)                     \
    __ENUMERATE_KEY_CODE(RightBracket, "]", 0x85)                    \
    __ENUMERATE_KEY_CODE(Backslash, "\\", 0x86)                      \
    __ENUMERATE_KEY_CODE(Underscore, "_", 0x87)                      \
    __ENUMERATE_KEY_CODE(LeftBrace, "{", 0x88)                       \
    __ENUMERATE_KEY_CODE(RightBrace, "}", 0x89)                      \
    __ENUMERATE_KEY_CODE(Pipe, "|", 0x8A)                            \
    __ENUMERATE_KEY_CODE(Tilde, "~", 0x8B)                           \
    __ENUMERATE_KEY_CODE(Backtick, "`", 0x8C)                        \
    __ENUMERATE_KEY_CODE(NumLock, "NumLock", 0x90)                   \
    __ENUMERATE_KEY_CODE(ScrollLock, "ScrollLock", 0x91)             \
    __ENUMERATE_KEY_CODE(LeftSuper, "LeftSuper", 0x92)               \
    __ENUMERATE_KEY_CODE(RightSuper, "RightSuper", 0xAC)             \
    __ENUMERATE_KEY_CODE(BrowserSearch, "BrowserSearch", 0x93)       \
    __ENUMERATE_KEY_CODE(BrowserFavorites, "BrowserFavorites", 0x94) \
    __ENUMERATE_KEY_CODE(BrowserHome, "BrowserHome", 0x95)           \
    __ENUMERATE_KEY_CODE(PreviousTrack, "PreviousTrack", 0x96)       \
    __ENUMERATE_KEY_CODE(BrowserBack, "BrowserBack", 0x97)           \
    __ENUMERATE_KEY_CODE(BrowserForward, "BrowserForward", 0x98)     \
    __ENUMERATE_KEY_CODE(BrowserRefresh, "BrowserRefresh", 0x99)     \
    __ENUMERATE_KEY_CODE(BrowserStop, "BrowserStop", 0x9A)           \
    __ENUMERATE_KEY_CODE(VolumeDown, "VolumeDown", 0x9B)             \
    __ENUMERATE_KEY_CODE(VolumeUp, "VolumeUp", 0x9C)                 \
    __ENUMERATE_KEY_CODE(Wake, "Wake", 0x9D)                         \
    __ENUMERATE_KEY_CODE(Sleep, "Sleep", 0x9E)                       \
    __ENUMERATE_KEY_CODE(NextTrack, "NextTrack", 0x9F)               \
    __ENUMERATE_KEY_CODE(MediaSelect, "MediaSelect", 0xA0)           \
    __ENUMERATE_KEY_CODE(Email, "Email", 0xA1)                       \
    __ENUMERATE_KEY_CODE(MyComputer, "MyComputer", 0xA2)             \
    __ENUMERATE_KEY_CODE(Power, "Power", 0xA3)                       \
    __ENUMERATE_KEY_CODE(Stop, "Stop", 0xA4)                         \
    __ENUMERATE_KEY_CODE(LeftGUI, "LeftGUI", 0xA5)                   \
    __ENUMERATE_KEY_CODE(Mute, "Mute", 0xA6)                         \
    __ENUMERATE_KEY_CODE(RightGUI, "RightGUI", 0xA7)                 \
    __ENUMERATE_KEY_CODE(Calculator, "Calculator", 0xA8)             \
    __ENUMERATE_KEY_CODE(Apps, "Apps", 0xA9)                         \
    __ENUMERATE_KEY_CODE(PlayPause, "PlayPause", 0xAA)               \
    __ENUMERATE_KEY_CODE(Menu, "Menu", 0xAB)
// clang-format on

enum KeyCode : unsigned char {
#define __ENUMERATE_KEY_CODE(name, ui_name, code) Key_##name = code,
    ENUMERATE_KEY_CODES
#undef __ENUMERATE_KEY_CODE
};

enum KeyModifier {
    Mod_None = 0x00,
    Mod_Alt = (1 << 0),
    Mod_Ctrl = (1 << 1),
    Mod_Shift = (1 << 2),
    Mod_Super = (1 << 3),
    Mod_Keypad = (1 << 4),
};

}
