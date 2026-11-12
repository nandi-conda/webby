/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Theme.h"
#include "Dialog.h"

#include <QFontMetricsF>
#include <QKeyEvent>
#include <QPainter>
#include <QPainterPath>

namespace {

QColor const& text_color = WebbyUI::theme().text;
QColor const& dim_text_color = WebbyUI::theme().dim_text;
QColor const& accent = WebbyUI::theme().focus;
QColor const& hover = WebbyUI::theme().hover;

constexpr qreal width = 420;
constexpr qreal padding = 24;
constexpr qreal row_height = 48;
constexpr qreal button_height = 34;

QFont font_of(int size, bool bold = false)
{
    QFont f;
    f.setPixelSize(size);
    f.setBold(bold);
    return f;
}

}

void ModalDialog::open(QString title, QString text, std::vector<Row> rows, QStringList buttons, std::function<void(int)> done)
{
    if (m_open)
        close(-1);
    m_open = true;
    m_title = std::move(title);
    m_text = std::move(text);
    m_rows = std::move(rows);
    m_buttons = std::move(buttons);
    m_done = std::move(done);
    m_hover_row = m_hover_button = -1;
}

void ModalDialog::close(int result)
{
    if (!m_open)
        return;
    m_open = false;
    auto done = std::move(m_done);
    m_done = nullptr;
    if (done)
        done(result);
}

qreal ModalDialog::text_height() const
{
    QFontMetricsF metrics(font_of(14));
    return metrics.boundingRect(QRectF(0, 0, width - 2 * padding, 1000), Qt::TextWordWrap, m_text).height();
}

QRectF ModalDialog::box(QSize window) const
{
    qreal h = padding + 28 + 8 + text_height() + 12 + m_rows.size() * row_height + 16 + button_height + padding;
    qreal w = qMin<qreal>(width, window.width() - 32);
    return { (window.width() - w) / 2, qMax<qreal>(16, (window.height() - h) / 3), w, h };
}

QRectF ModalDialog::row_rect(int index, QSize window) const
{
    auto b = box(window);
    return { b.left() + 12, b.top() + padding + 36 + text_height() + 12 + index * row_height, b.width() - 24, row_height };
}

QRectF ModalDialog::button_rect(int index, QSize window) const
{
    // Right to left: the last button (the one that agrees) at the right edge.
    auto b = box(window);
    QFontMetricsF metrics(font_of(14));
    qreal x = b.right() - padding;
    for (int i = int(m_buttons.size()) - 1; i >= 0; --i) {
        qreal w = metrics.horizontalAdvance(m_buttons[i]) + 32;
        x -= w;
        if (i == index)
            return { x, b.bottom() - padding - button_height, w, button_height };
        x -= 8;
    }
    return {};
}

void ModalDialog::paint(QPainter& p, QSize window) const
{
    if (!m_open)
        return;
    p.save();
    p.fillRect(QRectF(0, 0, window.width(), window.height()), QColor(0, 0, 0, 80));
    auto b = box(window);
    p.setPen(Qt::NoPen);
    p.setBrush(WebbyUI::theme().menu);
    p.drawRoundedRect(b, 12, 12);
    p.setPen(text_color);
    p.setFont(font_of(18, true));
    QFontMetricsF title_metrics(p.font());
    p.drawText(QRectF(b.left() + padding, b.top() + padding, b.width() - 2 * padding, 28), Qt::AlignLeft | Qt::AlignVCenter,
        title_metrics.elidedText(m_title, Qt::ElideRight, b.width() - 2 * padding));
    p.setFont(font_of(14));
    p.setPen(dim_text_color);
    p.drawText(QRectF(b.left() + padding, b.top() + padding + 36, b.width() - 2 * padding, text_height()), Qt::TextWordWrap, m_text);
    for (int i = 0; i < int(m_rows.size()); ++i) {
        auto r = row_rect(i, window);
        if (i == m_hover_row) {
            p.setPen(Qt::NoPen);
            p.setBrush(hover);
            p.drawRoundedRect(r, 8, 8);
        }
        // An account's circle with its initial.
        QRectF circle(r.left() + 10, r.center().y() - 15, 30, 30);
        p.setPen(Qt::NoPen);
        p.setBrush(WebbyUI::theme().selected);
        p.drawEllipse(circle);
        p.setPen(accent);
        p.setFont(font_of(14, true));
        p.drawText(circle, Qt::AlignCenter, m_rows[i].title.left(1).toUpper());
        auto text = r.adjusted(52, 0, -8, 0);
        QFontMetricsF metrics(p.font());
        p.setPen(text_color);
        if (m_rows[i].subtitle.isEmpty()) {
            p.drawText(text, Qt::AlignLeft | Qt::AlignVCenter, metrics.elidedText(m_rows[i].title, Qt::ElideRight, text.width()));
        } else {
            p.drawText(text.adjusted(0, 6, 0, -r.height() / 2), Qt::AlignLeft | Qt::AlignBottom, metrics.elidedText(m_rows[i].title, Qt::ElideRight, text.width()));
            p.setFont(font_of(12));
            p.setPen(dim_text_color);
            p.drawText(text.adjusted(0, r.height() / 2 + 2, 0, 0), Qt::AlignLeft | Qt::AlignTop, QFontMetricsF(p.font()).elidedText(m_rows[i].subtitle, Qt::ElideRight, text.width()));
        }
    }
    p.setFont(font_of(14));
    for (int i = 0; i < int(m_buttons.size()); ++i) {
        auto r = button_rect(i, window);
        bool primary = i == int(m_buttons.size()) - 1 && m_buttons.size() > 1;
        QPainterPath path;
        path.addRoundedRect(r, r.height() / 2, r.height() / 2);
        if (primary) {
            p.fillPath(path, i == m_hover_button ? WebbyUI::theme().deeper(accent) : accent);
            p.setPen(WebbyUI::theme().on_focus);
        } else {
            if (i == m_hover_button)
                p.fillPath(path, hover);
            p.setPen(QPen(WebbyUI::theme().border, 1));
            p.setBrush(Qt::NoBrush);
            p.drawPath(path);
            p.setPen(accent);
        }
        p.drawText(r, Qt::AlignCenter, m_buttons[i]);
    }
    p.restore();
}

bool ModalDialog::mouse_press(QPointF at, QSize window)
{
    if (!m_open)
        return false;
    for (int i = 0; i < int(m_rows.size()); ++i) {
        if (row_rect(i, window).contains(at)) {
            close(row_result + i);
            return true;
        }
    }
    for (int i = 0; i < int(m_buttons.size()); ++i) {
        if (button_rect(i, window).contains(at)) {
            close(i);
            return true;
        }
    }
    return false;
}

bool ModalDialog::mouse_move(QPointF at, QSize window)
{
    int row = -1, button = -1;
    for (int i = 0; i < int(m_rows.size()); ++i) {
        if (row_rect(i, window).contains(at))
            row = i;
    }
    for (int i = 0; i < int(m_buttons.size()); ++i) {
        if (button_rect(i, window).contains(at))
            button = i;
    }
    if (row == m_hover_row && button == m_hover_button)
        return false;
    m_hover_row = row;
    m_hover_button = button;
    return true;
}

bool ModalDialog::key_press(QKeyEvent* event)
{
    if (!m_open)
        return false;
    switch (event->key()) {
    case Qt::Key_Escape:
        close(-1);
        return true;
    case Qt::Key_Return:
    case Qt::Key_Enter:
        // The highlighted row, else the last button (the one that agrees), as a default button.
        if (m_hover_row >= 0)
            close(row_result + m_hover_row);
        else if (!m_rows.empty() && m_rows.size() == 1)
            close(row_result);
        else if (!m_buttons.isEmpty())
            close(int(m_buttons.size()) - 1);
        return true;
    case Qt::Key_Down:
    case Qt::Key_Up:
        if (!m_rows.empty()) {
            int n = int(m_rows.size());
            m_hover_row = event->key() == Qt::Key_Down ? (m_hover_row + 1) % n : (m_hover_row <= 0 ? n - 1 : m_hover_row - 1);
        }
        return true;
    default:
        return true;
    }
}
