/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "PopupMenu.h"

#include <QFontMetricsF>
#include <QKeyEvent>
#include <QPainter>
#include <QPainterPath>

namespace {

constexpr qreal row_height = 28;
constexpr qreal separator_height = 9;
constexpr qreal padding_y = 6;
constexpr qreal padding_x = 16;
constexpr qreal min_width = 180;
constexpr qreal max_width = 420;
constexpr int font_size = 13;

QColor const menu_color { 0xff, 0xff, 0xff };
QColor const border_color { 0xda, 0xdc, 0xe0 };
QColor const hover_color { 0xe8, 0xf0, 0xfe };
QColor const text_color { 0x20, 0x21, 0x24 };
QColor const disabled_color { 0xa0, 0xa4, 0xa8 };

QFont menu_font()
{
    QFont font;
    font.setPixelSize(font_size);
    return font;
}

bool is_separator(PopupMenu::Item const& item) { return !item.action; }

}

void PopupMenu::add(QString label, std::function<void()> action, bool enabled)
{
    m_items.push_back({ std::move(label), std::move(action), enabled });
}

void PopupMenu::add_separator()
{
    if (!m_items.empty() && !is_separator(m_items.back()))
        m_items.push_back({});
}

void PopupMenu::open(QPointF at, QSize window)
{
    while (!m_items.empty() && is_separator(m_items.back()))
        m_items.pop_back();
    if (m_items.empty())
        return;
    QFontMetricsF metrics(menu_font());
    qreal width = min_width;
    qreal height = padding_y * 2;
    for (auto const& item : m_items) {
        height += is_separator(item) ? separator_height : row_height;
        if (!is_separator(item))
            width = qMax(width, metrics.horizontalAdvance(item.label) + padding_x * 2 + 8);
    }
    width = qMin(width, max_width);
    // Below and right of the pointer, flipped where it would leave the window.
    qreal x = at.x() + width > window.width() ? at.x() - width : at.x();
    qreal y = at.y() + height > window.height() ? at.y() - height : at.y();
    x = qBound<qreal>(0, x, qMax<qreal>(0, window.width() - width));
    y = qBound<qreal>(0, y, qMax<qreal>(0, window.height() - height));
    m_rect = { x, y, width, height };
    m_opened_at = at;
    m_moved = false;
    m_hover = -1;
    m_open = true;
}

void PopupMenu::close()
{
    m_open = false;
    m_items.clear();
    m_hover = -1;
}

QRectF PopupMenu::item_rect(int index) const
{
    qreal y = m_rect.top() + padding_y;
    for (int i = 0; i < index; ++i)
        y += is_separator(m_items[i]) ? separator_height : row_height;
    return { m_rect.left(), y, m_rect.width(), is_separator(m_items[index]) ? separator_height : row_height };
}

int PopupMenu::item_at(QPointF p) const
{
    if (!m_rect.contains(p))
        return -1;
    for (int i = 0; i < int(m_items.size()); ++i) {
        if (item_rect(i).contains(p))
            return is_separator(m_items[i]) || !m_items[i].enabled ? -1 : i;
    }
    return -1;
}

void PopupMenu::paint(QPainter& p) const
{
    if (!m_open)
        return;
    p.save();
    p.setRenderHint(QPainter::Antialiasing);
    // A soft shadow, then the menu.
    for (int i = 3; i >= 1; --i) {
        p.setPen(Qt::NoPen);
        p.setBrush(QColor(0, 0, 0, 14));
        p.drawRoundedRect(m_rect.adjusted(-i, -i + 2, i, i + 2), 8 + i, 8 + i);
    }
    p.setPen(QPen(border_color, 1));
    p.setBrush(menu_color);
    p.drawRoundedRect(m_rect.adjusted(0.5, 0.5, -0.5, -0.5), 8, 8);
    auto font = menu_font();
    p.setFont(font);
    QFontMetricsF metrics(font);
    for (int i = 0; i < int(m_items.size()); ++i) {
        auto r = item_rect(i);
        auto const& item = m_items[i];
        if (is_separator(item)) {
            p.setPen(QPen(border_color, 1));
            qreal y = qRound(r.center().y()) + 0.5;
            p.drawLine(QPointF(r.left() + 1, y), QPointF(r.right() - 1, y));
            continue;
        }
        if (i == m_hover) {
            p.setPen(Qt::NoPen);
            p.setBrush(hover_color);
            p.drawRect(r.adjusted(1, 0, -1, 0));
        }
        p.setPen(item.enabled ? text_color : disabled_color);
        auto text = metrics.elidedText(item.label, Qt::ElideRight, r.width() - padding_x * 2);
        p.drawText(r.adjusted(padding_x, 0, -padding_x, 0), Qt::AlignVCenter | Qt::AlignLeft, text);
    }
    p.restore();
}

void PopupMenu::activate(int index)
{
    if (index < 0 || index >= int(m_items.size()) || is_separator(m_items[index]) || !m_items[index].enabled)
        return;
    // Closed first: the action may open another menu or close the tab this menu was for.
    auto action = std::move(m_items[index].action);
    close();
    action();
}

bool PopupMenu::mouse_press(QPointF p)
{
    if (!m_rect.contains(p)) {
        close();
        return true;
    }
    m_moved = true;
    return false;
}

bool PopupMenu::mouse_release(QPointF p, bool right_button)
{
    if (right_button && !m_moved && (p - m_opened_at).manhattanLength() < 6)
        return false;
    int index = item_at(p);
    if (index < 0)
        return false;
    activate(index);
    return true;
}

bool PopupMenu::mouse_move(QPointF p)
{
    if ((p - m_opened_at).manhattanLength() >= 6)
        m_moved = true;
    int index = item_at(p);
    if (index == m_hover)
        return false;
    m_hover = index;
    return true;
}

void PopupMenu::step(int direction)
{
    int n = int(m_items.size());
    int i = m_hover;
    for (int tries = 0; tries < n; ++tries) {
        i = i < 0 ? (direction > 0 ? 0 : n - 1) : (i + direction + n) % n;
        if (!is_separator(m_items[i]) && m_items[i].enabled) {
            m_hover = i;
            return;
        }
    }
}

bool PopupMenu::key_press(QKeyEvent* event)
{
    switch (event->key()) {
    case Qt::Key_Escape:
        close();
        break;
    case Qt::Key_Down:
    case Qt::Key_Tab:
        step(1);
        break;
    case Qt::Key_Up:
    case Qt::Key_Backtab:
        step(-1);
        break;
    case Qt::Key_Home:
        m_hover = -1;
        step(1);
        break;
    case Qt::Key_End:
        m_hover = -1;
        step(-1);
        break;
    case Qt::Key_Return:
    case Qt::Key_Enter:
    case Qt::Key_Space:
        activate(m_hover);
        break;
    default:
        break;
    }
    return true;
}
