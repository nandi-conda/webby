/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// A popup menu painted with QPainter inside the window (qt6-wasi has QtGui only: no QMenu, no popup windows). The
// window forwards its input here while the menu is open; the menu paints itself on top of everything else.

#pragma once

#include <QPointF>
#include <QRectF>
#include <QSize>
#include <QString>
#include <functional>
#include <vector>

class QKeyEvent;
class QPainter;

class PopupMenu {
public:
    struct Item {
        QString label;
        std::function<void()> action; // none: a separator
        bool enabled { true };
    };

    void add(QString label, std::function<void()> action, bool enabled = true);
    void add_separator();
    bool empty() const { return m_items.empty(); }

    // Opens at `at` (window coordinates), moved to fit inside `window`.
    void open(QPointF at, QSize window);
    void close();
    bool is_open() const { return m_open; }

    void paint(QPainter&) const;

    // Input while open. Each returns true when the window should repaint. A press outside the menu closes it
    // (the press is swallowed); a release over an item runs it, except the release of the right-click that
    // opened the menu at the same spot.
    bool mouse_press(QPointF);
    bool mouse_release(QPointF, bool right_button);
    bool mouse_move(QPointF);
    bool key_press(QKeyEvent*);

private:
    int item_at(QPointF) const;
    QRectF item_rect(int index) const;
    void activate(int index);
    void step(int direction);

    std::vector<Item> m_items;
    bool m_open { false };
    QRectF m_rect;
    QPointF m_opened_at;
    bool m_moved { false };
    int m_hover { -1 };
};
