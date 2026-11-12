/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The browser window: tabs, a toolbar (back, forward, reload, the address field) and the page, all painted with
// QPainter in one QRasterWindow (qt6-wasi has QtGui only, no widgets).

#pragma once

#include "Dialog.h"
#include "PageFrame.h"
#include "PdfView.h"
#include "PopupMenu.h"
#include "Omnibox.h"
#include "Profile.h"
#include "Summarize.h"
#include "WebView.h"

#include <QImage>
#include <QJsonObject>
#include <QRasterWindow>
#include <QString>
#include <QTimer>
#include <map>
#include <memory>
#include <vector>

struct SummaryJob;

class BrowserWindow final : public QRasterWindow {
    Q_OBJECT

public:
    explicit BrowserWindow(QStringList const& urls);

    static constexpr int tab_strip_height = 36;
    static constexpr int toolbar_height = 44;
    static constexpr int bookmarks_bar_height = 30;
    static constexpr int password_bar_height = 40;
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
    // Loads the Sync and Tabs from other devices pages again where they are open and have changed.
    void refresh_sync_pages();

    struct Tab {
        // Null while a restored tab sleeps: it gets a view (and loads `url`) when it first comes to the front.
        std::unique_ptr<WebbyUI::WebView> view;
        QString title;
        QString url;
        bool loading { false };
        qint64 created { 0 }; // seconds since the epoch, for the age dot
        // While the view's page is a PDF: the viewer, shown in place of the page (PdfView.h).
        std::unique_ptr<WebbyUI::PdfView> pdf {};
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
        Toolbar, // a button right of the address field; `tab` is its index (ToolbarButton)
        FindField,
        FindPrevious,
        FindNext,
        FindClose,
        Bookmark,
        Suggestion,
        PasswordBar, // a button of the password bar; `tab` is its index
        Panel,       // the Summarize / Ask AI side panel
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
    // Saved sessions (Sessions.h, SessionsPage.cpp), as the Nim front end has them.
    QList<WebbyUI::Profile::SavedTab> open_tabs() const;
    // Saves the open tabs as a session called `name` (the date when empty); `close_all` then closes them, leaving
    // one blank tab.
    void save_open_tabs_as_session(bool close_all, QString const& name = {});
    // Opens a session's tabs next to the current one (a blank current tab takes the first), `front` shown.
    void restore_session(QList<WebbyUI::Profile::SavedTab> const& tabs, int front);
    // Closing the window keeps its tabs as a session, without asking (once).
    void save_session_on_quit();
    void refresh_sessions_page();
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
    void paint_toast(QPainter&);

    // The buttons right of the address field, as the Nim front end's toolbar has them (right to left).
    enum ToolbarButton { ButtonMore, ButtonDownloads, ButtonHistory, ButtonBookmarks, ButtonSessions, ButtonCloseAndSave, ButtonSummarize, ButtonCount };
    QRectF toolbar_button_rect(int button) const;
    void paint_toolbar_buttons(QPainter&);
    void toolbar_button(int button);
    // The ⋮ menu, built each time it opens, grouped as the Nim front end's (nim/src/browser.nim MenuGroup).
    void open_more_menu();
    void show_toast(QString const& text);
    void close_tab(int index);
    void activate_tab(int index);
    Tab* current();
    void sync_from_view();
    void navigate_from_address();
    void focus_address(bool focus);
    void pump();
    // The page's right-click menu (PageMenu.cpp).
    void show_page_menu(WebbyUI::WebView*, WebbyUI::ContextMenu const&);
    // PDFs (PdfView): the view handed one over; its right-click menu; Save (Ctrl+S, the bar's button).
    void open_pdf(WebbyUI::WebView*, WebbyUI::PdfDocument&);
    void show_pdf_menu(QPointF at);
    void save_pdf(Tab&);
    WebbyUI::PdfView* current_pdf();
    bool menu_event(QEvent*);

    // Passwords and passkeys (PasswordBar.cpp, Passwords.h): the save / fill / generate bar under the toolbar and the
    // passkey dialog.
    struct BarButton {
        QString label;
        QRectF rect;
        bool primary { false };
    };
    void setup_passwords();
    bool show_password_bar() const;
    QRectF password_bar_rect() const;
    std::vector<BarButton> password_bar_buttons() const;
    void paint_password_bar(QPainter&);
    void password_bar_click(int button);
    void password_offer_changed(WebbyUI::WebView*);
    void show_passkey_dialog(WebbyUI::WebView*, QJsonObject const& prompt);
    void next_passkey_dialog();
    bool dialog_event(QEvent*);
    void open_passwords_page();

    // Summarize and Ask AI (SummaryPanel.cpp, Summarize.h): a job per tab, and the side panel showing the current
    // tab's, a page of its own in m_panel beside (or under) the page.
    void summarize_page();
    void toggle_summary();
    void close_summary();
    void open_summarize_settings();
    void ask_about_selection(WebbyUI::WebView*, QString const& text);
    SummaryJob* panel_job() const;
    bool panel_showing() const;
    QRect panel_rect() const;
    void relayout_panel();
    void paint_panel(QPainter&);
    void ensure_panel();
    void render_panel();
    void send_panel_state();
    void panel_message(QString const&);
    void job_changed(SummaryJob&);
    std::shared_ptr<SummaryJob> job_for(WebbyUI::WebView*);
    void start_summary(std::shared_ptr<SummaryJob> const&, bool fresh);
    void ask_question(std::shared_ptr<SummaryJob> const&, QString const& question);
    void read_page_text(WebbyUI::WebView*, bool whole_page, std::function<void(bool, WebbyUI::Summarize::PageText const&)>);
    void hook_summarize(WebbyUI::WebView&);
    void forget_summary(WebbyUI::WebView*);
    void summary_jump(SummaryJob&, QString const& words);
    void summary_jump_elsewhere(SummaryJob&, QString const& words);
    void run_summary_jump(WebbyUI::WebView*, QString const& words, int retries, bool click);

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
    void apply_color_scheme();
    void paint_status(QPainter&);
    QRect status_rect() const;

    // The page's pixels reach the window in frames: a view that changed asks for one (request_page_frame), and at the
    // window's next update the frame is taken and only what it changed is repainted (prepare_page_frame, PageFrame).
    void request_page_frame();
    void prepare_page_frame();
    // What the window paints over the page (the hovered link's box, the find bar): a scroll moves it along with the
    // page, so it is painted again where it is. Anything new drawn over the page goes here too.
    QRegion page_overlays() const;
    // The page's viewport scrollbars, drawn over it (in Ladybird its Compositor draws them): those of the frame on
    // screen, and the window area they cover.
    void paint_page_scrollbars(QPainter&);
    QRegion scrollbar_region(std::vector<WebbyUI::WebView::Scrollbar> const&) const;
    void play_test_input();
    Qt::MouseButtons m_test_buttons;
    void paint_bookmarks_bar(QPainter&);
    void paint_suggestions(QPainter&);
    QRect suggestions_box() const;
    QRegion chrome_region() const;
    void update_chrome();
    void update_address();
    bool needs_paint(QRectF const&) const;

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
    ModalDialog m_dialog;
    WebbyUI::WebView* m_dialog_view { nullptr }; // the passkey dialog's page
    std::vector<std::pair<WebbyUI::WebView*, QJsonObject>> m_passkey_requests; // waiting behind the open dialog
    bool m_swallow_release { false };

    QList<WebbyUI::Profile::SavedTab> m_closed; // for Ctrl+Shift+T, newest last
    bool m_quit_saved { false };
    QList<WebbyUI::Omnibox::Suggestion> m_suggestions;
    int m_suggestion { -1 }; // the highlighted suggestion, -1 for none (Return loads the typed text)
    QString m_typed_text; // what was typed before Up/Down put a suggestion in the field
    QTimer m_save_timer;

    // A short note at the bottom of the window ("Downloaded …"), gone after a few seconds.
    QString m_toast;
    QTimer m_toast_timer;

    // The find bar (Ctrl+F), over the page's top right corner.
    bool m_find_open { false };
    bool m_find_focused { false }; // keys go to the find field
    QString m_find_text;
    WebbyUI::WebView::FindResult m_find_result;

    // Dragging a tab along the strip.
    bool m_dragging_tab { false };
    qreal m_press_x { 0 };
    qreal m_drag_offset { 0 };

    WebbyUI::PageFrame m_page_frame;
    QImage m_page_image; // the frame on screen (the view's own pixels, valid until its next paint)
    bool m_page_dirty { true };
    QRect m_status_painted;
    std::vector<WebbyUI::WebView::Scrollbar> m_page_scrollbars;
    QRect m_suggestions_painted; // where paint_suggestions last drew its box
    QRegion m_paint_region;      // what the paint in progress repaints (needs_paint skips the rest)

    std::map<WebbyUI::WebView*, std::shared_ptr<SummaryJob>> m_jobs;
    std::unique_ptr<WebbyUI::WebView> m_panel;
    bool m_panel_ready { false };
    bool m_panel_focused { false }; // keys go to the panel
    bool m_panel_has_mouse { false };
    bool m_panel_render_queued { false };
    bool m_panel_open_settings { false };
    bool m_panel_focus_entry { false };
    bool m_panel_scroll_to_end { false };
    std::pair<WebbyUI::WebView*, QString> m_pending_jump { nullptr, {} }; // a source link waiting for its page to load
};
