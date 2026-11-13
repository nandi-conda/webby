/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The types WebView (WebView.h, what the chrome uses) and EngineView (EngineView.h, LibWeb in this instance) share.
// Only std types, so Qt code includes this without meeting Ladybird's headers.

#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace WebbyUI {

// Keyboard modifiers, as LibWeb's UIEvents::KeyModifier numbers them.
enum Modifier : unsigned {
    ModNone = 0,
    ModAlt = 1 << 0,
    ModCtrl = 1 << 1,
    ModShift = 1 << 2,
    ModSuper = 1 << 3,
    ModKeypad = 1 << 4,
};

// Mouse buttons, as LibWeb's UIEvents::MouseButton numbers them.
enum MouseButton : unsigned {
    ButtonNone = 0,
    ButtonPrimary = 1,
    ButtonSecondary = 2,
    ButtonMiddle = 4,
    ButtonBackward = 8,
    ButtonForward = 16,
};

// What a right-click (or Ctrl+click) hit, for the chrome's context menu. URLs are "" when there is none.
struct ContextMenu {
    int x { 0 }; // viewport coordinates of the click
    int y { 0 };
    std::string link;      // the link's URL
    std::string link_text; // its text
    std::string image;     // the image's URL
    std::string selection; // the selected text in the clicked frame
    bool editable { false }; // the click was in a text field or contenteditable
};

// A navigation saved as a file (see WebView::on_download).
struct Download {
    std::string url;
    std::string path;  // where it was saved, "" if it was not
    uint64_t size { 0 };
    std::string mime;
    std::string error; // why it was not saved, "" if it was
};

// A navigation whose response is a PDF (see WebView::on_pdf).
struct PdfDocument {
    std::string url;
    std::string mime;
    std::vector<uint8_t> data;
};

// What the last paint() changed in the pixels it returned, when it knows (it repainted only damage): the rows
// moved by `moved` (negative: the content moved up, the page scrolled down), then `rects` drawn again. When not
// known, compare the frames.
struct PaintChange {
    bool known { false };
    int moved { 0 };
    std::vector<std::array<int, 4>> rects; // x, y, width, height
};

// The viewport's scrollbars, as of the last paint(), for the chrome to draw over the page: in Ladybird the
// Compositor process draws them, and there is none here. Viewport pixels. A scrollbar is thin until the pointer is
// over it or drags it (`expanded`), when its gutter is drawn too. Inner scroll containers' scrollbars are in the
// page's own pixels. The view takes the presses, drags and hovers on all of them (mouse_down and so on).
struct Scrollbar {
    bool vertical { true };
    bool expanded { false };
    std::array<int, 4> gutter {}; // x, y, width, height
    std::array<int, 4> thumb {};
    uint32_t thumb_color { 0 }; // ARGB, not premultiplied
    uint32_t track_color { 0 };
    bool operator==(Scrollbar const&) const = default;
};

// Find in page (Ctrl+F): every match highlighted, the active one scrolled to. `index` counts from 0; `total` is -1
// when unknown, 0 for no match.
struct FindResult {
    unsigned index { 0 };
    int total { 0 };
};

}
