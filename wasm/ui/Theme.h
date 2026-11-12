/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

// The chrome's colors, light or dark as the desktop is (latha:gui's host.prefers-dark, which qt2wasm's platform theme
// turns into QStyleHints::colorScheme, with changes as colorSchemeChanged). The values change in place, so a
// `QColor const& x = theme().text` taken once always reads the current one; BrowserWindow switches them and repaints.
// Light is Chrome's light theme, dark Chrome's dark theme.

#include <QColor>

namespace WebbyUI {

struct Theme {
    bool dark = false;
    QColor strip;            // the tab strip
    QColor tab;              // the active tab, the toolbar, bars and panels drawn on it
    QColor tab_hover;        // an inactive tab under the pointer
    QColor text;
    QColor dim_text;
    QColor field;            // the address bar, not focused
    QColor focus;            // focus rings, links in the chrome, the accent
    QColor on_focus;         // text on a `focus` fill (buttons)
    QColor button_hover;
    QColor hover;            // a lighter hover, for rows in dialogs
    QColor disabled;
    QColor star;
    QColor age;              // tabs tinted by age
    QColor border;           // hairlines between bars and around popups
    QColor panel;            // popups that float over the page (link status aside)
    QColor menu;             // menus and dialogs
    QColor menu_disabled;
    QColor selected;         // the selected omnibox suggestion, menu row under the pointer, a dialog's chosen row
    QColor selection;        // selected text in the chrome's fields
    QColor error;
    QColor page_blank;       // where the page has not painted yet

    // A pressed or hovered-on-hover fill: a step darker in light, lighter in dark.
    QColor deeper(QColor const& c) const { return dark ? c.lighter(125) : c.darker(105); }

    void set_dark(bool d)
    {
        dark = d;
        if (!d) {
            strip = QColor(0xde, 0xe1, 0xe6);
            tab = QColor(0xff, 0xff, 0xff);
            tab_hover = QColor(0xec, 0xee, 0xf1);
            text = QColor(0x20, 0x21, 0x24);
            dim_text = QColor(0x5f, 0x63, 0x68);
            field = QColor(0xf1, 0xf3, 0xf4);
            focus = QColor(0x1a, 0x73, 0xe8);
            on_focus = QColor(0xff, 0xff, 0xff);
            button_hover = QColor(0xe8, 0xea, 0xed);
            hover = QColor(0xf1, 0xf3, 0xf4);
            disabled = QColor(0xbd, 0xc1, 0xc6);
            star = QColor(0x1a, 0x73, 0xe8);
            border = QColor(0xda, 0xdc, 0xe0);
            panel = QColor(0xf8, 0xf9, 0xfa);
            menu = QColor(0xff, 0xff, 0xff);
            menu_disabled = QColor(0xa0, 0xa4, 0xa8);
            selected = QColor(0xe8, 0xf0, 0xfe);
            selection = QColor(0xc2, 0xdb, 0xff);
            error = QColor(0xd9, 0x30, 0x25);
            page_blank = QColor(0xff, 0xff, 0xff);
        } else {
            strip = QColor(0x20, 0x21, 0x24);
            tab = QColor(0x35, 0x36, 0x3a);
            tab_hover = QColor(0x2b, 0x2c, 0x2f);
            text = QColor(0xe8, 0xea, 0xed);
            dim_text = QColor(0x9a, 0xa0, 0xa6);
            field = QColor(0x20, 0x21, 0x24);
            focus = QColor(0x8a, 0xb4, 0xf8);
            on_focus = QColor(0x20, 0x21, 0x24);
            button_hover = QColor(0x48, 0x49, 0x4d);
            hover = QColor(0x3c, 0x40, 0x43);
            disabled = QColor(0x5f, 0x63, 0x68);
            star = QColor(0x8a, 0xb4, 0xf8);
            border = QColor(0x4a, 0x4c, 0x50);
            panel = QColor(0x29, 0x2a, 0x2d);
            menu = QColor(0x29, 0x2a, 0x2d);
            menu_disabled = QColor(0x6f, 0x73, 0x78);
            selected = QColor(0x39, 0x44, 0x57);
            selection = QColor(0x3b, 0x5b, 0x8f);
            error = QColor(0xf2, 0x8b, 0x82);
            page_blank = QColor(0x20, 0x21, 0x24);
        }
        age = QColor(0xf2, 0x8b, 0x1e);
    }
};

inline Theme& theme()
{
    static Theme t = [] {
        Theme t;
        t.set_dark(false);
        return t;
    }();
    return t;
}

}
