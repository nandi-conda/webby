/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The browser window: tabs, a toolbar (back, forward, reload, the address field) and the page, all painted with
// QPainter in one QRasterWindow (qt6-wasi has QtGui only, no widgets).

#pragma once

#include "PopupMenu.h"
#include "Omnibox.h"
#include "Profile.h"
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
    static constexpr int bookmarks_bar_height = 30;
    // The tabs, the toolbar and (when it is on and has bookmarks) the bookmarks bar.
    int chrome_height() const;

    // The current page in the bookmarks bar, or out of the bookmarks if it is there (Ctrl+D, the star).
    void toggle_bookmark();
    // Opens `url` in a new tab after the current one; `activate` brings it to the front.
    void open_in_new_tab(QString const& url, bool activate);

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
        // Null while a restored tab sleeps: it gets a view (and loads `url`) when it first comes to the front.
        std::unique_ptr<WebbyUI::WebView> view;
        QString title;
        QString url;
        bool loading { false };
        qint64 created { 0 }; // seconds since the epoch, for the age dot
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
        Star,
        Zoom,
        FindField,
        FindPrevious,
        FindNext,
        FindClose,
        Bookmark,
        Suggestion,
        Page,
    };
    struct HitResult {
        Hit hit { Hit::None };
        int tab { -1 };
    };

    void new_tab(QString const& url, int at = -1, bool sleeping = false, QString const& title = {}, qint64 created = 0);
    void wake(Tab&);
    void reopen_closed_tab();
    void save_tabs();
    void open_own_page(QString const& url);
    bool show_bookmarks_bar() const;
    void update_suggestions();
    void hide_suggestions();
    void load_in_current(QString const& url);
    void open_find();
    void close_find();
    void run_find(int direction); // 0: search again from the start, 1: next, -1: previous
    bool find_key(QKeyEvent*);
    void zoom_by(int steps); // 0 resets
    QRectF find_rect() const;
    QRectF find_button_rect(int index) const; // 0 previous, 1 next, 2 close
    QRectF zoom_rect() const;
    void paint_find(QPainter&);
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
    QRectF star_rect() const;
    QRectF bookmark_rect(int index) const;
    QRectF suggestion_rect(int index) const;
    QRect page_rect() const;

    void paint_tabs(QPainter&);
    void paint_toolbar(QPainter&);
    void paint_page(QPainter&);
    void paint_status(QPainter&);
    void paint_bookmarks_bar(QPainter&);
    void paint_suggestions(QPainter&);

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

    QList<WebbyUI::Profile::SavedTab> m_closed; // for Ctrl+Shift+T, newest last
    QList<WebbyUI::Omnibox::Suggestion> m_suggestions;
    int m_suggestion { -1 }; // the highlighted suggestion, -1 for none (Return loads the typed text)
    QString m_typed_text; // what was typed before Up/Down put a suggestion in the field
    QTimer m_save_timer;

    // The find bar (Ctrl+F), over the page's top right corner.
    bool m_find_open { false };
    bool m_find_focused { false }; // keys go to the find field
    QString m_find_text;
    WebbyUI::WebView::FindResult m_find_result;

    // Dragging a tab along the strip.
    bool m_dragging_tab { false };
    qreal m_press_x { 0 };
    qreal m_drag_offset { 0 };
};
