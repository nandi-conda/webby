/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// A modal dialog painted with QPainter inside the window (qt6-wasi has no widgets or popup windows), as PopupMenu is:
// a title, a line of text, optional rows to pick from (passkey accounts) and buttons. While it is open the window
// gives it all input.

#pragma once

#include <QRectF>
#include <QSize>
#include <QString>
#include <QStringList>
#include <functional>
#include <vector>

class QKeyEvent;
class QPainter;
class QPointF;

class ModalDialog {
public:
    struct Row {
        QString title;
        QString subtitle;
    };
    static constexpr int row_result = 1000; // a click on row i answers row_result + i

    // `done` gets the button's index, row_result + a row's, or -1 (Escape, or closed by the app).
    void open(QString title, QString text, std::vector<Row> rows, QStringList buttons, std::function<void(int)> done);
    void close(int result = -1);
    bool is_open() const { return m_open; }

    void paint(QPainter&, QSize window) const;
    // Each returns true when the window should repaint.
    bool mouse_press(QPointF, QSize window);
    bool mouse_move(QPointF, QSize window);
    bool key_press(QKeyEvent*);

private:
    QRectF box(QSize window) const;
    QRectF row_rect(int index, QSize window) const;
    QRectF button_rect(int index, QSize window) const;
    qreal text_height() const;

    bool m_open { false };
    QString m_title;
    QString m_text;
    std::vector<Row> m_rows;
    QStringList m_buttons;
    std::function<void(int)> m_done;
    int m_hover_row { -1 };
    int m_hover_button { -1 };
};
