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
#include <QPolygonF>

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

bool is_separator(PopupMenu::Item const& item) { return !item.action && !item.submenu && !item.heading; }
bool is_active(PopupMenu::Item const& item) { return !is_separator(item) && !item.heading && item.enabled; }

constexpr qreal check_gutter = 26;
constexpr qreal shortcut_gap = 32;
QColor const dim_color { 0x5f, 0x63, 0x68 };

}

void PopupMenu::add(QString label, std::function<void()> action, bool enabled)
{
    m_items.push_back({ std::move(label), std::move(action), enabled });
}

void PopupMenu::add(QString label, QString shortcut, std::function<void()> action, bool enabled)
{
    m_items.push_back({ std::move(label), std::move(action), enabled, std::move(shortcut) });
}

void PopupMenu::add_check(QString label, bool checked, QString shortcut, std::function<void()> action)
{
    m_items.push_back({ std::move(label), std::move(action), true, std::move(shortcut), checked ? 1 : 0 });
}

PopupMenu& PopupMenu::add_submenu(QString label)
{
    Item item { std::move(label), {}, true };
    item.submenu = std::make_shared<PopupMenu>();
    item.submenu->m_parent = this;
    m_items.push_back(item);
    return *m_items.back().submenu;
}

void PopupMenu::add_heading(QString label)
{
    Item item { std::move(label), {}, false };
    item.heading = true;
    m_items.push_back(std::move(item));
}

PopupMenu& PopupMenu::root()
{
    auto* menu = this;
    while (menu->m_parent)
        menu = menu->m_parent;
    return *menu;
}

void PopupMenu::add_separator()
{
    if (!m_items.empty() && !is_separator(m_items.back()))
        m_items.push_back({});
}

void PopupMenu::open(QPointF at, QSize window)
{
    // Empty submenus go, then separators left at either end or doubled.
    std::erase_if(m_items, [](Item const& item) { return item.submenu && item.submenu->empty(); });
    for (size_t i = 1; i < m_items.size(); ++i) {
        if (is_separator(m_items[i]) && is_separator(m_items[i - 1]))
            m_items.erase(m_items.begin() + i--);
    }
    while (!m_items.empty() && is_separator(m_items.back()))
        m_items.pop_back();
    while (!m_items.empty() && is_separator(m_items.front()))
        m_items.erase(m_items.begin());
    if (m_items.empty())
        return;
    QFontMetricsF metrics(menu_font());
    qreal width = min_width;
    qreal height = padding_y * 2;
    for (auto const& item : m_items) {
        height += is_separator(item) ? separator_height : row_height;
        if (!is_separator(item)) {
            qreal w = metrics.horizontalAdvance(item.label) + padding_x * 2 + 8 + check_gutter;
            if (!item.shortcut.isEmpty())
                w += shortcut_gap + metrics.horizontalAdvance(item.shortcut);
            if (item.submenu)
                w += 20;
            width = qMax(width, w);
        }
    }
    m_window = window;
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
    m_child = nullptr;
    m_child_index = -1;
    m_open = false;
    m_items.clear();
    m_hover = -1;
}

void PopupMenu::open_submenu(int index)
{
    if (index == m_child_index && m_child)
        return;
    close_submenu();
    if (index < 0 || !m_items[index].submenu)
        return;
    m_child = m_items[index].submenu;
    m_child_index = index;
    auto row = item_rect(index);
    // Beside the row, on the right unless that leaves the window; the submenu works out its own height.
    m_child->open({ row.right() - 4, row.top() - padding_y }, m_window);
    if (m_child->m_rect.left() < row.right() - 8) {
        qreal x = qMax<qreal>(0, m_rect.left() - m_child->m_rect.width() + 4);
        m_child->m_rect.moveLeft(x);
    }
}

void PopupMenu::close_submenu()
{
    if (!m_child)
        return;
    // Opened again from the same item next time: keep its items, drop only its open state.
    m_child->m_child = nullptr;
    m_child->m_child_index = -1;
    m_child->m_open = false;
    m_child->m_hover = -1;
    m_child = nullptr;
    m_child_index = -1;
}

bool PopupMenu::contains(QPointF p) const
{
    return m_rect.contains(p) || (m_child && m_child->contains(p));
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
            return is_active(m_items[i]) ? i : -1;
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
        if (i == m_child_index && i != m_hover) {
            p.setPen(Qt::NoPen);
            p.setBrush(hover_color);
            p.drawRect(r.adjusted(1, 0, -1, 0));
        }
        if (item.check >= 0) {
            QRectF box(r.left() + padding_x - 4, r.center().y() - 7, 14, 14);
            p.setPen(QPen(item.check ? QColor(0x1a, 0x73, 0xe8) : dim_color, 1.3));
            p.setBrush(item.check ? QColor(0x1a, 0x73, 0xe8) : Qt::transparent);
            p.drawRoundedRect(box, 3, 3);
            if (item.check) {
                p.setPen(QPen(Qt::white, 1.8, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
                p.drawLine(box.center() + QPointF(-4, 0), box.center() + QPointF(-1, 3));
                p.drawLine(box.center() + QPointF(-1, 3), box.center() + QPointF(4, -3));
            }
        }
        auto inner = r.adjusted(padding_x + check_gutter, 0, -padding_x, 0);
        qreal right = 0;
        if (item.submenu) {
            p.setPen(Qt::NoPen);
            p.setBrush(text_color);
            auto c = QPointF(inner.right() - 4, r.center().y());
            QPolygonF arrow;
            arrow << c + QPointF(-3, -5) << c + QPointF(3, 0) << c + QPointF(-3, 5);
            p.drawPolygon(arrow);
            right = 16;
        } else if (!item.shortcut.isEmpty()) {
            p.setPen(dim_color);
            p.drawText(inner, Qt::AlignVCenter | Qt::AlignRight, item.shortcut);
            right = metrics.horizontalAdvance(item.shortcut) + shortcut_gap;
        }
        p.setPen(item.heading ? dim_color : item.enabled ? text_color : disabled_color);
        auto label_rect = item.heading ? r.adjusted(padding_x, 0, -padding_x, 0) : inner.adjusted(0, 0, -right, 0);
        auto text = metrics.elidedText(item.label, Qt::ElideRight, label_rect.width());
        p.drawText(label_rect, Qt::AlignVCenter | Qt::AlignLeft, text);
    }
    p.restore();
    if (m_child)
        m_child->paint(p);
}

void PopupMenu::activate(int index)
{
    if (index < 0 || index >= int(m_items.size()) || !is_active(m_items[index]))
        return;
    if (m_items[index].submenu) {
        open_submenu(index);
        if (m_child) {
            m_child->m_hover = -1;
            m_child->step(1);
        }
        return;
    }
    // Closed first (the whole menu, from its top): the action may open another menu or close the tab it was for.
    auto action = std::move(m_items[index].action);
    root().close();
    if (action)
        action();
}

bool PopupMenu::mouse_press(QPointF p)
{
    if (m_child && m_child->contains(p))
        return m_child->mouse_press(p);
    if (!contains(p)) {
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
    if (m_child && m_child->contains(p))
        return m_child->mouse_release(p, right_button);
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
    if (m_child && m_child->contains(p)) {
        m_child->m_moved = true;
        return m_child->mouse_move(p);
    }
    int index = item_at(p);
    if (index == m_hover)
        return false;
    m_hover = index;
    // Resting on a row with a submenu opens it; another row closes it. Off the menu, it stays.
    if (index >= 0)
        m_items[index].submenu ? open_submenu(index) : close_submenu();
    return true;
}

void PopupMenu::step(int direction)
{
    int n = int(m_items.size());
    int i = m_hover;
    for (int tries = 0; tries < n; ++tries) {
        i = i < 0 ? (direction > 0 ? 0 : n - 1) : (i + direction + n) % n;
        if (is_active(m_items[i])) {
            m_hover = i;
            return;
        }
    }
}

bool PopupMenu::key_press(QKeyEvent* event)
{
    if (m_child && m_child->m_hover >= 0) {
        if (event->key() == Qt::Key_Left || event->key() == Qt::Key_Escape) {
            close_submenu();
            return true;
        }
        return m_child->key_press(event);
    }
    switch (event->key()) {
    case Qt::Key_Right:
        if (m_hover >= 0 && m_items[m_hover].submenu)
            activate(m_hover);
        break;
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
