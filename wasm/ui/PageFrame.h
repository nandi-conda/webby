/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// What a new frame of the page changed since the one on screen, so that the window sends the host only that.
//
// Every frame used to go out whole: the page re-rastered, then the full window base64 encoded for the host, decoded
// there and blended, ~6 MB per frame at 1600x1000 (two thirds of a scroll's time; Ladybird's own raster was ~15%).
// PageFrame keeps a hash of each row of each 128-pixel column band of the frame on screen. A new frame's rows are
// matched against them: the offset most rows agree on is the scroll (the host moves those pixels itself,
// qt2wasm::gui::scrollWindow), and only the band rows that still differ after that move are damaged. Sticky and fixed
// parts of a page (a header, a sidebar) differ after the move, so they are damaged and repainted where they stay.

#pragma once

#include <QRegion>
#include <QSize>
#include <cstdint>
#include <vector>

namespace WebbyUI {

class PageFrame {
public:
    struct Change {
        // The content moved up by `scroll` pixels (the page scrolled down by it); 0: no move.
        int scroll { 0 };
        // What to repaint after the move, in the frame's pixels.
        QRegion damage;
    };

    // `pixels`: the new frame, premultiplied BGRA, `size` pixels, rows packed. `owner` tells frames of different views
    // apart: a new owner or size damages everything.
    Change take(uint8_t const* pixels, QSize size, void const* owner);
    // The same when the page already knows what it changed (WebView::last_paint_change): the content moved up by
    // `scroll`, then `damage` was drawn again. Only the damaged rows are hashed (a page that animates a dot used to
    // hash and sort every row of the frame for each of its frames).
    Change take_known(uint8_t const* pixels, QSize size, void const* owner, int scroll, QRegion const& damage);

    // The next frame is compared with nothing (the screen no longer shows the last one).
    void invalidate() { m_size = {}; }

    static constexpr int band_width = 128;

private:
    void hash_rows(uint8_t const* pixels, QSize size, std::vector<uint64_t>& out) const;
    uint64_t hash_band_row(uint8_t const* pixels, int width, int y, int band) const;
    int find_scroll(std::vector<uint64_t> const& now) const;

    QSize m_size;
    void const* m_owner { nullptr };
    int m_bands { 0 };
    // m_rows[band * height + y]: the hash of row y of the band on screen.
    std::vector<uint64_t> m_rows;
    std::vector<uint64_t> m_next;
};

}
