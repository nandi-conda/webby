/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "PageFrame.h"

#include <QRect>
#include <algorithm>
#include <cstring>
#include <unordered_map>
#include <utility>

namespace WebbyUI {

void PageFrame::hash_rows(uint8_t const* pixels, QSize size, std::vector<uint64_t>& out) const
{
    int const w = size.width(), h = size.height();
    out.resize(size_t(m_bands) * size_t(h));
    for (int y = 0; y < h; ++y) {
        uint8_t const* row = pixels + size_t(y) * size_t(w) * 4;
        for (int b = 0; b < m_bands; ++b) {
            int const x0 = b * band_width;
            int const x1 = std::min(w, x0 + band_width);
            uint8_t const* p = row + size_t(x0) * 4;
            size_t const bytes = size_t(x1 - x0) * 4;
            // A multiply-xorshift over 8-byte words; the seed keeps an all-zero band from hashing to 0.
            uint64_t hash = 0x9e3779b97f4a7c15ull ^ uint64_t(b);
            size_t i = 0;
            for (; i + 8 <= bytes; i += 8) {
                uint64_t word;
                memcpy(&word, p + i, 8);
                hash = (hash ^ word) * 0xff51afd7ed558ccdull;
                hash ^= hash >> 29;
            }
            if (i < bytes) {
                uint64_t word = 0;
                memcpy(&word, p + i, bytes - i);
                hash = (hash ^ word) * 0xff51afd7ed558ccdull;
                hash ^= hash >> 29;
            }
            out[size_t(b) * size_t(h) + size_t(y)] = hash;
        }
    }
}

// The scroll most band rows agree on: a row that appears once in its band on screen and once in the new frame votes
// for the distance between the two. Rows that repeat (blank lines, borders) do not vote.
int PageFrame::find_scroll(std::vector<uint64_t> const& now) const
{
    int const h = m_size.height();
    std::unordered_map<int, int> votes;
    std::vector<std::pair<uint64_t, int>> old_rows, new_rows;
    auto unique_sorted = [h](std::vector<uint64_t> const& rows, size_t base, std::vector<std::pair<uint64_t, int>>& out) {
        out.clear();
        for (int y = 0; y < h; ++y)
            out.push_back({ rows[base + size_t(y)], y });
        std::sort(out.begin(), out.end());
        // Keep the rows whose hash appears once.
        size_t kept = 0;
        for (size_t i = 0; i < out.size();) {
            size_t j = i + 1;
            while (j < out.size() && out[j].first == out[i].first)
                ++j;
            if (j == i + 1)
                out[kept++] = out[i];
            i = j;
        }
        out.resize(kept);
    };
    for (int b = 0; b < m_bands; ++b) {
        size_t const base = size_t(b) * size_t(h);
        unique_sorted(m_rows, base, old_rows);
        unique_sorted(now, base, new_rows);
        // Both lists are sorted by hash: walk them together.
        size_t i = 0, j = 0;
        while (i < old_rows.size() && j < new_rows.size()) {
            if (old_rows[i].first < new_rows[j].first) {
                ++i;
            } else if (new_rows[j].first < old_rows[i].first) {
                ++j;
            } else {
                ++votes[old_rows[i].second - new_rows[j].second];
                ++i;
                ++j;
            }
        }
    }
    int best = 0, best_votes = 0;
    for (auto [scroll, count] : votes) {
        if (scroll != 0 && count > best_votes) {
            best = scroll;
            best_votes = count;
        }
    }
    // A move has to explain more of the frame than staying put does, and more than a stray match or two.
    auto still = votes.find(0);
    int const still_votes = still == votes.end() ? 0 : still->second;
    if (best_votes < 8 || best_votes <= still_votes)
        return 0;
    return best;
}

PageFrame::Change PageFrame::take(uint8_t const* pixels, QSize size, void const* owner)
{
    Change change;
    int const w = size.width(), h = size.height();
    if (!pixels || w <= 0 || h <= 0) {
        invalidate();
        return change;
    }
    bool const comparable = size == m_size && owner == m_owner;
    m_bands = (w + band_width - 1) / band_width;
    hash_rows(pixels, size, m_next);
    if (!comparable) {
        change.damage = QRect(0, 0, w, h);
    } else {
        change.scroll = find_scroll(m_next);
        int const scroll = change.scroll;
        // Each band's runs of rows that differ, with gaps shorter than merge_gap closed: a sticky sidebar's lines of
        // text are one run, not one per line (the host takes the bounds of more than 16 rectangles, which for a
        // sidebar plus the uncovered strip is the whole page).
        constexpr int merge_gap = 48;
        std::vector<std::vector<std::pair<int, int>>> runs(static_cast<size_t>(m_bands));
        for (int b = 0; b < m_bands; ++b) {
            size_t const base = size_t(b) * size_t(h);
            auto& band = runs[size_t(b)];
            int run = -1;
            for (int y = 0; y <= h; ++y) {
                bool differs = false;
                if (y < h) {
                    int const old_y = y + scroll;
                    differs = old_y < 0 || old_y >= h || m_rows[base + size_t(old_y)] != m_next[base + size_t(y)];
                }
                if (differs && run < 0) {
                    run = y;
                } else if (!differs && run >= 0) {
                    if (!band.empty() && run - band.back().second < merge_gap)
                        band.back().second = y;
                    else
                        band.push_back({ run, y });
                    run = -1;
                }
            }
        }
        auto build = [&](bool one_run_per_band) {
            QRegion region;
            for (int b = 0; b < m_bands; ++b) {
                auto const& band = runs[size_t(b)];
                if (band.empty())
                    continue;
                int const x0 = b * band_width;
                int const bw = std::min(w, x0 + band_width) - x0;
                if (one_run_per_band) {
                    region += QRect(x0, band.front().first, bw, band.back().second - band.front().first);
                    continue;
                }
                for (auto [top, bottom] : band)
                    region += QRect(x0, top, bw, bottom - top);
            }
            return region;
        };
        change.damage = build(false);
        if (change.damage.rectCount() > 16)
            change.damage = build(true);
    }
    std::swap(m_rows, m_next);
    m_size = size;
    m_owner = owner;
    return change;
}

}
