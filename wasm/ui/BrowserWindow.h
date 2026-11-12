/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The browser window: tabs, a toolbar (back, forward, reload, the address field) and the page, all painted with
// QPainter in one QRasterWindow (qt6-wasi has QtGui only, no widgets).

#pragma once

#include "PopupMenu.h"
#include "WebView.h"

#include <QImage>
#include <QRasterWindow>
#include <QString>
#include <QTimer>
#include <memory>
#include <vector>

class BrowserWindow final : public QRasterWindow {
    Q_OBJECT

public:
    explicit BrowserWindow(QStringList const& urls);

    static constexpr int tab_strip_height = 36;
    static constexpr int toolbar_height = 44;
    static constexpr int chrome_height = tab_strip_height + toolbar_height;

protected:
    void paintEvent(QPaintEvent*) override;
    void resizeEvent(QResizeEvent*) override;
    void mousePressEvent(QMouseEvent*) override;
    void mouseReleaseEvent(QMouseEvent*) override;
    void mouseMoveEvent(QMouseEvent*) override;
    void mouseDoubleClickEvent(QMouseEvent*) override;
    void wheelEvent(QWheelEvent*) override;
    void keyPressEvent(QKeyEvent*) override;
    void keyReleaseEvent(QKeyEvent*) override;
    bool event(QEvent*) override;

private:
    struct Tab {
        std::unique_ptr<WebbyUI::WebView> view;
        QString title;
        QString url;
        bool loading { false };
    };

    enum class Hit {
        None,
        Tab,
        TabClose,
        NewTab,
        Back,
        Forward,
        Reload,
        Address,
        Page,
    };
    struct HitResult {
        Hit hit { Hit::None };
        int tab { -1 };
    };

    void new_tab(QString const& url);
    void close_tab(int index);
    void activate_tab(int index);
    Tab* current();
    void sync_from_view();
    void navigate_from_address();
    void focus_address(bool focus);
    void pump();
    // The page's right-click menu (PageMenu.cpp).
    void show_page_menu(WebbyUI::WebView*, WebbyUI::ContextMenu const&);
    bool menu_event(QEvent*);

    HitResult hit_test(QPointF) const;
    QRectF tab_rect(int index) const;
    QRectF tab_close_rect(int index) const;
    QRectF new_tab_rect() const;
    QRectF button_rect(int index) const;
    QRectF address_rect() const;
    QRect page_rect() const;

    void paint_tabs(QPainter&);
    void paint_toolbar(QPainter&);
    void paint_page(QPainter&);
    void paint_status(QPainter&);

    bool address_key(QKeyEvent*);
    int address_index_at(qreal x) const;
    void update_primary_selection();

    std::vector<Tab> m_tabs;
    int m_current { -1 };
    QTimer m_pump_timer;

    bool m_address_focused { false };
    QString m_address_text;
    int m_address_cursor { 0 };
    int m_address_anchor { 0 };

    QString m_hovered_link;
    HitResult m_hover;
    HitResult m_pressed;
    bool m_page_has_mouse { false };
    unsigned m_page_buttons { 0 };
    PopupMenu m_menu;
    bool m_swallow_release { false };
};
