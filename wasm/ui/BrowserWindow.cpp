/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Theme.h"
#include "BrowserWindow.h"
#include "KeyMap.h"
#include "Pages.h"
#include "Passwords.h"
#include "Sessions.h"
#include "Sync.h"

#include <QDir>
#include <QFile>
#include <QFontMetricsF>
#include <QGuiApplication>
#include <QInputMethod>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QPolygonF>
#include <QStyleHints>
#include <QTimer>
#include <QUrl>
#include <QWheelEvent>
#include <QtMath>
#include <cmath>
#include <cstdlib>
#include <qt2wasm/gui.h>

using namespace WebbyUI;

namespace {

// Light chrome, close to the Nim desktop front end's.
QColor const& strip_color = WebbyUI::theme().strip;
QColor const& tab_color = WebbyUI::theme().tab;
QColor const& tab_hover_color = WebbyUI::theme().tab_hover;
QColor const& text_color = WebbyUI::theme().text;
QColor const& dim_text_color = WebbyUI::theme().dim_text;
QColor const& field_color = WebbyUI::theme().field;
QColor const& focus_color = WebbyUI::theme().focus;
QColor const& button_hover_color = WebbyUI::theme().button_hover;
QColor const& disabled_color = WebbyUI::theme().disabled;
QColor const& star_color = WebbyUI::theme().star;
QColor const& age_color = WebbyUI::theme().age;

// The age dot's steps (seconds), as the Nim strip's ageSteps: strongest when just opened, gone after 12 hours.
constexpr qint64 age_steps[] = { 5 * 60, 20 * 60, 3600, 3 * 3600, 12 * 3600 };

constexpr int max_tab_width = 220;
constexpr int min_tab_width = 72;
constexpr int button_size = 32;
// Pinned tabs: tiles this wide in the strip; in the sidebar, rows of this many tiles this tall (the Nim strip's).
constexpr int pinned_tile_width = 40;
constexpr int sidebar_tiles_per_row = 5;
constexpr int sidebar_tile_height = 36;
constexpr int sidebar_row_height = 34;

// A pinned tile without an icon shows its site's letter on one of eight colors, the same for a site every time (the
// Nim strip's badgeColor and its .webby-badge-N colors).
QColor badge_color(QString const& host)
{
    static QColor const colors[] = { QColor(0xc5, 0x22, 0x1f), QColor(0xb0, 0x60, 0x00), QColor(0x13, 0x73, 0x33),
        QColor(0x19, 0x67, 0xd2), QColor(0x84, 0x30, 0xce), QColor(0x00, 0x7b, 0x83), QColor(0xc2, 0x18, 0x5b),
        QColor(0x5f, 0x63, 0x68) };
    quint32 h = 0;
    for (auto c : host.toLower().toUtf8())
        h = h * 31 + quint32(quint8(c));
    return colors[h % 8];
}

unsigned web_button(Qt::MouseButton button)
{
    switch (button) {
    case Qt::LeftButton:
        return WebbyUI::ButtonPrimary;
    case Qt::RightButton:
        return WebbyUI::ButtonSecondary;
    case Qt::MiddleButton:
        return WebbyUI::ButtonMiddle;
    case Qt::BackButton:
        return WebbyUI::ButtonBackward;
    case Qt::ForwardButton:
        return WebbyUI::ButtonForward;
    default:
        return WebbyUI::ButtonNone;
    }
}

unsigned web_buttons(Qt::MouseButtons buttons)
{
    unsigned result = 0;
    for (auto b : { Qt::LeftButton, Qt::RightButton, Qt::MiddleButton, Qt::BackButton, Qt::ForwardButton }) {
        if (buttons & b)
            result |= web_button(b);
    }
    return result;
}

QString from_std(std::string const& s) { return QString::fromUtf8(s.data(), qsizetype(s.size())); }
std::string to_std(QString const& s) { return s.toUtf8().toStdString(); }

}

BrowserWindow::BrowserWindow(QStringList const& urls)
{
    setTitle(QStringLiteral("webby"));
    setMinimumSize({ 480, 320 });
    // The engine's event loop (timers, tasks, the page's deferred work) runs between the host's calls.
    m_pump_timer.setInterval(8);
    QObject::connect(&m_pump_timer, &QTimer::timeout, this, [this] { pump(); });
    m_pump_timer.start();
    // The open tabs are saved a moment after they change, for the next start.
    m_save_timer.setSingleShot(true);
    m_save_timer.setInterval(500);
    QObject::connect(&m_save_timer, &QTimer::timeout, this, [this] { save_tabs(); });
    m_memory_timer.setInterval(500);
    QObject::connect(&m_memory_timer, &QTimer::timeout, this, [this] { check_memory(); });
    m_memory_timer.start();
    m_toast_timer.setSingleShot(true);
    m_toast_timer.setInterval(6000);
    QObject::connect(&m_toast_timer, &QTimer::timeout, this, [this] {
        m_toast.clear();
        update();
    });
    setup_passwords();

    // Light or dark as the desktop is, and again whenever it changes (latha:gui's app.color-scheme): the chrome's
    // colors and pages' prefers-color-scheme.
    apply_color_scheme();
    QObject::connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this, [this] { apply_color_scheme(); });

    // With no URLs given, last time's tabs come back, asleep until they come to the front (as in the Nim front end).
    int active = 0;
    if (urls.isEmpty() && qEnvironmentVariable("WEBBY_RESTORE_TABS") != u"0" && Profile::ui_setting(QStringLiteral("restoreTabs")).toBool(true)) {
        int pinned = 0;
        auto saved = Profile::read_open_tabs(active, pinned);
        for (auto const& tab : saved) {
            new_tab(tab.url, -1, true, tab.title, tab.created);
            m_tabs.back().pinned = int(m_tabs.size()) <= pinned;
        }
    }
    bool blank = urls.isEmpty() && m_tabs.empty();
    if (blank)
        new_tab({});
    for (auto const& url : urls)
        new_tab(url);
    activate_tab(active);
    if (blank)
        focus_address(true);
    play_test_input();

    // Sync (Sync.h): its pages follow its state, and the bookmarks bar follows bookmarks that sync brings in.
    WebbyUI::Sync::on_status([this] { refresh_sync_pages(); });
    WebbyUI::Sync::on_devices([this] { refresh_sync_pages(); });
    // An open Sessions page follows the sessions (a change here, or one sync brought in). After the action that
    // changed them has shown the page, so a page that already says it is not loaded twice.
    WebbyUI::Sessions::on_change([this] { QTimer::singleShot(0, this, [this] { refresh_sync_pages(); }); });
    // Closing the window keeps its tabs as a session.
    QObject::connect(qApp, &QCoreApplication::aboutToQuit, this, [this] { save_session_on_quit(); });
    Profile::Bookmarks::the().on_change([this] {
        resizeEvent(nullptr);
        update();
    });
    // Once the first page has set the network up.
    QTimer::singleShot(3000, this, [] { WebbyUI::Sync::start(); });
}

void BrowserWindow::refresh_sync_pages()
{
    for (auto& tab : m_tabs) {
        if (!tab.view)
            continue;
        auto url = from_std(tab.view->url());
        if (url != Pages::sync_page_url() && url != Pages::devices_page_url() && url != Pages::sessions_page_url())
            continue;
        // Written again; loaded again only when it says something new (a reload would empty a form being filled in).
        auto path = QUrl(url).toLocalFile();
        QByteArray before;
        if (QFile f(path); f.open(QIODevice::ReadOnly))
            before = f.readAll();
        Pages::refresh(url);
        QByteArray after;
        if (QFile f(path); f.open(QIODevice::ReadOnly))
            after = f.readAll();
        if (after != before)
            tab.view->load(to_std(url));
    }
}

bool BrowserWindow::vertical_tabs() const
{
    return Profile::vertical_tabs();
}

int BrowserWindow::toolbar_top() const
{
    return vertical_tabs() ? 0 : tab_strip_height;
}

int BrowserWindow::chrome_height() const
{
    return toolbar_top() + toolbar_height + (show_bookmarks_bar() ? bookmarks_bar_height : 0) + (show_password_bar() ? password_bar_height : 0);
}

bool BrowserWindow::show_bookmarks_bar() const
{
    auto const& b = Profile::Bookmarks::the();
    return b.show_bar() && !b.bar().children.isEmpty();
}

BrowserWindow::Tab* BrowserWindow::current()
{
    if (m_current < 0 || m_current >= int(m_tabs.size()))
        return nullptr;
    return &m_tabs[m_current];
}

void BrowserWindow::new_tab(QString const& url, int at, bool sleeping, QString const& title, qint64 created)
{
    if (at < 0 || at > int(m_tabs.size()))
        at = int(m_tabs.size());
    // A new tab is never among the pinned ones.
    at = qMax(at, pinned_count());
    if (at <= m_current)
        ++m_current;
    m_tabs.insert(m_tabs.begin() + at, Tab { nullptr, title.isEmpty() ? (url.isEmpty() ? QStringLiteral("New Tab") : url) : title, url, false, created > 0 ? created : Profile::now_seconds() });
    if (!sleeping)
        wake(m_tabs[at]);
    m_save_timer.start();
    update();
}

void BrowserWindow::wake(Tab& tab)
{
    if (tab.view)
        return;
    auto page = page_rect();
    auto view = WebbyUI::WebView::create(page.width(), page.height());
    if (!view)
        return;
    auto* raw = view.get();
    auto url = tab.url;
    // Only the tab in front renders (see WebView::set_visible); activate_tab shows it when it comes forward.
    raw->set_visible(current() == &tab);
    tab.view = std::move(view);
    raw->on_needs_paint = [this, raw] {
        if (current() && current()->view.get() == raw)
            request_page_frame();
    };
    raw->on_title_change = [this, raw](std::string const& title) {
        Profile::History::the().set_title(from_std(raw->url()), from_std(title).simplified());
        sync_from_view();
    };
    raw->on_url_change = [this, raw](std::string const& u) {
        // The PDF viewer shows while the view stays on the PDF's URL (back, a link or a new address leave it).
        for (auto& t : m_tabs) {
            if (t.view.get() == raw && t.pdf && t.pdf->url() != from_std(u)) {
                t.pdf.reset();
                if (current() == &t) {
                    m_page_frame.invalidate();
                    m_hovered_link.clear();
                    request_page_frame();
                }
            }
        }
        if (current() && current()->view.get() == raw && !m_address_focused)
            m_address_text = from_std(u);
        Profile::History::the().add(from_std(u), from_std(raw->title()).simplified());
        PasswordManager::the().url_changed(raw);
        sync_from_view();
        m_save_timer.start();
    };
    raw->on_loading_change = [this](bool) { sync_from_view(); };
    raw->on_link_hover = [this, raw](std::string const& link) {
        if (current() && current()->view.get() == raw) {
            auto was = status_rect();
            m_hovered_link = from_std(link);
            update(QRegion(was) | status_rect());
        }
    };
    // The page's copies and pastes go to the host's clipboard (qt6-wasi has no QClipboard; qt2wasm asks the host).
    raw->on_clipboard_write = [](std::string const& text, bool selection) {
        auto q = from_std(text);
        selection ? qt2wasm::gui::setPrimaryText(q) : qt2wasm::gui::setClipboardText(q);
    };
    raw->on_clipboard_request = [raw](uint64_t request, bool selection) {
        raw->answer_clipboard(request, to_std(selection ? qt2wasm::gui::primaryText() : qt2wasm::gui::clipboardText()));
    };
    raw->on_download = [this](WebbyUI::Download const& d) {
        Profile::DownloadRecord record { from_std(d.url), from_std(d.path), qint64(d.size), from_std(d.mime), from_std(d.error), Profile::now_ms() };
        Profile::add_download(record);
        if (d.error.empty())
            show_toast(QStringLiteral("Downloaded %1 to %2  ·  Ctrl+J").arg(record.path.section(u'/', -1), record.path.section(u'/', 0, -2)));
        else
            show_toast(QStringLiteral("Download failed: %1").arg(record.error));
    };
    raw->on_context_menu = [this, raw](WebbyUI::ContextMenu const& menu) { show_page_menu(raw, menu); };
    raw->on_pdf = [this, raw](WebbyUI::PdfDocument& pdf) { open_pdf(raw, pdf); };
    PasswordManager::the().attach(*raw);
    hook_summarize(*raw);
    raw->on_navigation_request = [this, raw](std::string const& u) {
        auto url = from_std(u);
        if (Pages::is_sessions_action(url)) {
            auto action = Pages::run_sessions_action(url);
            // Later: closing every tab closes this view, which is still answering its navigation.
            QTimer::singleShot(0, this, [this, raw, action] {
                bool alive = false;
                for (auto const& t : m_tabs)
                    alive |= t.view.get() == raw;
                if (action.save != Pages::SessionsAction::Save::None)
                    save_open_tabs_as_session(action.save == Pages::SessionsAction::Save::CloseAll, action.name);
                if (!action.open.isEmpty())
                    restore_session(action.open, action.front);
                bool still = false;
                for (auto const& t : m_tabs)
                    still |= t.view.get() == raw;
                if (alive && still && !action.load.isEmpty())
                    raw->load(to_std(Pages::refresh(action.load)));
            });
            return true;
        }
        if (!Pages::is_sync_action(url))
            return false;
        auto action = Pages::run_sync_action(url);
        if (!action.copy.isEmpty()) {
            qt2wasm::gui::setClipboardText(action.copy);
            show_toast(QStringLiteral("Copied"));
        }
        for (auto const& open : action.open)
            open_in_new_tab(open, false);
        if (!action.load.isEmpty())
            raw->load(to_std(Pages::refresh(action.load)));
        return true;
    };
    raw->load(to_std(Pages::is_own_page(url) ? Pages::refresh(url) : url));
}

void BrowserWindow::open_in_new_tab(QString const& url, bool activate)
{
    int at = m_current + 1;
    new_tab(url, at);
    if (activate)
        activate_tab(at);
}

void BrowserWindow::reopen_closed_tab()
{
    if (m_closed.isEmpty())
        return;
    auto tab = m_closed.takeLast();
    int at = int(m_tabs.size());
    new_tab(tab.url, at, false, tab.title, tab.created);
    activate_tab(at);
}

void BrowserWindow::save_tabs()
{
    QList<Profile::SavedTab> tabs;
    for (auto const& tab : m_tabs)
        tabs.append({ tab.title, tab.url, tab.created });
    Profile::write_open_tabs(tabs, m_current, pinned_count());
    // Other devices see them under Tabs from other devices.
    QList<WebbyUI::Sync::DeviceTab> shared;
    for (auto const& tab : m_tabs)
        shared.append({ tab.title, tab.url });
    WebbyUI::Sync::set_tabs(shared);
}

QList<Profile::SavedTab> BrowserWindow::open_tabs() const
{
    QList<Profile::SavedTab> tabs;
    for (auto const& tab : m_tabs)
        tabs.append({ tab.title, tab.url, 0 });
    return tabs;
}

void BrowserWindow::save_open_tabs_as_session(bool close_all, QString const& name)
{
    auto tabs = open_tabs();
    auto id = WebbyUI::Sessions::save(tabs, close_all ? QString() : name, m_current);
    if (id.isEmpty()) {
        show_toast(QStringLiteral("There are no open pages to save"));
        return;
    }
    if (close_all) {
        // Every tab goes; one blank tab stays.
        new_tab({}, int(m_tabs.size()));
        while (m_tabs.size() > 1)
            close_tab(0);
        activate_tab(0);
        focus_address(true);
    }
    auto const* s = WebbyUI::Sessions::find(id);
    show_toast(QStringLiteral("Saved session \"%1\"").arg(s ? s->name : QString()));
}

void BrowserWindow::restore_session(QList<Profile::SavedTab> const& tabs, int front)
{
    if (tabs.isEmpty())
        return;
    auto* cur = current();
    bool blank = cur && cur->view && (cur->url.isEmpty() || cur->url == u"about:blank");
    int at = blank ? m_current : m_current + 1;
    int front_index = -1;
    for (int i = 0; i < tabs.size(); ++i) {
        if (i == 0 && blank) {
            load_in_current(tabs[i].url);
        } else {
            // In the background asleep, like restored tabs at start; the front one loads.
            new_tab(tabs[i].url, at, i != front, tabs[i].title);
        }
        if (i == front)
            front_index = at;
        ++at;
    }
    if (front_index >= 0)
        activate_tab(front_index);
    update();
}

void BrowserWindow::save_session_on_quit()
{
    if (m_quit_saved)
        return;
    m_quit_saved = true;
    WebbyUI::Sessions::save(open_tabs(), {}, m_current);
}

// The engine's memory is one wasm32 linear memory (4 GiB at most) for every tab. When its GC runs short of room, the
// background tab shown longest ago goes back to sleep (as restored tabs start: its URL and title stay, and it loads
// again when it comes to the front) and the heap is collected; one every half second while the pressure lasts. When only the
// front tab is left and even the GC's reserve went, that tab is stopped and loaded afresh, so one page that eats all
// memory costs its own state, not the whole browser.
void BrowserWindow::check_memory()
{
    static bool const log = qEnvironmentVariable("WEBBY_MEMORY_LOG") == u"1";
    static int ticks = 0;
    if (log && ++ticks % 60 == 1)
        qInfo("webby: %s", WebbyUI::WebView::memory_report().c_str());
    auto state = WebbyUI::WebView::take_memory_pressure();
    if (!state.pressure)
        return;
    int oldest = -1;
    // Pinned tabs sleep last (the Nim strip never discards them).
    for (int i = 0; i < int(m_tabs.size()); ++i) {
        if (i == m_current || !m_tabs[i].view)
            continue;
        if (oldest < 0 || std::pair(m_tabs[i].pinned, m_tabs[i].last_shown) < std::pair(m_tabs[oldest].pinned, m_tabs[oldest].last_shown))
            oldest = i;
    }
    if (oldest >= 0) {
        qInfo("webby: memory is running low, the background tab \"%s\" goes to sleep (%s)", qPrintable(m_tabs[oldest].url), WebbyUI::WebView::memory_report().c_str());
        sleep_tab(oldest);
        WebbyUI::WebView::collect_garbage();
        return;
    }
    WebbyUI::WebView::collect_garbage();
    if (state.critical && current() && current()->view) {
        qWarning("webby: memory ran out with only the front tab awake: it is loaded again (%s)", WebbyUI::WebView::memory_report().c_str());
        sleep_tab(m_current);
        WebbyUI::WebView::collect_garbage();
        activate_tab(m_current);
        show_toast(QStringLiteral("This page used up webby's memory and was loaded again"));
    }
}

bool BrowserWindow::sleep_tab(int index)
{
    if (index < 0 || index >= int(m_tabs.size()) || !m_tabs[index].view)
        return false;
    auto& tab = m_tabs[index];
    auto* view = tab.view.get();
    if (!view->url().empty())
        tab.url = from_std(view->url());
    forget_summary(view);
    PasswordManager::the().detach(view);
    std::erase_if(m_passkey_requests, [view](auto const& r) { return r.first == view; });
    if (m_dialog_view == view) {
        m_dialog_view = nullptr;
        m_dialog.close(-1);
    }
    if (index == m_current) {
        m_page_image = {};
        m_page_frame.invalidate();
    }
    tab.pdf.reset();
    tab.loading = false;
    tab.view.reset();
    m_save_timer.start();
    update();
    return true;
}

void BrowserWindow::close_tab(int index)
{
    if (index < 0 || index >= int(m_tabs.size()))
        return;
    m_menu.close();
    if (Profile::is_session_url(m_tabs[index].url))
        m_closed.append({ m_tabs[index].title, m_tabs[index].url, m_tabs[index].created });
    if (m_closed.size() > 25)
        m_closed.removeFirst();
    // The frame on screen may be the closing tab's pixels.
    m_page_image = {};
    m_page_frame.invalidate();
    bool panel_was = panel_showing();
    if (auto* view = m_tabs[index].view.get()) {
        forget_summary(view);
        PasswordManager::the().detach(view);
        std::erase_if(m_passkey_requests, [view](auto const& r) { return r.first == view; });
        if (m_dialog_view == view) {
            // The view answers its own request as it goes.
            m_dialog_view = nullptr;
            m_dialog.close(-1);
        }
    }
    if (m_tabs.size() == 1 && !m_quit_saved) {
        // Closing the last tab closes the window: it is kept as a session, as on the desktop.
        m_quit_saved = true;
        WebbyUI::Sessions::save({ { m_tabs[0].title, m_tabs[0].url, 0 } });
    }
    m_tabs.erase(m_tabs.begin() + index);
    m_save_timer.start();
    if (m_tabs.empty()) {
        // Closing the last tab quits; the next start opens a blank tab, not the one just closed.
        save_tabs();
        QGuiApplication::quit();
        return;
    }
    if (m_current >= int(m_tabs.size()) || m_current > index)
        --m_current;
    activate_tab(qBound(0, m_current, int(m_tabs.size()) - 1));
    if (panel_was && !panel_showing())
        relayout_panel();
}

void BrowserWindow::activate_tab(int index)
{
    if (index < 0 || index >= int(m_tabs.size()))
        return;
    if (index != m_current) {
        m_menu.close();
        close_find();
    }
    bool panel_was = panel_showing();
    auto* panel_job_was = panel_job();
    m_current = index;
    m_tabs[index].last_shown = Profile::now_ms();
    scroll_tab_into_view(index);
    auto page = page_rect();
    if (!m_tabs[index].view)
        wake(m_tabs[index]);
    if (!m_tabs[index].view)
        return;
    m_tabs[index].view->resize(page.width(), page.height());
    for (int i = 0; i < int(m_tabs.size()); ++i) {
        if (m_tabs[i].view)
            m_tabs[i].view->set_visible(i == index);
    }
    if (m_tabs[index].pdf)
        m_tabs[index].pdf->resize(page.size());
    m_address_text = from_std(m_tabs[index].view->url());
    if (m_address_text.isEmpty() && !m_tabs[index].url.isEmpty())
        m_address_text = m_tabs[index].url;
    m_hovered_link.clear();
    hide_suggestions();
    m_save_timer.start();
    m_page_frame.invalidate();
    request_page_frame();
    sync_from_view();
    // The panel shows this tab's summary, if it has one open.
    if (panel_showing() != panel_was || panel_job() != panel_job_was) {
        m_panel_focused = false;
        if (panel_showing()) {
            ensure_panel();
            render_panel();
        }
        relayout_panel();
    }
}

void BrowserWindow::sync_from_view()
{
    for (auto& tab : m_tabs) {
        if (!tab.view)
            continue;
        auto title = tab.pdf ? tab.pdf->title() : from_std(tab.view->title()).simplified();
        tab.url = from_std(tab.view->url());
        tab.title = !title.isEmpty() ? title : !tab.url.isEmpty() ? tab.url : QStringLiteral("New Tab");
        tab.loading = tab.view->is_loading();
    }
    if (auto* tab = current())
        setTitle(tab->title + QStringLiteral(" - webby"));
    update_chrome();
}

void BrowserWindow::pump()
{
    WebbyUI::WebView::pump();
    if (auto* pdf = current_pdf()) {
        // At most one page rendered (or read) a turn, so input keeps coming through while a PDF fills in.
        pdf->pump();
        if (m_find_open && !m_find_text.isEmpty()) {
            auto r = pdf->find_state();
            if (r.index != m_find_result.index || r.total != m_find_result.total) {
                m_find_result = r;
                update(find_rect().toAlignedRect().adjusted(-2, -2, 2, 2));
            }
        }
        if (pdf->needs_paint())
            request_page_frame();
        return;
    }
    if (auto* tab = current(); tab && tab->view && tab->view->needs_paint())
        request_page_frame();
}

void BrowserWindow::navigate_from_address()
{
    auto url = m_suggestion >= 0 && m_suggestion < m_suggestions.size() ? m_suggestions[m_suggestion].url
                                                                           : Omnibox::address_to_url(m_address_text);
    focus_address(false);
    load_in_current(url);
}

void BrowserWindow::load_in_current(QString const& url)
{
    auto* tab = current();
    if (!tab || !tab->view)
        return;
    m_address_focused = false;
    hide_suggestions();
    tab->view->load(to_std(Pages::is_own_page(url) ? Pages::refresh(url) : url));
    m_address_text = from_std(tab->view->url());
    update();
}

void BrowserWindow::open_own_page(QString const& url)
{
    if (url.isEmpty())
        return;
    // Like the Nim front end: in this tab when it is blank, else in a new one.
    auto* tab = current();
    if (tab && tab->view && !Profile::is_session_url(from_std(tab->view->url())) && !Pages::is_own_page(from_std(tab->view->url())))
        load_in_current(url);
    else
        open_in_new_tab(url, true);
}

void BrowserWindow::toggle_bookmark()
{
    auto* tab = current();
    if (!tab || !tab->view)
        return;
    auto url = from_std(tab->view->url());
    if (!Profile::is_session_url(url))
        return;
    auto& bookmarks = Profile::Bookmarks::the();
    bool bar_was_shown = show_bookmarks_bar();
    if (bookmarks.contains(url))
        bookmarks.remove_url(url);
    else
        bookmarks.add(url, tab->title);
    // The bar showing or hiding changes the page's height.
    if (bar_was_shown != show_bookmarks_bar())
        resizeEvent(nullptr);
    update();
}

void BrowserWindow::update_suggestions()
{
    m_suggestions = m_address_focused ? Omnibox::suggestions(m_address_text) : QList<Omnibox::Suggestion> {};
    // Only a search for the very text typed is not worth a list.
    if (m_suggestions.size() == 1 && m_suggestions.first().kind != Omnibox::Suggestion::Kind::Bookmark
        && m_suggestions.first().kind != Omnibox::Suggestion::Kind::History)
        m_suggestions.clear();
    m_suggestion = -1;
    m_typed_text = m_address_text;
    update_address();
}

void BrowserWindow::hide_suggestions()
{
    if (m_suggestions.isEmpty() && m_suggestion < 0)
        return;
    m_suggestions.clear();
    m_suggestion = -1;
    update_address();
}

void BrowserWindow::focus_address(bool focus)
{
    m_address_focused = focus;
    if (focus) {
        m_address_anchor = 0;
        m_address_cursor = m_address_text.size();
        QGuiApplication::inputMethod()->show();
    } else {
        hide_suggestions();
        if (auto* tab = current(); tab && tab->view)
            m_address_text = from_std(tab->view->url());
        if (!m_find_focused)
            QGuiApplication::inputMethod()->hide();
    }
    update_chrome();
}

// Geometry, in logical pixels.

int BrowserWindow::pinned_count() const
{
    int n = 0;
    while (n < int(m_tabs.size()) && m_tabs[n].pinned)
        ++n;
    return n;
}

QRect BrowserWindow::sidebar_rect() const
{
    if (!vertical_tabs())
        return {};
    int top = chrome_height();
    return { 0, top, sidebar_width, qMax(1, height() - top) };
}

bool BrowserWindow::in_tab_area(QPointF p) const
{
    if (vertical_tabs())
        return sidebar_rect().contains(p.toPoint());
    return p.y() >= 0 && p.y() < tab_strip_height;
}

// Pinned tiles first (in the strip, a row of them; in the sidebar, rows of five), then the other tabs.
QRectF BrowserWindow::tab_rect(int index) const
{
    int pinned = pinned_count();
    if (vertical_tabs()) {
        qreal top = chrome_height() + 6 - m_sidebar_scroll;
        qreal tile_width = (sidebar_width - 12) / qreal(sidebar_tiles_per_row);
        if (index < pinned)
            return { 6 + (index % sidebar_tiles_per_row) * tile_width, top + (index / sidebar_tiles_per_row) * sidebar_tile_height, tile_width, qreal(sidebar_tile_height - 2) };
        int tile_rows = (pinned + sidebar_tiles_per_row - 1) / sidebar_tiles_per_row;
        qreal rows_top = top + tile_rows * sidebar_tile_height + (tile_rows ? 4 : 0);
        return { 6, rows_top + (index - pinned) * sidebar_row_height, sidebar_width - 12.0, qreal(sidebar_row_height - 2) };
    }
    if (index < pinned)
        return { 8.0 + index * (pinned_tile_width + 2), 6, qreal(pinned_tile_width), qreal(tab_strip_height - 6) };
    qreal left = 8 + pinned * (pinned_tile_width + 2) + (pinned ? 4 : 0);
    int others = int(m_tabs.size()) - pinned;
    qreal available = width() - left - 40;
    qreal w = others <= 0 ? max_tab_width : qBound<qreal>(min_tab_width, available / others, max_tab_width);
    return { left + (index - pinned) * w, 6, w - 2, qreal(tab_strip_height - 6) };
}

QRectF BrowserWindow::tab_close_rect(int index) const
{
    if (index >= 0 && index < int(m_tabs.size()) && m_tabs[index].pinned)
        return {}; // closed from the menu or with a middle click, as in the Nim strip
    auto r = tab_rect(index);
    if (vertical_tabs())
        return { r.right() - 26, r.top() + (r.height() - 20) / 2, 20, 20 };
    return { r.right() - 26, r.top() + (r.height() - 18) / 2, 18, 18 };
}

QRectF BrowserWindow::new_tab_rect() const
{
    auto r = tab_rect(int(m_tabs.size()));
    if (vertical_tabs())
        return r;
    return { r.left() + 4, r.top() + (r.height() - 26) / 2, 26, 26 };
}

qreal BrowserWindow::sidebar_content_height() const
{
    // From the sidebar's top to under the New tab row, unscrolled.
    return new_tab_rect().bottom() + m_sidebar_scroll - chrome_height() + 8;
}

void BrowserWindow::clamp_sidebar_scroll()
{
    qreal most = vertical_tabs() ? qMax<qreal>(0, sidebar_content_height() - sidebar_rect().height()) : 0;
    m_sidebar_scroll = qBound<qreal>(0, m_sidebar_scroll, most);
}

void BrowserWindow::scroll_tab_into_view(int index)
{
    if (!vertical_tabs() || index < 0)
        return;
    auto bar = sidebar_rect();
    auto r = tab_rect(index);
    if (r.top() < bar.top())
        m_sidebar_scroll -= bar.top() - r.top() + 6;
    else if (r.bottom() > bar.bottom())
        m_sidebar_scroll += r.bottom() - bar.bottom() + 6;
    clamp_sidebar_scroll();
}

QString BrowserWindow::site_letter(int index) const
{
    auto host = QUrl(m_tabs[index].url).host().toLower();
    if (host.startsWith(u"www."))
        host = host.mid(4);
    for (auto c : host) {
        if (c.isLetterOrNumber())
            return QString(c).toUpper();
    }
    return {};
}

QRectF BrowserWindow::button_rect(int index) const
{
    return { 8.0 + index * (button_size + 4), toolbar_top() + (toolbar_height - button_size) / 2.0, qreal(button_size), qreal(button_size) };
}

QRectF BrowserWindow::address_rect() const
{
    auto left = button_rect(3).left() + 4;
    qreal right = toolbar_button_rect(ButtonCount - 1).left() - 6;
    return { left, toolbar_top() + 6.0, qMax<qreal>(80, right - left), toolbar_height - 12.0 };
}

QRectF BrowserWindow::star_rect() const
{
    auto field = address_rect();
    return { field.right() - field.height() - 2, field.top(), field.height(), field.height() };
}

QRectF BrowserWindow::bookmark_rect(int index) const
{
    // Laid out left to right at the width of each label; past the window's edge, none.
    QFont font;
    font.setPixelSize(12);
    QFontMetricsF metrics(font);
    qreal x = 8;
    auto const& items = Profile::Bookmarks::the().bar().children;
    for (int i = 0; i < int(items.size()); ++i) {
        qreal w = qMin<qreal>(180, metrics.horizontalAdvance(items[i].label()) + 20 + (items[i].folder ? 14 : 0));
        if (i == index)
            return { x, qreal(toolbar_top() + toolbar_height + 3), w, bookmarks_bar_height - 6.0 };
        x += w + 4;
    }
    return {};
}

QRectF BrowserWindow::suggestion_rect(int index) const
{
    auto field = address_rect();
    return { field.left(), field.bottom() + 6 + index * 34.0, field.width(), 34 };
}

QRect BrowserWindow::page_rect() const
{
    int left = vertical_tabs() ? sidebar_width : 0;
    QRect page { left, chrome_height(), qMax(1, width() - left), qMax(1, height() - chrome_height()) };
    // The Summarize panel takes the right (or, in a narrow window, the lower) part.
    if (auto panel = panel_rect(); !panel.isEmpty()) {
        if (panel.top() == page.top())
            page.setWidth(qMax(1, panel.left() - left));
        else
            page.setHeight(qMax(1, panel.top() - page.top()));
    }
    return page;
}

BrowserWindow::HitResult BrowserWindow::hit_test(QPointF p) const
{
    for (int i = 0; i < int(m_suggestions.size()); ++i) {
        if (suggestion_rect(i).contains(p))
            return { Hit::Suggestion, i };
    }
    // Tabs scrolled out of the sidebar are under the toolbar, not there.
    if (!vertical_tabs() || sidebar_rect().contains(p.toPoint())) {
        for (int i = 0; i < int(m_tabs.size()); ++i) {
            if (tab_close_rect(i).contains(p))
                return { Hit::TabClose, i };
            if (tab_rect(i).contains(p))
                return { Hit::Tab, i };
        }
        if (new_tab_rect().contains(p))
            return { Hit::NewTab };
    }
    if (button_rect(0).contains(p))
        return { Hit::Back };
    if (button_rect(1).contains(p))
        return { Hit::Forward };
    if (button_rect(2).contains(p))
        return { Hit::Reload };
    if (m_find_open) {
        for (int i = 0; i < 3; ++i) {
            if (find_button_rect(i).contains(p))
                return { i == 0 ? Hit::FindPrevious : i == 1 ? Hit::FindNext : Hit::FindClose };
        }
        if (find_rect().contains(p))
            return { Hit::FindField };
    }
    for (int i = 0; i < ButtonCount; ++i) {
        if (toolbar_button_rect(i).contains(p))
            return { Hit::Toolbar, i };
    }
    if (star_rect().contains(p))
        return { Hit::Star };
    if (zoom_rect().contains(p))
        return { Hit::Zoom };
    if (address_rect().contains(p))
        return { Hit::Address };
    if (show_bookmarks_bar()) {
        for (int i = 0; i < int(Profile::Bookmarks::the().bar().children.size()); ++i) {
            if (bookmark_rect(i).contains(p))
                return { Hit::Bookmark, i };
        }
    }
    if (show_password_bar()) {
        auto buttons = password_bar_buttons();
        for (int i = 0; i < int(buttons.size()); ++i) {
            if (buttons[i].rect.contains(p))
                return { Hit::PasswordBar, i };
        }
        if (password_bar_rect().contains(p))
            return {};
    }
    if (panel_showing() && panel_rect().contains(p.toPoint()))
        return { Hit::Panel };
    if (page_rect().contains(p.toPoint()))
        return { Hit::Page };
    return {};
}

// Painting.

void BrowserWindow::paintEvent(QPaintEvent* event)
{
    m_paint_region = event->region();
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);
    paint_page(painter);
    paint_page_scrollbars(painter);
    paint_panel(painter);
    paint_tabs(painter);
    paint_toolbar(painter);
    paint_toolbar_buttons(painter);
    paint_bookmarks_bar(painter);
    paint_password_bar(painter);
    paint_status(painter);
    paint_find(painter);
    paint_toast(painter);
    paint_suggestions(painter);
    m_menu.paint(painter);
    m_dialog.paint(painter, size());
}

void BrowserWindow::paint_tabs(QPainter& p)
{
    bool vertical = vertical_tabs();
    QRectF area = vertical ? QRectF(sidebar_rect()) : QRectF(0, 0, width(), tab_strip_height);
    if (!needs_paint(area))
        return;
    p.fillRect(area, strip_color);
    p.save();
    p.setClipRect(area);
    if (vertical) {
        p.setPen(QPen(WebbyUI::theme().border, 1));
        p.drawLine(QPointF(area.right() + 0.5, area.top()), QPointF(area.right() + 0.5, area.bottom() + 1));
    }
    QFont font = p.font();
    font.setPixelSize(13);
    p.setFont(font);
    // The dragged tab last, over its neighbours.
    for (int pass = 0; pass < 2; ++pass) {
        for (int i = 0; i < int(m_tabs.size()); ++i) {
            bool dragged = m_dragging_tab && i == m_current;
            if (dragged != (pass == 1))
                continue;
            auto r = tab_rect(i);
            if (dragged)
                r.translate(m_drag_offset);
            if (!needs_paint(r) || !r.intersects(area))
                continue;
            if (m_tabs[i].pinned)
                paint_pinned_tile(p, i, r);
            else
                paint_tab(p, i, r, vertical);
        }
    }
    auto n = new_tab_rect();
    if (needs_paint(n)) {
        if (vertical) {
            // A "+ New tab" row under the tabs.
            if (m_hover.hit == Hit::NewTab) {
                QPainterPath path;
                path.addRoundedRect(n, 6, 6);
                p.fillPath(path, tab_hover_color);
            }
            p.setPen(QPen(dim_text_color, 1.6));
            QPointF c(n.left() + 18, n.center().y());
            p.drawLine(QPointF(c.x() - 6, c.y()), QPointF(c.x() + 6, c.y()));
            p.drawLine(QPointF(c.x(), c.y() - 6), QPointF(c.x(), c.y() + 6));
            p.setPen(dim_text_color);
            p.drawText(n.adjusted(36, 0, -8, 0), Qt::AlignVCenter | Qt::AlignLeft, QStringLiteral("New tab"));
        } else {
            if (m_hover.hit == Hit::NewTab) {
                p.setPen(Qt::NoPen);
                p.setBrush(button_hover_color);
                p.drawEllipse(n);
            }
            p.setPen(QPen(dim_text_color, 1.6));
            auto c = n.center();
            p.drawLine(QPointF(c.x() - 6, c.y()), QPointF(c.x() + 6, c.y()));
            p.drawLine(QPointF(c.x(), c.y() - 6), QPointF(c.x(), c.y() + 6));
        }
    }
    p.restore();
}

void BrowserWindow::paint_tab(QPainter& p, int i, QRectF r, bool vertical)
{
    QFontMetricsF metrics(p.font());
    bool active = i == m_current;
    bool hovered = m_hover.tab == i && (m_hover.hit == Hit::Tab || m_hover.hit == Hit::TabClose);
    if (active || hovered) {
        QPainterPath path;
        if (vertical) {
            // A row of the sidebar: flat, rounded all round.
            path.addRoundedRect(r, 6, 6);
            p.fillPath(path, active ? tab_color : tab_hover_color);
        } else {
            // A tab joined to the toolbar under it.
            path.addRoundedRect(r.adjusted(0, 0, 0, 8), 8, 8);
            p.save();
            p.setClipRect(QRectF(0, 0, width(), tab_strip_height));
            p.fillPath(path, active ? tab_color : tab_hover_color);
            p.restore();
        }
    }
    // In the sidebar, as in the Nim one, the close button shows on the front tab and the one under the pointer.
    bool show_close = !vertical || active || hovered;
    auto text_rect = r.adjusted(12, 0, show_close || !vertical ? -30 : -10, 0);
    auto title = m_tabs[i].loading ? QStringLiteral("Loading…") : m_tabs[i].title;
    // A young tab gets a small orange dot before its close button, fainter at each step (the Nim strip's).
    int step = -1;
    auto now = Profile::now_seconds();
    for (int k = 0; k < int(std::size(age_steps)) && Profile::age_colors(); ++k) {
        if (m_tabs[i].created > 0 && now - m_tabs[i].created < age_steps[k]) {
            step = k;
            break;
        }
    }
    if (step >= 0) {
        if (vertical && !show_close)
            text_rect.setRight(r.right() - 30);
        text_rect.adjust(0, 0, -10, 0);
        QColor dot = age_color;
        dot.setAlphaF(1.0 - step * 0.18);
        p.setPen(Qt::NoPen);
        p.setBrush(dot);
        p.drawEllipse(QPointF(r.right() - 34, r.center().y()), 3, 3);
    }
    p.setPen(active ? text_color : dim_text_color);
    p.drawText(text_rect, Qt::AlignVCenter | Qt::AlignLeft, metrics.elidedText(title, Qt::ElideRight, text_rect.width()));
    if (!show_close)
        return;
    auto c = tab_close_rect(i).translated(r.topLeft() - tab_rect(i).topLeft());
    if (m_hover.hit == Hit::TabClose && m_hover.tab == i) {
        p.setPen(Qt::NoPen);
        p.setBrush(WebbyUI::theme().deeper(button_hover_color));
        p.drawEllipse(c);
    }
    p.setPen(QPen(dim_text_color, 1.4));
    auto x = c.adjusted(5, 5, -5, -5);
    p.drawLine(x.topLeft(), x.bottomRight());
    p.drawLine(x.topRight(), x.bottomLeft());
}

// A pinned tab: a tile with its site's letter on the site's color (a page without a site, a globe); tinted under the
// pointer, tinted and underlined in the accent when it is the front tab (the Nim strip's tiles).
void BrowserWindow::paint_pinned_tile(QPainter& p, int i, QRectF r)
{
    bool active = i == m_current;
    bool hovered = m_hover.tab == i && m_hover.hit == Hit::Tab;
    if (active || hovered) {
        QPainterPath path;
        path.addRoundedRect(r, 6, 6);
        p.fillPath(path, active ? tab_color : tab_hover_color);
    }
    if (active) {
        p.setPen(QPen(focus_color, 2, Qt::SolidLine, Qt::RoundCap));
        p.drawLine(QPointF(r.left() + 8, r.bottom() - 1.5), QPointF(r.right() - 8, r.bottom() - 1.5));
    }
    QRectF badge(0, 0, 18, 18);
    badge.moveCenter(r.center() - QPointF(0, 1));
    auto letter = site_letter(i);
    if (letter.isEmpty()) {
        p.setPen(QPen(dim_text_color, 1.3));
        p.setBrush(Qt::NoBrush);
        auto g = badge.adjusted(2, 2, -2, -2);
        p.drawEllipse(g);
        p.drawEllipse(g.adjusted(g.width() / 2 - 3, 0, -(g.width() / 2 - 3), 0));
        p.drawLine(QPointF(g.left(), g.center().y()), QPointF(g.right(), g.center().y()));
        return;
    }
    QPainterPath path;
    path.addRoundedRect(badge, 4, 4);
    QColor fill = badge_color(QUrl(m_tabs[i].url).host());
    if (m_tabs[i].loading)
        fill.setAlphaF(0.6);
    p.fillPath(path, fill);
    QFont font = p.font();
    font.setPixelSize(11);
    font.setBold(true);
    p.save();
    p.setFont(font);
    p.setPen(Qt::white);
    p.drawText(badge, Qt::AlignCenter, letter);
    p.restore();
}

void BrowserWindow::paint_toolbar(QPainter& p)
{
    QRectF bar(0, toolbar_top(), width(), toolbar_height);
    p.fillRect(bar, tab_color);
    p.setPen(QPen(WebbyUI::theme().border, 1));
    p.drawLine(QPointF(0, chrome_height() - 0.5), QPointF(width(), chrome_height() - 0.5));

    auto* tab = current();
    bool can_back = tab && tab->view && tab->view->can_go_back();
    bool can_forward = tab && tab->view && tab->view->can_go_forward();
    Hit buttons[] = { Hit::Back, Hit::Forward, Hit::Reload };
    bool enabled[] = { can_back, can_forward, tab != nullptr };
    for (int i = 0; i < 3; ++i) {
        auto r = button_rect(i);
        if (!needs_paint(r))
            continue;
        if (m_hover.hit == buttons[i] && enabled[i]) {
            p.setPen(Qt::NoPen);
            p.setBrush(button_hover_color);
            p.drawEllipse(r);
        }
        p.setPen(QPen(enabled[i] ? text_color : disabled_color, 1.8, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.setBrush(Qt::NoBrush);
        auto c = r.center();
        if (i < 2) {
            qreal d = i == 0 ? -1 : 1;
            p.drawLine(QPointF(c.x() - 7 * d, c.y()), QPointF(c.x() + 7 * d, c.y()));
            p.drawLine(QPointF(c.x() + 7 * d, c.y()), QPointF(c.x() + 2 * d, c.y() - 5));
            p.drawLine(QPointF(c.x() + 7 * d, c.y()), QPointF(c.x() + 2 * d, c.y() + 5));
        } else if (tab && tab->loading) {
            auto x = QRectF(c.x() - 6, c.y() - 6, 12, 12);
            p.drawLine(x.topLeft(), x.bottomRight());
            p.drawLine(x.topRight(), x.bottomLeft());
        } else {
            QRectF arc(c.x() - 7, c.y() - 7, 14, 14);
            p.drawArc(arc, 90 * 16, 300 * 16);
            QPointF tip(c.x() + 1, c.y() - 7);
            p.drawLine(tip, tip + QPointF(-4, -3.5));
            p.drawLine(tip, tip + QPointF(-4, 3.5));
        }
    }

    auto field = address_rect();
    if (!needs_paint(field))
        return;
    QPainterPath path;
    path.addRoundedRect(field, field.height() / 2, field.height() / 2);
    p.fillPath(path, m_address_focused ? tab_color : field_color);
    if (m_address_focused) {
        p.setPen(QPen(focus_color, 2));
        p.setBrush(Qt::NoBrush);
        p.drawPath(path);
    }

    QFont font = p.font();
    font.setPixelSize(14);
    p.setFont(font);
    QFontMetricsF metrics(font);
    // The star: filled when the page is bookmarked.
    auto star = star_rect();
    if (m_hover.hit == Hit::Star) {
        p.setPen(Qt::NoPen);
        p.setBrush(button_hover_color);
        p.drawEllipse(star.adjusted(3, 3, -3, -3));
    }
    {
        auto c = star.center();
        QPolygonF poly;
        for (int k = 0; k < 10; ++k) {
            qreal radius = k % 2 ? 3.4 : 8.0;
            qreal angle = M_PI / 2 + k * M_PI / 5;
            poly << QPointF(c.x() + radius * std::cos(angle), c.y() - radius * std::sin(angle));
        }
        bool marked = tab && tab->view && Profile::Bookmarks::the().contains(from_std(tab->view->url()));
        p.setPen(QPen(marked ? star_color : dim_text_color, 1.4, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.setBrush(marked ? QBrush(star_color) : QBrush(Qt::NoBrush));
        p.drawPolygon(poly);
    }

    // The page's zoom, when it is not 100%: a pill before the star that resets it.
    auto zoom = zoom_rect();
    if (!zoom.isEmpty()) {
        QFont small = p.font();
        small.setPixelSize(12);
        p.save();
        p.setFont(small);
        QPainterPath pill;
        pill.addRoundedRect(zoom, zoom.height() / 2, zoom.height() / 2);
        p.fillPath(pill, m_hover.hit == Hit::Zoom ? WebbyUI::theme().deeper(button_hover_color) : button_hover_color);
        p.setPen(text_color);
        p.drawText(zoom, Qt::AlignCenter, QStringLiteral("%1%").arg(qRound(tab->view->zoom() * 100)));
        p.restore();
    }

    auto text_rect = field.adjusted(16, 0, -16 - star.width() - (zoom.isEmpty() ? 0 : zoom.width() + 4), 0);
    p.save();
    p.setClipRect(text_rect);
    if (m_address_text.isEmpty() && !m_address_focused) {
        p.setPen(dim_text_color);
        p.drawText(text_rect, Qt::AlignVCenter | Qt::AlignLeft, QStringLiteral("Search or enter a file:// address"));
    } else {
        qreal baseline = text_rect.center().y() + (metrics.ascent() - metrics.descent()) / 2;
        if (m_address_focused && m_address_anchor != m_address_cursor) {
            int a = qMin(m_address_anchor, m_address_cursor);
            int b = qMax(m_address_anchor, m_address_cursor);
            qreal x0 = text_rect.left() + metrics.horizontalAdvance(m_address_text.left(a));
            qreal x1 = text_rect.left() + metrics.horizontalAdvance(m_address_text.left(b));
            p.fillRect(QRectF(x0, text_rect.center().y() - metrics.height() / 2, x1 - x0, metrics.height()), WebbyUI::theme().selection);
        }
        p.setPen(text_color);
        p.drawText(QPointF(text_rect.left(), baseline), m_address_text);
        if (m_address_focused) {
            qreal x = text_rect.left() + metrics.horizontalAdvance(m_address_text.left(m_address_cursor));
            p.setPen(QPen(text_color, 1));
            p.drawLine(QPointF(x, text_rect.center().y() - metrics.height() / 2), QPointF(x, text_rect.center().y() + metrics.height() / 2));
        }
    }
    p.restore();
}

void BrowserWindow::paint_bookmarks_bar(QPainter& p)
{
    if (!show_bookmarks_bar())
        return;
    QRectF bar(0, toolbar_top() + toolbar_height, width(), bookmarks_bar_height);
    p.fillRect(bar, tab_color);
    p.setPen(QPen(WebbyUI::theme().border, 1));
    p.drawLine(QPointF(0, bar.bottom() - 0.5), QPointF(width(), bar.bottom() - 0.5));
    QFont font = p.font();
    font.setPixelSize(12);
    p.setFont(font);
    QFontMetricsF metrics(font);
    auto const& items = Profile::Bookmarks::the().bar().children;
    for (int i = 0; i < int(items.size()); ++i) {
        auto r = bookmark_rect(i);
        if (r.isEmpty() || r.left() > width())
            break;
        if (m_hover.hit == Hit::Bookmark && m_hover.tab == i) {
            QPainterPath path;
            path.addRoundedRect(r, r.height() / 2, r.height() / 2);
            p.fillPath(path, button_hover_color);
        }
        auto text = r.adjusted(10, 0, -10, 0);
        p.setPen(text_color);
        auto label = items[i].label();
        if (items[i].folder)
            label += QStringLiteral(" ▾");
        p.drawText(text, Qt::AlignVCenter | Qt::AlignLeft, metrics.elidedText(label, Qt::ElideRight, text.width()));
    }
}

QRect BrowserWindow::suggestions_box() const
{
    if (m_suggestions.isEmpty())
        return {};
    auto first = suggestion_rect(0);
    return QRectF(first.left(), first.top() - 4, first.width(), m_suggestions.size() * first.height() + 8).toAlignedRect().adjusted(-2, -2, 2, 2);
}

// What a change to the chrome alone repaints: the tab strip, toolbar and bars above the page, the find bar, and the
// address suggestions as they are now and as they were last drawn. A full update() repaints the page under them too
// and is several times the work. With a menu or a dialog open (either can cover any of it), the whole window.
QRegion BrowserWindow::chrome_region() const
{
    if (m_menu.is_open() || m_dialog.is_open())
        return QRegion(0, 0, width(), height());
    QRegion region(0, 0, width(), chrome_height());
    region += sidebar_rect();
    region += m_suggestions_painted;
    region += suggestions_box();
    if (m_find_open)
        region += find_rect().toAlignedRect().adjusted(-2, -2, 2, 2);
    return region;
}

void BrowserWindow::update_chrome()
{
    update(chrome_region());
}

// A change to the address field alone (typing, the caret, the selection, focus): the field and the suggestions.
void BrowserWindow::update_address()
{
    if (m_menu.is_open() || m_dialog.is_open()) {
        update();
        return;
    }
    QRegion region(address_rect().toAlignedRect().adjusted(-3, -3, 3, 3));
    region += m_suggestions_painted;
    region += suggestions_box();
    update(region);
}

// Whether `r` is in what this paint repaints. Clipped drawing is not free: Qt still turns every curve, rounded
// rect and round-capped line into polygons, and in wasm the toolbar's icons cost more than the pixels they touch.
bool BrowserWindow::needs_paint(QRectF const& r) const
{
    return m_paint_region.intersects(r.toAlignedRect().adjusted(-2, -2, 2, 2));
}

void BrowserWindow::paint_suggestions(QPainter& p)
{
    m_suggestions_painted = suggestions_box();
    if (m_suggestions.isEmpty())
        return;
    auto first = suggestion_rect(0);
    QRectF box(first.left(), first.top() - 4, first.width(), m_suggestions.size() * first.height() + 8);
    p.setPen(QPen(WebbyUI::theme().border, 1));
    p.setBrush(tab_color);
    p.drawRoundedRect(box, 10, 10);
    QFont font = p.font();
    font.setPixelSize(14);
    QFont small = font;
    small.setPixelSize(12);
    for (int i = 0; i < int(m_suggestions.size()); ++i) {
        auto r = suggestion_rect(i);
        auto const& s = m_suggestions[i];
        if (i == m_suggestion || (m_hover.hit == Hit::Suggestion && m_hover.tab == i))
            p.fillRect(r, i == m_suggestion ? WebbyUI::theme().selected : button_hover_color);
        // An icon: a magnifier for a search, a star for a bookmark, a clock for history.
        auto c = QPointF(r.left() + 22, r.center().y());
        p.setPen(QPen(dim_text_color, 1.5));
        p.setBrush(Qt::NoBrush);
        using Kind = Omnibox::Suggestion::Kind;
        if (s.kind == Kind::Search) {
            p.drawEllipse(c + QPointF(-1.5, -1.5), 5, 5);
            p.drawLine(c + QPointF(2, 2), c + QPointF(6, 6));
        } else if (s.kind == Kind::Bookmark) {
            QPolygonF poly;
            for (int k = 0; k < 10; ++k) {
                qreal radius = k % 2 ? 3 : 7;
                qreal angle = M_PI / 2 + k * M_PI / 5;
                poly << QPointF(c.x() + radius * std::cos(angle), c.y() - radius * std::sin(angle));
            }
            p.drawPolygon(poly);
        } else if (s.kind == Kind::History) {
            p.drawEllipse(c, 6.5, 6.5);
            p.drawLine(c, c + QPointF(0, -4));
            p.drawLine(c, c + QPointF(3, 2));
        } else {
            p.drawEllipse(c, 6.5, 6.5);
            p.drawLine(c + QPointF(-6.5, 0), c + QPointF(6.5, 0));
            p.drawEllipse(c, 3, 6.5);
        }
        auto text = r.adjusted(44, 0, -12, 0);
        QFontMetricsF metrics(font);
        p.setFont(font);
        p.setPen(text_color);
        auto title = s.kind == Kind::Search ? s.title + QStringLiteral(" — Search") : s.title;
        auto title_text = metrics.elidedText(title, Qt::ElideRight, text.width() * 0.6);
        p.drawText(text, Qt::AlignVCenter | Qt::AlignLeft, title_text);
        if (s.kind == Kind::Bookmark || s.kind == Kind::History) {
            qreal x = metrics.horizontalAdvance(title_text) + 12;
            QFontMetricsF small_metrics(small);
            p.setFont(small);
            p.setPen(focus_color);
            p.drawText(text.adjusted(x, 0, 0, 0), Qt::AlignVCenter | Qt::AlignLeft,
                small_metrics.elidedText(s.url, Qt::ElideMiddle, text.width() - x));
        }
    }
}

void BrowserWindow::request_page_frame()
{
    m_page_dirty = true;
    requestUpdate();
}

// At the window's update, before it paints: take the page's new frame and mark what it changed. A scroll moves the
// pixels already on screen (on the host too, so they are not sent again) and repaints only what the move did not
// bring along: the strip it uncovered, sticky or fixed parts of the page, and what the window draws over the page.
// Every other paint of the page area draws this same frame (m_page_image): only here does the view paint.
void BrowserWindow::prepare_page_frame()
{
    if (!m_page_dirty)
        return;
    m_page_dirty = false;
    auto page = page_rect();
    auto* tab = current();
    auto* pdf = current_pdf();
    uint8_t const* pixels = nullptr;
    QSize size;
    void const* owner = nullptr;
    if (pdf) {
        auto const& frame = pdf->paint();
        pixels = frame.isNull() ? nullptr : frame.constBits();
        size = frame.size();
        owner = pdf;
    } else if (tab && tab->view) {
        pixels = tab->view->paint();
        size = { tab->view->width(), tab->view->height() };
        owner = tab->view.get();
    }
    if (!pixels) {
        m_page_image = {};
        m_page_frame.invalidate();
        m_page_scrollbars.clear();
        update(page);
        return;
    }
    // The viewport's scrollbars move with a scroll, grow under the pointer and change with the page's length: repaint
    // where they were and where they are now whenever they changed (and on any scroll, which moves their pixels).
    std::vector<WebbyUI::WebView::Scrollbar> bars;
    if (!pdf)
        bars = tab->view->scrollbars();
    QRegion bar_region = scrollbar_region(m_page_scrollbars) + scrollbar_region(bars);
    bool bars_changed = bars != m_page_scrollbars;
    m_page_scrollbars = std::move(bars);
    m_page_image = QImage(pixels, size.width(), size.height(), size.width() * 4, QImage::Format_ARGB32_Premultiplied);
    // The engine says what it repainted (it rasters only damage): no need to compare the whole frame.
    WebbyUI::PageFrame::Change change;
    if (!pdf && tab->view->last_paint_change().known) {
        auto const& known = tab->view->last_paint_change();
        QRegion region;
        for (auto const& r : known.rects)
            region += QRect(r[0], r[1], r[2], r[3]);
        change = m_page_frame.take_known(pixels, size, owner, -known.moved, region);
    } else {
        change = m_page_frame.take(pixels, size, owner);
    }
    QRegion damage = change.damage.translated(page.topLeft());
    if (change.scroll) {
        // The host moves whole device pixels. Under an open menu or the address suggestions (they can cover most of
        // the page) the page is painted again instead.
        qreal dpr = devicePixelRatio();
        bool moved = false;
        if (dpr == qFloor(dpr) && size == page.size() && !m_menu.is_open() && m_suggestions.isEmpty()) {
            int d = int(dpr);
            QRect area { page.left() * d, page.top() * d, page.width() * d, page.height() * d };
            moved = qt2wasm::gui::scrollWindow(this, area, 0, -change.scroll * d);
        }
        if (moved) {
            auto overlays = page_overlays() + bar_region;
            damage += overlays;
            damage += overlays.translated(0, -change.scroll);
            damage &= page;
        } else {
            damage = page;
        }
    }
    if (size != page.size())
        damage += page;
    if (bars_changed)
        damage += bar_region;
    // WEBBY_DAMAGE_DEBUG=1: each frame's scroll and damage on stderr.
    if (getenv("WEBBY_DAMAGE_DEBUG")) {
        QString out;
        for (auto const& r : damage)
            out += QStringLiteral(" %1,%2 %3x%4").arg(r.x()).arg(r.y()).arg(r.width()).arg(r.height());
        qWarning("webby: frame scroll %d, %d rects:%s", change.scroll, int(damage.rectCount()), qPrintable(out));
    }
    if (!damage.isEmpty())
        update(damage);
}

QRegion BrowserWindow::page_overlays() const
{
    QRegion overlays;
    if (!m_status_painted.isEmpty())
        overlays += m_status_painted;
    if (m_find_open)
        overlays += find_rect().toAlignedRect().adjusted(-2, -2, 2, 2);
    if (!m_toast.isEmpty())
        overlays += QRect(0, height() - 60, width(), 44);
    overlays += scrollbar_region(m_page_scrollbars);
    return overlays;
}

// WEBBY_TEST_INPUT (tests, as latha-gui's --type): mouse steps "press X,Y@MS;move X,Y@MS;release X,Y@MS", with the
// left button, in page coordinates (a negative X counts from the page's right edge), MS after the window starts. A "w"
// before the kind ("wpress") takes window coordinates and goes through event() (as a real one would, so an open menu
// gets it); "rpress" and "rrelease" are the right button's.
void BrowserWindow::play_test_input()
{
    auto steps = qEnvironmentVariable("WEBBY_TEST_INPUT").split(QLatin1Char(';'), Qt::SkipEmptyParts);
    for (auto const& step : steps) {
        auto words = step.trimmed().split(QLatin1Char(' '), Qt::SkipEmptyParts);
        if (words.size() != 2)
            continue;
        auto at = words[1].split(QLatin1Char('@'));
        auto xy = at[0].split(QLatin1Char(','));
        if (at.size() != 2 || xy.size() != 2)
            continue;
        auto kind = words[0];
        int x = xy[0].toInt(), y = xy[1].toInt(), ms = at[1].toInt();
        bool window = kind.startsWith(u'w');
        if (window)
            kind = kind.mid(1);
        Qt::MouseButton button = kind.startsWith(u'r') && kind != u"release" ? Qt::RightButton : Qt::LeftButton;
        if (button == Qt::RightButton)
            kind = kind.mid(1);
        QTimer::singleShot(ms, this, [this, kind, x, y, window, button] {
            auto page = page_rect();
            QPointF position = window ? QPointF(x, y) : QPointF(x < 0 ? page.right() + 1 + x : page.left() + x, page.top() + y);
            auto type = kind == u"press" ? QEvent::MouseButtonPress : kind == u"release" ? QEvent::MouseButtonRelease : QEvent::MouseMove;
            auto buttons = kind == u"release" ? Qt::NoButton : kind == u"press" ? Qt::MouseButtons(button) : Qt::MouseButtons(m_test_buttons);
            m_test_buttons = buttons;
            QMouseEvent event(type, position, mapToGlobal(position), type == QEvent::MouseMove ? Qt::NoButton : button, buttons, Qt::NoModifier);
            if (window)
                QCoreApplication::sendEvent(this, &event);
            else if (type == QEvent::MouseButtonPress)
                mousePressEvent(&event);
            else if (type == QEvent::MouseButtonRelease)
                mouseReleaseEvent(&event);
            else
                mouseMoveEvent(&event);
            qWarning("webby: test input %s %d,%d", qPrintable(kind), int(position.x()), int(position.y()));
        });
    }
}

QRegion BrowserWindow::scrollbar_region(std::vector<WebbyUI::WebView::Scrollbar> const& bars) const
{
    auto page = page_rect();
    QRegion region;
    for (auto const& bar : bars) {
        QRect gutter(bar.gutter[0], bar.gutter[1], bar.gutter[2], bar.gutter[3]);
        QRect thumb(bar.thumb[0], bar.thumb[1], bar.thumb[2], bar.thumb[3]);
        region += gutter.united(thumb).adjusted(-2, -2, 2, 2).translated(page.topLeft());
    }
    return region & page;
}

// As Ladybird's Compositor paints them (DisplayListPlayerSkia's paint_scrollbar_into_surface): the gutter in the track
// color, then the thumb, a rounded bar with a lighter edge.
void BrowserWindow::paint_page_scrollbars(QPainter& p)
{
    if (m_page_scrollbars.empty() || m_page_image.isNull() || current_pdf())
        return;
    auto page = page_rect();
    p.save();
    p.setClipRect(page);
    for (auto const& bar : m_page_scrollbars) {
        QRectF gutter(bar.gutter[0], bar.gutter[1], bar.gutter[2], bar.gutter[3]);
        QRectF thumb(bar.thumb[0], bar.thumb[1], bar.thumb[2], bar.thumb[3]);
        gutter.translate(page.topLeft());
        thumb.translate(page.topLeft());
        auto track = QColor::fromRgba(bar.track_color);
        if (bar.expanded && track.alpha() > 0)
            p.fillRect(gutter, track);
        if (thumb.isEmpty())
            continue;
        auto color = QColor::fromRgba(bar.thumb_color);
        auto edge = color.lighter(120);
        edge.setAlpha(color.alpha());
        qreal radius = (bar.vertical ? thumb.width() : thumb.height()) / 2;
        p.setPen(QPen(edge, 1));
        p.setBrush(color);
        p.drawRoundedRect(thumb.adjusted(0.5, 0.5, -0.5, -0.5), radius, radius);
    }
    p.restore();
}

void BrowserWindow::apply_color_scheme()
{
    // WEBBY_THEME=dark|light overrides the desktop (LATHA_GUI_THEME does the same for every latha:gui app).
    auto forced = qEnvironmentVariable("WEBBY_THEME");
    bool dark = forced == QStringLiteral("dark") || (forced != QStringLiteral("light") && QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark);
    bool changed = dark != theme().dark;
    theme().set_dark(dark);
    WebView::set_color_scheme(dark);
    if (changed)
        update();
}

void BrowserWindow::paint_page(QPainter& p)
{
    auto r = page_rect();
    if (m_page_image.isNull()) {
        p.fillRect(r, WebbyUI::theme().page_blank);
        return;
    }
    auto const& image = m_page_image;
    // The page is opaque: copy it, no blending.
    p.save();
    p.setCompositionMode(QPainter::CompositionMode_Source);
    p.drawImage(r.topLeft(), image);
    p.restore();
    if (image.width() < r.width())
        p.fillRect(QRect(r.left() + image.width(), r.top(), r.width() - image.width(), r.height()), WebbyUI::theme().page_blank);
    if (image.height() < r.height())
        p.fillRect(QRect(r.left(), r.top() + image.height(), r.width(), r.height() - image.height()), WebbyUI::theme().page_blank);
}

QRect BrowserWindow::status_rect() const
{
    if (m_hovered_link.isEmpty())
        return {};
    // Wide enough for any text paint_status elides to (60% of the window), so it needs no font here.
    return QRect(0, height() - 25, int(width() * 0.6) + 24, 25);
}

void BrowserWindow::paint_status(QPainter& p)
{
    m_status_painted = status_rect();
    if (m_hovered_link.isEmpty())
        return;
    QFont font = p.font();
    font.setPixelSize(12);
    p.setFont(font);
    QFontMetricsF metrics(font);
    auto text = metrics.elidedText(m_hovered_link, Qt::ElideMiddle, width() * 0.6);
    QRectF box(0, height() - 24, metrics.horizontalAdvance(text) + 16, 24);
    p.setPen(QPen(WebbyUI::theme().border, 1));
    p.setBrush(WebbyUI::theme().panel);
    p.drawRect(box.adjusted(-1, 0, 0, 1));
    p.setPen(text_color);
    p.drawText(box.adjusted(8, 0, 0, 0), Qt::AlignVCenter | Qt::AlignLeft, text);
}

// Input.

void BrowserWindow::resizeEvent(QResizeEvent*)
{
    m_menu.close();
    clamp_sidebar_scroll();
    if (auto* tab = current(); tab && tab->view) {
        auto page = page_rect();
        tab->view->resize(page.width(), page.height());
        if (tab->pdf)
            tab->pdf->resize(page.size());
    }
    if (m_panel && panel_showing()) {
        auto panel = panel_rect();
        if (m_panel->width() != panel.width() || m_panel->height() != panel.height())
            m_panel->resize(panel.width(), panel.height());
    }
    request_page_frame();
    update();
}

int BrowserWindow::address_index_at(qreal x) const
{
    QFont font;
    font.setPixelSize(14);
    QFontMetricsF metrics(font);
    qreal left = address_rect().left() + 16;
    for (int i = 0; i <= m_address_text.size(); ++i) {
        qreal w = metrics.horizontalAdvance(m_address_text.left(i));
        if (left + w >= x) {
            if (i > 0 && (left + w) - x > x - (left + metrics.horizontalAdvance(m_address_text.left(i - 1))))
                return i - 1;
            return i;
        }
    }
    return m_address_text.size();
}

void BrowserWindow::mousePressEvent(QMouseEvent* event)
{
    auto hit = hit_test(event->position());
    m_pressed = hit;
    if (m_find_open) {
        bool in_find = hit.hit == Hit::FindField || hit.hit == Hit::FindPrevious || hit.hit == Hit::FindNext;
        if (in_find != m_find_focused) {
            m_find_focused = in_find;
            if (m_find_focused)
                QGuiApplication::inputMethod()->show();
            else if (!m_address_focused)
                QGuiApplication::inputMethod()->hide();
            update();
        }
    }
    if (hit.hit == Hit::Suggestion) {
        if (event->button() == Qt::LeftButton && hit.tab < m_suggestions.size()) {
            auto url = m_suggestions[hit.tab].url;
            m_address_focused = false;
            if (!m_find_focused)
                QGuiApplication::inputMethod()->hide();
            load_in_current(url);
        }
        m_pressed = {};
        return;
    }
    if (hit.hit != Hit::Address && hit.hit != Hit::None && m_address_focused)
        focus_address(false);
    m_panel_focused = hit.hit == Hit::Panel;
    auto* tab = current();
    if (tab && !tab->view)
        tab = nullptr;
    switch (hit.hit) {
    case Hit::Panel:
        if (m_panel) {
            auto r = panel_rect();
            m_panel->mouse_down(int(event->position().x()) - r.left(), int(event->position().y()) - r.top(),
                web_button(event->button()), web_buttons(event->buttons()), web_modifiers(event->modifiers()), 1);
        }
        break;
    case Hit::Tab:
    case Hit::TabClose:
        if (event->button() == Qt::MiddleButton) {
            m_pressed = {};
            close_tab(hit.tab);
        } else if (event->button() == Qt::RightButton) {
            m_pressed = {};
            open_tab_menu(event->position(), hit.tab);
        } else if (hit.hit == Hit::Tab) {
            activate_tab(hit.tab);
            m_press_pos = event->position();
            m_drag_offset = {};
        }
        break;
    case Hit::NewTab:
    case Hit::None:
        if (event->button() == Qt::RightButton && in_tab_area(event->position())) {
            m_pressed = {};
            open_tab_menu(event->position(), -1);
        }
        break;
    case Hit::Toolbar:
        if (hit.tab == ButtonMore && event->button() == Qt::LeftButton) {
            m_pressed = {};
            open_more_menu();
        }
        break;
    case Hit::Bookmark:
        if (event->button() == Qt::MiddleButton) {
            auto const& items = Profile::Bookmarks::the().bar().children;
            if (hit.tab < items.size() && !items[hit.tab].folder)
                open_in_new_tab(items[hit.tab].url, false);
        }
        break;
    case Hit::Address:
        if (event->button() == Qt::MiddleButton) {
            auto text = qt2wasm::gui::primaryText();
            if (!m_address_focused)
                focus_address(true);
            m_address_cursor = m_address_anchor = address_index_at(event->position().x());
            text.replace(QLatin1Char('\r'), QLatin1Char(' ')).replace(QLatin1Char('\n'), QLatin1Char(' '));
            m_address_text.insert(m_address_cursor, text);
            m_address_cursor += int(text.size());
            m_address_anchor = m_address_cursor;
            update();
            break;
        }
        if (!m_address_focused) {
            focus_address(true);
        } else {
            m_address_cursor = address_index_at(event->position().x());
            if (!(event->modifiers() & Qt::ShiftModifier))
                m_address_anchor = m_address_cursor;
            QGuiApplication::inputMethod()->show();
            update();
        }
        break;
    case Hit::Page:
        if (auto* pdf = current_pdf()) {
            if (event->button() == Qt::RightButton) {
                m_pressed = {};
                show_pdf_menu(event->position());
            } else {
                pdf->mouse_press(event->position() - page_rect().topLeft(), event->button(), event->modifiers(), 1);
            }
            break;
        }
        // A middle or Ctrl+click on a link opens it in a new tab behind this one.
        if (!m_hovered_link.isEmpty() && (event->button() == Qt::MiddleButton
                || (event->button() == Qt::LeftButton && (event->modifiers() & Qt::ControlModifier)))) {
            open_in_new_tab(m_hovered_link, event->modifiers() & Qt::ShiftModifier);
            m_pressed = {};
            break;
        }
        if (tab) {
            auto page = page_rect();
            m_page_buttons = web_buttons(event->buttons());
            tab->view->mouse_down(int(event->position().x()) - page.left(), int(event->position().y()) - page.top(),
                web_button(event->button()), m_page_buttons, web_modifiers(event->modifiers()), 1);
        }
        break;
    default:
        break;
    }
}

void BrowserWindow::mouseDoubleClickEvent(QMouseEvent* event)
{
    auto hit = hit_test(event->position());
    if (hit.hit == Hit::Address) {
        m_address_anchor = 0;
        m_address_cursor = m_address_text.size();
        update_primary_selection();
        update();
        return;
    }
    if (hit.hit == Hit::None && event->button() == Qt::LeftButton && in_tab_area(event->position())) {
        new_tab({});
        activate_tab(int(m_tabs.size()) - 1);
        focus_address(true);
        return;
    }
    if (hit.hit == Hit::Panel && m_panel) {
        auto r = panel_rect();
        m_panel->mouse_down(int(event->position().x()) - r.left(), int(event->position().y()) - r.top(),
            web_button(event->button()), web_buttons(event->buttons()), web_modifiers(event->modifiers()), 2);
        return;
    }
    if (hit.hit == Hit::Page) {
        if (auto* pdf = current_pdf()) {
            if (event->button() == Qt::LeftButton)
                pdf->mouse_press(event->position() - page_rect().topLeft(), event->button(), event->modifiers(), 2);
            return;
        }
        if (auto* tab = current(); tab && tab->view) {
            auto page = page_rect();
            tab->view->mouse_down(int(event->position().x()) - page.left(), int(event->position().y()) - page.top(),
                web_button(event->button()), web_buttons(event->buttons()), web_modifiers(event->modifiers()), 2);
        }
    }
}

void BrowserWindow::mouseReleaseEvent(QMouseEvent* event)
{
    auto hit = hit_test(event->position());
    auto pressed = m_pressed;
    m_pressed = {};
    if (pressed.hit == Hit::Address && event->button() == Qt::LeftButton)
        update_primary_selection();
    if (m_dragging_tab) {
        m_dragging_tab = false;
        m_drag_offset = {};
        m_save_timer.start();
        update();
        return;
    }
    auto* tab = current();
    if (tab && !tab->view)
        tab = nullptr;
    if (pressed.hit == Hit::Panel) {
        if (m_panel && panel_showing()) {
            auto r = panel_rect();
            m_panel->mouse_up(int(event->position().x()) - r.left(), int(event->position().y()) - r.top(),
                web_button(event->button()), web_buttons(event->buttons()), web_modifiers(event->modifiers()));
        }
        return;
    }
    if (pressed.hit == Hit::Page && tab && tab->pdf) {
        tab->pdf->mouse_release(event->position() - page_rect().topLeft(), event->button(), event->modifiers());
        return;
    }
    if (pressed.hit == Hit::Page && tab) {
        auto page = page_rect();
        m_page_buttons = web_buttons(event->buttons());
        tab->view->mouse_up(int(event->position().x()) - page.left(), int(event->position().y()) - page.top(),
            web_button(event->button()), m_page_buttons, web_modifiers(event->modifiers()));
        return;
    }
    if (hit.hit != pressed.hit || event->button() != Qt::LeftButton)
        return;
    switch (hit.hit) {
    case Hit::TabClose:
        if (hit.tab == pressed.tab)
            close_tab(hit.tab);
        break;
    case Hit::NewTab:
        new_tab({});
        activate_tab(int(m_tabs.size()) - 1);
        focus_address(true);
        break;
    case Hit::Back:
        if (tab)
            tab->view->go_back();
        break;
    case Hit::Forward:
        if (tab)
            tab->view->go_forward();
        break;
    case Hit::Reload:
        if (tab)
            Pages::is_own_page(from_std(tab->view->url())) ? load_in_current(from_std(tab->view->url())) : tab->view->reload();
        break;
    case Hit::Star:
        toggle_bookmark();
        break;
    case Hit::Toolbar:
        if (hit.tab != ButtonMore)
            toolbar_button(hit.tab);
        break;
    case Hit::Zoom:
        zoom_by(0);
        break;
    case Hit::PasswordBar:
        if (hit.tab == pressed.tab)
            password_bar_click(hit.tab);
        break;
    case Hit::FindPrevious:
        run_find(-1);
        break;
    case Hit::FindNext:
        run_find(1);
        break;
    case Hit::FindClose:
        close_find();
        break;
    case Hit::Bookmark:
        if (hit.tab == pressed.tab) {
            auto const& items = Profile::Bookmarks::the().bar().children;
            if (hit.tab < items.size()) {
                if (items[hit.tab].folder)
                    open_own_page(Pages::bookmarks_page());
                else if (event->modifiers() & Qt::ControlModifier)
                    open_in_new_tab(items[hit.tab].url, false);
                else
                    load_in_current(items[hit.tab].url);
            }
        }
        break;
    default:
        break;
    }
}

void BrowserWindow::mouseMoveEvent(QMouseEvent* event)
{
    auto hit = hit_test(event->position());
    if (hit.hit != m_hover.hit || hit.tab != m_hover.tab) {
        // Only the chrome draws hovers; moving within the page (or off everything) changes nothing on screen.
        auto quiet = [](Hit h) { return h == Hit::None || h == Hit::Page; };
        bool repaint = !quiet(hit.hit) || !quiet(m_hover.hit);
        m_hover = hit;
        if (repaint)
            update_chrome();
    }
    if (m_pressed.hit == Hit::Address && (event->buttons() & Qt::LeftButton)) {
        m_address_cursor = address_index_at(event->position().x());
        update_address();
        return;
    }
    if (m_pressed.hit == Hit::Tab && (event->buttons() & Qt::LeftButton) && m_current >= 0) {
        // Dragging a tab: it follows the pointer (along the strip, down the sidebar, or anywhere in the pinned tiles'
        // grid) and takes the place of a neighbour of its kind it comes nearer to; pinned tabs stay among the pinned.
        bool vertical = vertical_tabs();
        bool pinned = m_tabs[m_current].pinned;
        QPointF offset = event->position() - m_press_pos;
        if (!vertical)
            offset.setY(0);
        else if (!pinned)
            offset.setX(0);
        m_drag_offset = offset;
        if (!m_dragging_tab && (qAbs(offset.x()) > 5 || qAbs(offset.y()) > 5))
            m_dragging_tab = true;
        if (m_dragging_tab) {
            int pinned_tabs = pinned_count();
            int first = pinned ? 0 : pinned_tabs;
            int last = pinned ? pinned_tabs - 1 : int(m_tabs.size()) - 1;
            auto from = tab_rect(m_current);
            auto centre = from.center() + offset;
            auto distance = [&](QRectF const& r) { return QLineF(centre, r.center()).length(); };
            int best = m_current;
            qreal nearest = distance(from);
            for (int j = first; j <= last; ++j) {
                if (auto d = distance(tab_rect(j)); d < nearest) {
                    nearest = d;
                    best = j;
                }
            }
            if (best != m_current) {
                QPointF shift = tab_rect(best).topLeft() - from.topLeft();
                if (best > m_current)
                    std::rotate(m_tabs.begin() + m_current, m_tabs.begin() + m_current + 1, m_tabs.begin() + best + 1);
                else
                    std::rotate(m_tabs.begin() + best, m_tabs.begin() + m_current, m_tabs.begin() + m_current + 1);
                m_current = best;
                m_press_pos += shift;
                m_drag_offset -= shift;
            }
            update_chrome();
        }
        return;
    }
    bool in_panel = m_panel && panel_showing() && (m_pressed.hit == Hit::Panel || (hit.hit == Hit::Panel && m_pressed.hit != Hit::Page));
    if (in_panel) {
        auto r = panel_rect();
        m_panel->mouse_move(int(event->position().x()) - r.left(), int(event->position().y()) - r.top(),
            web_buttons(event->buttons()), web_modifiers(event->modifiers()));
        m_panel_has_mouse = true;
    } else if (m_panel_has_mouse) {
        if (m_panel)
            m_panel->mouse_leave();
        m_panel_has_mouse = false;
        m_hovered_link.clear();
    }
    auto* tab = current();
    if (!tab || !tab->view)
        return;
    bool in_page = hit.hit == Hit::Page || m_pressed.hit == Hit::Page;
    if (tab->pdf) {
        if (in_page) {
            tab->pdf->mouse_move(event->position() - page_rect().topLeft(), event->buttons(), event->modifiers());
            m_page_has_mouse = true;
        } else if (m_page_has_mouse) {
            tab->pdf->mouse_leave();
            m_page_has_mouse = false;
        }
        return;
    }
    if (in_page) {
        auto page = page_rect();
        tab->view->mouse_move(int(event->position().x()) - page.left(), int(event->position().y()) - page.top(),
            web_buttons(event->buttons()), web_modifiers(event->modifiers()));
        m_page_has_mouse = true;
    } else if (m_page_has_mouse) {
        tab->view->mouse_leave();
        m_page_has_mouse = false;
        m_hovered_link.clear();
    }
}

void BrowserWindow::wheelEvent(QWheelEvent* event)
{
    if (vertical_tabs() && sidebar_rect().contains(event->position().toPoint())) {
        qreal dy = !event->pixelDelta().isNull() ? -event->pixelDelta().y() : -event->angleDelta().y() / 120.0 * 3 * sidebar_row_height / 2;
        auto was = m_sidebar_scroll;
        m_sidebar_scroll += dy;
        clamp_sidebar_scroll();
        if (m_sidebar_scroll != was) {
            m_hover = hit_test(event->position());
            update(sidebar_rect());
        }
        return;
    }
    if (m_panel && panel_showing() && hit_test(event->position()).hit == Hit::Panel) {
        auto r = panel_rect();
        QPointF delta = !event->pixelDelta().isNull() ? QPointF(-event->pixelDelta()) : QPointF(-event->angleDelta());
        m_panel->wheel(int(event->position().x()) - r.left(), int(event->position().y()) - r.top(), delta.x(), delta.y(),
            web_modifiers(event->modifiers()));
        return;
    }
    auto* tab = current();
    if (!tab || !tab->view || hit_test(event->position()).hit != Hit::Page)
        return;
    if (tab->pdf) {
        tab->pdf->wheel(event->position() - page_rect().topLeft(), event->pixelDelta(), event->angleDelta(), event->modifiers());
        return;
    }
    if (event->modifiers() & Qt::ControlModifier) {
        // Ctrl+wheel zooms, a step a notch.
        auto dy = event->angleDelta().y();
        if (dy)
            zoom_by(dy > 0 ? 1 : -1);
        return;
    }
    auto page = page_rect();
    // A notch is 120 eighths of a degree in angleDelta and scrolls three 40-pixel lines; a touchpad reports pixels.
    QPointF delta = !event->pixelDelta().isNull() ? QPointF(-event->pixelDelta()) : QPointF(-event->angleDelta()) / 120.0 * 120.0;
    tab->view->wheel(int(event->position().x()) - page.left(), int(event->position().y()) - page.top(), delta.x(), delta.y(),
        web_modifiers(event->modifiers()));
}

bool BrowserWindow::address_key(QKeyEvent* event)
{
    auto mods = event->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier);
    bool shift = event->modifiers() & Qt::ShiftModifier;
    auto remove_selection = [this] {
        if (m_address_anchor == m_address_cursor)
            return false;
        int a = qMin(m_address_anchor, m_address_cursor);
        m_address_text.remove(a, qAbs(m_address_anchor - m_address_cursor));
        m_address_cursor = m_address_anchor = a;
        return true;
    };
    auto move = [&](int to) {
        m_address_cursor = qBound(0, to, int(m_address_text.size()));
        if (!shift)
            m_address_anchor = m_address_cursor;
    };
    auto selected = [this] {
        int a = qMin(m_address_anchor, m_address_cursor);
        return m_address_text.mid(a, qAbs(m_address_anchor - m_address_cursor));
    };
    auto paste = [&](QString text) {
        // One line: a pasted newline would end up in the URL.
        text.replace(QLatin1Char('\r'), QLatin1Char(' ')).replace(QLatin1Char('\n'), QLatin1Char(' '));
        remove_selection();
        m_address_text.insert(m_address_cursor, text);
        m_address_cursor += int(text.size());
        m_address_anchor = m_address_cursor;
    };
    auto key = event->key();
    bool ctrl = mods == Qt::ControlModifier;
    bool copy = (ctrl && key == Qt::Key_C) || (ctrl && key == Qt::Key_Insert);
    bool cut = (ctrl && key == Qt::Key_X) || (shift && !mods && key == Qt::Key_Delete);
    bool paste_key = (ctrl && key == Qt::Key_V) || (shift && !mods && key == Qt::Key_Insert);
    if (copy || cut) {
        if (m_address_anchor != m_address_cursor) {
            qt2wasm::gui::setClipboardText(selected());
            if (cut)
                remove_selection();
        }
        update_address();
        return true;
    }
    if (paste_key) {
        paste(qt2wasm::gui::clipboardText());
        update_suggestions();
        return true;
    }
    auto before = m_address_text;
    switch (key) {
    case Qt::Key_Return:
    case Qt::Key_Enter:
        navigate_from_address();
        return true;
    case Qt::Key_Escape:
        // First Escape closes the suggestions (and puts back what was typed), the second leaves the field.
        if (!m_suggestions.isEmpty()) {
            m_address_text = m_typed_text;
            m_address_cursor = m_address_anchor = int(m_address_text.size());
            hide_suggestions();
        } else {
            focus_address(false);
        }
        return true;
    case Qt::Key_Up:
    case Qt::Key_Down: {
        if (m_suggestions.isEmpty())
            return true;
        int n = int(m_suggestions.size());
        m_suggestion = key == Qt::Key_Down ? (m_suggestion + 1 >= n ? -1 : m_suggestion + 1)
                                           : (m_suggestion < 0 ? n - 1 : m_suggestion - 1);
        m_address_text = m_suggestion < 0 ? m_typed_text
            : m_suggestions[m_suggestion].kind == Omnibox::Suggestion::Kind::Search ? m_suggestions[m_suggestion].title
                                                                                     : m_suggestions[m_suggestion].url;
        m_address_cursor = m_address_anchor = int(m_address_text.size());
        update_address();
        return true;
    }
    case Qt::Key_Left:
        move(m_address_cursor - 1);
        break;
    case Qt::Key_Right:
        move(m_address_cursor + 1);
        break;
    case Qt::Key_Home:
        move(0);
        break;
    case Qt::Key_End:
        move(int(m_address_text.size()));
        break;
    case Qt::Key_Backspace:
        if (!remove_selection() && m_address_cursor > 0) {
            m_address_text.remove(m_address_cursor - 1, 1);
            m_address_anchor = --m_address_cursor;
        }
        break;
    case Qt::Key_Delete:
        if (!remove_selection() && m_address_cursor < m_address_text.size())
            m_address_text.remove(m_address_cursor, 1);
        break;
    case Qt::Key_A:
        if (mods == Qt::ControlModifier) {
            m_address_anchor = 0;
            m_address_cursor = int(m_address_text.size());
            update_primary_selection();
            break;
        }
        [[fallthrough]];
    default:
        if (mods & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier))
            return false;
        auto text = event->text();
        if (text.isEmpty() || !text.at(0).isPrint())
            return false;
        remove_selection();
        m_address_text.insert(m_address_cursor, text);
        m_address_cursor += int(text.size());
        m_address_anchor = m_address_cursor;
        break;
    }
    if (shift && m_address_anchor != m_address_cursor)
        update_primary_selection();
    if (m_address_text != before)
        update_suggestions();
    update_address();
    return true;
}

// X11 habit: selected text in the address field is the primary selection, which a middle click pastes.
void BrowserWindow::update_primary_selection()
{
    if (m_address_anchor == m_address_cursor)
        return;
    int a = qMin(m_address_anchor, m_address_cursor);
    qt2wasm::gui::setPrimaryText(m_address_text.mid(a, qAbs(m_address_anchor - m_address_cursor)));
}

void BrowserWindow::keyPressEvent(QKeyEvent* event)
{
    auto mods = event->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier | Qt::MetaModifier);
    auto* tab = current();
    if (tab && !tab->view)
        tab = nullptr;
    auto key = event->key();
    bool ctrl = mods == Qt::ControlModifier;
    bool ctrl_shift = mods == (Qt::ControlModifier | Qt::ShiftModifier);
    // Browser shortcuts first, the Nim front end's.
    if (ctrl && key == Qt::Key_F) {
        open_find();
        return;
    }
    if ((mods == Qt::NoModifier && key == Qt::Key_F3) || (ctrl && key == Qt::Key_G)) {
        m_find_open ? run_find(1) : open_find();
        return;
    }
    if ((mods == Qt::ShiftModifier && key == Qt::Key_F3) || (ctrl_shift && key == Qt::Key_G)) {
        m_find_open ? run_find(-1) : open_find();
        return;
    }
    if ((ctrl || ctrl_shift) && (key == Qt::Key_Plus || key == Qt::Key_Equal)) {
        zoom_by(1);
        return;
    }
    if (ctrl && (key == Qt::Key_Minus || key == Qt::Key_Underscore)) {
        zoom_by(-1);
        return;
    }
    if (ctrl && key == Qt::Key_0) {
        zoom_by(0);
        return;
    }
    if (m_find_open && m_find_focused && !m_address_focused && find_key(event))
        return;
    if (ctrl && key == Qt::Key_D) {
        toggle_bookmark();
        return;
    }
    if (ctrl_shift && key == Qt::Key_B) {
        auto& bookmarks = Profile::Bookmarks::the();
        bookmarks.set_show_bar(!bookmarks.show_bar());
        resizeEvent(nullptr);
        return;
    }
    if ((ctrl && key == Qt::Key_H) || (ctrl_shift && key == Qt::Key_H)) {
        open_own_page(Pages::history_page());
        return;
    }
    if (ctrl && key == Qt::Key_J) {
        open_own_page(Pages::downloads_page());
        return;
    }
    if (ctrl_shift && key == Qt::Key_O) {
        open_own_page(Pages::bookmarks_page());
        return;
    }
    if (ctrl_shift && key == Qt::Key_T) {
        reopen_closed_tab();
        return;
    }
    if (ctrl && key >= Qt::Key_1 && key <= Qt::Key_9 && !m_tabs.empty()) {
        activate_tab(key == Qt::Key_9 ? int(m_tabs.size()) - 1 : qMin(int(key - Qt::Key_1), int(m_tabs.size()) - 1));
        return;
    }
    if (((ctrl_shift && (key == Qt::Key_Backtab || key == Qt::Key_Tab)) || (ctrl && key == Qt::Key_PageUp)) && !m_tabs.empty()) {
        activate_tab((m_current + int(m_tabs.size()) - 1) % int(m_tabs.size()));
        return;
    }
    if (ctrl && key == Qt::Key_PageDown && !m_tabs.empty()) {
        activate_tab((m_current + 1) % int(m_tabs.size()));
        return;
    }
    if ((mods == Qt::NoModifier && key == Qt::Key_F6) || (mods == Qt::AltModifier && key == Qt::Key_D) || (ctrl && key == Qt::Key_K)) {
        focus_address(true);
        return;
    }
    if (mods == Qt::AltModifier && key == Qt::Key_Home) {
        load_in_current({});
        return;
    }
    if (mods == Qt::ControlModifier && event->key() == Qt::Key_T) {
        new_tab({});
        activate_tab(int(m_tabs.size()) - 1);
        focus_address(true);
        return;
    }
    if (mods == Qt::ControlModifier && event->key() == Qt::Key_W) {
        close_tab(m_current);
        return;
    }
    if (mods == Qt::ControlModifier && event->key() == Qt::Key_L) {
        focus_address(true);
        return;
    }
    if ((mods == Qt::ControlModifier && event->key() == Qt::Key_R) || (mods == Qt::NoModifier && event->key() == Qt::Key_F5)) {
        if (tab)
            Pages::is_own_page(from_std(tab->view->url())) ? load_in_current(from_std(tab->view->url())) : tab->view->reload();
        return;
    }
    if (mods == Qt::AltModifier && (event->key() == Qt::Key_Left || event->key() == Qt::Key_Right)) {
        if (tab)
            event->key() == Qt::Key_Left ? tab->view->go_back() : tab->view->go_forward();
        return;
    }
    if (mods == Qt::ControlModifier && event->key() == Qt::Key_Tab && !m_tabs.empty()) {
        activate_tab((m_current + 1) % int(m_tabs.size()));
        return;
    }
    if (m_address_focused) {
        address_key(event);
        return;
    }
    if (m_panel_focused && m_panel && panel_showing()) {
        auto text = event->text();
        uint32_t code_point = text.isEmpty() ? 0 : text.toUcs4().value(0);
        if (code_point && !QChar::isPrint(code_point) && code_point != '\r' && code_point != '\t' && code_point != '\b')
            code_point = 0;
        m_panel->key_down(web_key_code(*event), web_modifiers(event->modifiers()), code_point, event->isAutoRepeat());
        return;
    }
    if (!tab)
        return;
    if (tab->pdf) {
        tab->pdf->key_press(event);
        return;
    }
    auto text = event->text();
    uint32_t code_point = text.isEmpty() ? 0 : text.toUcs4().value(0);
    if (code_point && !QChar::isPrint(code_point) && code_point != '\r' && code_point != '\t' && code_point != '\b')
        code_point = 0;
    tab->view->key_down(web_key_code(*event), web_modifiers(event->modifiers()), code_point, event->isAutoRepeat());
}

void BrowserWindow::keyReleaseEvent(QKeyEvent* event)
{
    if (m_address_focused)
        return;
    if (m_panel_focused && m_panel && panel_showing()) {
        m_panel->key_up(web_key_code(*event), web_modifiers(event->modifiers()), 0);
        return;
    }
    if (auto* tab = current(); tab && tab->view && !tab->pdf)
        tab->view->key_up(web_key_code(*event), web_modifiers(event->modifiers()), 0);
}

// While the page menu is open it takes the window's input. A release still reaches the page that had the press.
bool BrowserWindow::menu_event(QEvent* event)
{
    if (!m_menu.is_open())
        return false;
    switch (event->type()) {
    case QEvent::MouseButtonPress:
    case QEvent::MouseButtonDblClick: {
        auto* mouse = static_cast<QMouseEvent*>(event);
        if (m_menu.mouse_press(mouse->position()))
            update();
        // Swallowed either way, as GTK and Qt menus do: a click outside only closes the menu.
        m_swallow_release = true;
        return true;
    }
    case QEvent::MouseButtonRelease: {
        auto* mouse = static_cast<QMouseEvent*>(event);
        if (m_pressed.hit == Hit::Page) {
            if (auto* pdf = current_pdf()) {
                pdf->mouse_release(mouse->position() - page_rect().topLeft(), mouse->button(), mouse->modifiers());
            } else if (auto* tab = current()) {
                auto page = page_rect();
                m_page_buttons = web_buttons(mouse->buttons());
                tab->view->mouse_up(int(mouse->position().x()) - page.left(), int(mouse->position().y()) - page.top(),
                    web_button(mouse->button()), m_page_buttons, web_modifiers(mouse->modifiers()));
            }
            m_pressed = {};
        }
        if (m_pressed.hit == Hit::Panel) {
            if (m_panel && panel_showing()) {
                auto r = panel_rect();
                m_panel->mouse_up(int(mouse->position().x()) - r.left(), int(mouse->position().y()) - r.top(),
                    web_button(mouse->button()), web_buttons(mouse->buttons()), web_modifiers(mouse->modifiers()));
            }
            m_pressed = {};
        }
        if (m_menu.mouse_release(mouse->position(), mouse->button() == Qt::RightButton))
            update();
        m_swallow_release = false;
        return true;
    }
    case QEvent::MouseMove:
        if (m_menu.mouse_move(static_cast<QMouseEvent*>(event)->position()))
            update();
        return true;
    case QEvent::Wheel:
        m_menu.close();
        update();
        return true;
    case QEvent::KeyPress:
        m_menu.key_press(static_cast<QKeyEvent*>(event));
        update();
        return true;
    case QEvent::KeyRelease:
        return true;
    case QEvent::FocusOut:
        m_menu.close();
        update();
        return false;
    default:
        return false;
    }
}

bool BrowserWindow::event(QEvent* event)
{
    // The page's frame is taken before the window paints, so its damage is part of what this update paints.
    if (event->type() == QEvent::UpdateRequest)
        prepare_page_frame();
    if (menu_event(event))
        return true;
    if (dialog_event(event))
        return true;
    // The release of a click that closed the menu goes nowhere.
    if (m_swallow_release && event->type() == QEvent::MouseButtonRelease) {
        m_swallow_release = false;
        return true;
    }
    if (event->type() == QEvent::Close)
        save_session_on_quit();
    if (event->type() == QEvent::Leave) {
        m_hover = {};
        if (m_panel_has_mouse && m_panel) {
            m_panel->mouse_leave();
            m_panel_has_mouse = false;
        }
        if (m_page_has_mouse) {
            if (auto* pdf = current_pdf())
                pdf->mouse_leave();
            else if (auto* tab = current(); tab && tab->view)
                tab->view->mouse_leave();
            m_page_has_mouse = false;
        }
        update();
    }
    return QRasterWindow::event(event);
}

// Find in page.

QRectF BrowserWindow::find_rect() const
{
    qreal w = qMin<qreal>(420, page_rect().width() - 24);
    // Under the PDF viewer's bar when a PDF shows.
    qreal below = const_cast<BrowserWindow*>(this)->current_pdf() ? 40 : 0;
    qreal right = page_rect().right() + 1;
    return { right - w - 12, chrome_height() + 8.0 + below, w, 40 };
}

QRectF BrowserWindow::find_button_rect(int index) const
{
    auto r = find_rect();
    return { r.right() - 8 - (3 - index) * 30.0, r.top() + 5, 30, 30 };
}

void BrowserWindow::open_find()
{
    auto* tab = current();
    if (!tab || !tab->view)
        return;
    if (m_address_focused)
        focus_address(false);
    m_find_open = true;
    m_find_focused = true;
    QGuiApplication::inputMethod()->show();
    // The page's selection is the first query, as in other browsers.
    auto selected = (tab->pdf ? tab->pdf->selected_text() : from_std(tab->view->selected_text())).simplified();
    if (!selected.isEmpty() && selected.size() < 200)
        m_find_text = selected;
    run_find(0);
    update();
}

void BrowserWindow::close_find()
{
    if (!m_find_open)
        return;
    m_find_open = false;
    m_find_focused = false;
    if (!m_address_focused)
        QGuiApplication::inputMethod()->hide();
    m_find_result = {};
    if (auto* pdf = current_pdf())
        pdf->find_end();
    else if (auto* tab = current(); tab && tab->view)
        tab->view->find_end();
    update();
}

void BrowserWindow::run_find(int direction)
{
    auto* tab = current();
    if (!tab || !tab->view)
        return;
    if (auto* pdf = tab->pdf.get()) {
        if (m_find_text.isEmpty()) {
            pdf->find_end();
            m_find_result = {};
        } else if (direction == 0) {
            m_find_result = pdf->find(m_find_text);
        } else {
            m_find_result = direction > 0 ? pdf->find_next() : pdf->find_previous();
        }
        update();
        return;
    }
    if (m_find_text.isEmpty()) {
        tab->view->find_end();
        m_find_result = {};
    } else if (direction == 0) {
        m_find_result = tab->view->find(to_std(m_find_text), false);
    } else {
        m_find_result = direction > 0 ? tab->view->find_next() : tab->view->find_previous();
    }
    update();
}

bool BrowserWindow::find_key(QKeyEvent* event)
{
    auto mods = event->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier);
    switch (event->key()) {
    case Qt::Key_Escape:
        close_find();
        return true;
    case Qt::Key_Return:
    case Qt::Key_Enter:
        run_find(event->modifiers() & Qt::ShiftModifier ? -1 : 1);
        return true;
    case Qt::Key_Backspace:
        if (!m_find_text.isEmpty()) {
            m_find_text.chop(1);
            run_find(0);
        }
        return true;
    default:
        break;
    }
    if (mods == Qt::ControlModifier && event->key() == Qt::Key_V) {
        auto text = qt2wasm::gui::clipboardText().simplified();
        if (!text.isEmpty()) {
            m_find_text += text;
            run_find(0);
        }
        return true;
    }
    if (mods == Qt::ControlModifier && event->key() == Qt::Key_A) {
        m_find_text.clear();
        run_find(0);
        return true;
    }
    if (mods)
        return false;
    auto text = event->text();
    if (text.isEmpty() || !text.at(0).isPrint())
        return false;
    m_find_text += text;
    run_find(0);
    return true;
}

void BrowserWindow::paint_find(QPainter& p)
{
    if (!m_find_open)
        return;
    auto r = find_rect();
    p.setPen(QPen(WebbyUI::theme().border, 1));
    p.setBrush(tab_color);
    p.drawRoundedRect(r, 10, 10);
    QFont font = p.font();
    font.setPixelSize(14);
    p.setFont(font);
    QFontMetricsF metrics(font);
    QString count;
    if (!m_find_text.isEmpty()) {
        if (m_find_result.total == 0)
            count = QStringLiteral("No results");
        else if (m_find_result.total > 0)
            count = QStringLiteral("%1 of %2").arg(m_find_result.index + 1).arg(m_find_result.total);
    }
    qreal count_width = count.isEmpty() ? 0 : metrics.horizontalAdvance(count) + 12;
    auto text = QRectF(r.left() + 14, r.top(), find_button_rect(0).left() - r.left() - 18 - count_width, r.height());
    p.save();
    p.setClipRect(text);
    qreal baseline = text.center().y() + (metrics.ascent() - metrics.descent()) / 2;
    if (m_find_text.isEmpty()) {
        p.setPen(dim_text_color);
        p.drawText(text, Qt::AlignVCenter | Qt::AlignLeft, QStringLiteral("Find in page"));
    } else {
        // The end of a long query stays in view.
        qreal w = metrics.horizontalAdvance(m_find_text);
        qreal x = text.left() + qMin<qreal>(0, text.width() - w - 2);
        p.setPen(text_color);
        p.drawText(QPointF(x, baseline), m_find_text);
    }
    qreal caret = text.left() + qMin(metrics.horizontalAdvance(m_find_text), text.width() - 2);
    p.setPen(QPen(m_find_focused ? text_color : Qt::transparent, 1));
    p.drawLine(QPointF(caret, text.center().y() - metrics.height() / 2), QPointF(caret, text.center().y() + metrics.height() / 2));
    p.restore();
    if (!count.isEmpty()) {
        p.setPen(m_find_result.total == 0 ? WebbyUI::theme().error : dim_text_color);
        p.drawText(QRectF(text.right() + 6, r.top(), count_width, r.height()), Qt::AlignVCenter | Qt::AlignLeft, count);
    }
    Hit hits[] = { Hit::FindPrevious, Hit::FindNext, Hit::FindClose };
    for (int i = 0; i < 3; ++i) {
        auto b = find_button_rect(i);
        if (m_hover.hit == hits[i]) {
            p.setPen(Qt::NoPen);
            p.setBrush(button_hover_color);
            p.drawEllipse(b.adjusted(2, 2, -2, -2));
        }
        p.setPen(QPen(text_color, 1.6, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.setBrush(Qt::NoBrush);
        auto c = b.center();
        if (i == 2) {
            p.drawLine(c + QPointF(-5, -5), c + QPointF(5, 5));
            p.drawLine(c + QPointF(5, -5), c + QPointF(-5, 5));
        } else {
            qreal d = i == 0 ? -1 : 1;
            p.drawLine(c + QPointF(-6, -3 * d), c + QPointF(0, 3 * d));
            p.drawLine(c + QPointF(0, 3 * d), c + QPointF(6, -3 * d));
        }
    }
}

// Zoom: the Nim front end's (and Chrome's) steps.

void BrowserWindow::zoom_by(int steps)
{
    auto* tab = current();
    if (!tab || !tab->view)
        return;
    if (tab->pdf) {
        // Ctrl+0 fits the width, as in the Nim viewer.
        tab->pdf->zoom_step(steps);
        update();
        return;
    }
    static constexpr double levels[] = { 0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0 };
    double zoom = tab->view->zoom();
    double next = 1.0;
    if (steps > 0) {
        next = levels[std::size(levels) - 1];
        for (double level : levels) {
            if (level > zoom + 0.001) {
                next = level;
                break;
            }
        }
    } else if (steps < 0) {
        next = levels[0];
        for (double level : levels) {
            if (level < zoom - 0.001)
                next = level;
        }
    }
    tab->view->set_zoom(next);
    update();
}

QRectF BrowserWindow::zoom_rect() const
{
    auto* tab = const_cast<BrowserWindow*>(this)->current();
    // The PDF viewer's bar shows its own zoom.
    if (!tab || !tab->view || tab->pdf || qAbs(tab->view->zoom() - 1.0) < 0.001)
        return {};
    auto star = star_rect();
    return { star.left() - 52, star.top() + 6, 50, star.height() - 12 };
}

// The toast: one line over the bottom left of the page, like the link status bubble but taller.

void BrowserWindow::show_toast(QString const& text)
{
    m_toast = text;
    m_toast_timer.start();
    update();
}

void BrowserWindow::paint_toast(QPainter& p)
{
    if (m_toast.isEmpty())
        return;
    QFont font = p.font();
    font.setPixelSize(13);
    p.setFont(font);
    QFontMetricsF metrics(font);
    auto text = metrics.elidedText(m_toast, Qt::ElideMiddle, width() - 64);
    QRectF box((width() - metrics.horizontalAdvance(text) - 32) / 2, height() - 56, metrics.horizontalAdvance(text) + 32, 36);
    p.setPen(Qt::NoPen);
    p.setBrush(QColor(0x30, 0x31, 0x34));
    p.drawRoundedRect(box, 8, 8);
    p.setPen(Qt::white);
    p.drawText(box, Qt::AlignCenter, text);
}


// PDFs.

WebbyUI::PdfView* BrowserWindow::current_pdf()
{
    auto* tab = current();
    return tab && tab->view ? tab->pdf.get() : nullptr;
}

void BrowserWindow::open_pdf(WebbyUI::WebView* view, WebbyUI::PdfDocument& document)
{
    Tab* tab = nullptr;
    for (auto& t : m_tabs) {
        if (t.view.get() == view)
            tab = &t;
    }
    if (!tab)
        return;
    QByteArray bytes(reinterpret_cast<char const*>(document.data.data()), qsizetype(document.data.size()));
    document.data.clear();
    document.data.shrink_to_fit();
    auto pdf = std::make_unique<WebbyUI::PdfView>(from_std(document.url), std::move(bytes), from_std(document.mime));
    auto* raw = pdf.get();
    raw->on_needs_paint = [this, raw] {
        if (current_pdf() == raw)
            request_page_frame();
    };
    raw->on_link_hover = [this, raw](QString const& link) {
        if (current_pdf() == raw) {
            auto was = status_rect();
            m_hovered_link = link;
            update(QRegion(was) | status_rect());
        }
    };
    raw->on_open_url = [this, raw](QString const& url, bool in_new_tab) {
        if (in_new_tab)
            open_in_new_tab(url, false);
        else if (current_pdf() == raw)
            load_in_current(url);
    };
    raw->on_save = [this, raw] {
        for (auto& t : m_tabs) {
            if (t.pdf.get() == raw)
                save_pdf(t);
        }
    };
    raw->resize(page_rect().size());
    tab->pdf = std::move(pdf);
    if (current() == tab) {
        close_find();
        m_hovered_link.clear();
        m_page_frame.invalidate();
        request_page_frame();
    }
    Profile::History::the().set_title(tab->pdf->url(), tab->pdf->title());
    sync_from_view();
}

void BrowserWindow::show_pdf_menu(QPointF at)
{
    auto* tab = current();
    auto* pdf = current_pdf();
    if (!pdf)
        return;
    auto* view = tab->view.get();
    // The viewer may be gone (its tab closed or navigated) by the time a row runs: look it up again.
    auto with_pdf = [this, pdf](auto f) {
        return [this, pdf, f] {
            for (auto& t : m_tabs) {
                if (t.pdf.get() == pdf) {
                    f(t);
                    return;
                }
            }
        };
    };
    auto link = pdf->link_at(at - page_rect().topLeft());
    m_menu.close();
    if (!link.uri.isEmpty()) {
        auto url = link.uri;
        m_menu.add(QStringLiteral("Open link in new tab"), [this, url] { new_tab(url); });
        m_menu.add(QStringLiteral("Copy link address"), [url] { qt2wasm::gui::setClipboardText(url); });
        m_menu.add_separator();
    }
    if (pdf->has_selection()) {
        m_menu.add(QStringLiteral("Copy"), QStringLiteral("Ctrl+C"), with_pdf([](Tab& t) { t.pdf->copy_selection(); }));
        m_menu.add(QStringLiteral("Ask AI about this"), with_pdf([this](Tab& t) {
            if (t.view)
                ask_about_selection(t.view.get(), t.pdf->selected_text().trimmed());
        }));
        m_menu.add_separator();
    }
    m_menu.add(QStringLiteral("Select all"), QStringLiteral("Ctrl+A"), with_pdf([](Tab& t) { t.pdf->select_all(); }));
    m_menu.add(QStringLiteral("Find…"), QStringLiteral("Ctrl+F"), [this] { open_find(); });
    m_menu.add(QStringLiteral("Save PDF"), QStringLiteral("Ctrl+S"), with_pdf([this](Tab& t) { save_pdf(t); }));
    m_menu.add_separator();
    m_menu.add(QStringLiteral("Back"), [this, view] {
        if (auto* t = current(); t && t->view.get() == view)
            view->go_back();
    }, view->can_go_back());
    m_menu.add(QStringLiteral("Reload"), [this, view] {
        if (auto* t = current(); t && t->view.get() == view)
            view->reload();
    });
    auto url = pdf->url();
    m_menu.add(QStringLiteral("Copy page address"), [url] { qt2wasm::gui::setClipboardText(url); });
    m_menu.open(at, size());
    update();
}

// Save: the PDF's bytes into the downloads folder (as the engine saves downloads: $WEBBY_DOWNLOAD_DIR, else
// $XDG_DOWNLOAD_DIR, else ~/Downloads; "name (1).pdf" rather than overwriting), and into the Downloads page's list.
void BrowserWindow::save_pdf(Tab& tab)
{
    if (!tab.pdf)
        return;
    QString dir;
    for (auto const* name : { "WEBBY_DOWNLOAD_DIR", "XDG_DOWNLOAD_DIR" }) {
        if (dir.isEmpty())
            dir = qEnvironmentVariable(name);
    }
    if (dir.isEmpty()) {
        auto home = qEnvironmentVariable("HOME");
        dir = (home.isEmpty() ? QStringLiteral("/tmp") : home) + QStringLiteral("/Downloads");
    }
    QDir().mkpath(dir);
    auto name = tab.pdf->file_name();
    auto stem = name.left(name.size() - 4);
    QString path;
    QFile file;
    for (int i = 0; i < 1000; ++i) {
        path = dir + u'/' + (i == 0 ? name : QStringLiteral("%1 (%2).pdf").arg(stem).arg(i));
        if (QFile::exists(path))
            continue;
        file.setFileName(path);
        if (file.open(QIODevice::WriteOnly | QIODevice::NewOnly))
            break;
    }
    QString error;
    if (!file.isOpen())
        error = QStringLiteral("cannot write in %1").arg(dir);
    else if (file.write(tab.pdf->data()) != tab.pdf->data().size())
        error = file.errorString();
    file.close();
    if (!error.isEmpty())
        QFile::remove(path);
    Profile::DownloadRecord record { tab.pdf->url(), error.isEmpty() ? path : QString(), qint64(tab.pdf->data().size()),
        QStringLiteral("application/pdf"), error, Profile::now_ms() };
    Profile::add_download(record);
    if (error.isEmpty()) {
        tab.pdf->set_status(QStringLiteral("Saved as %1").arg(path.section(u'/', -1)));
        show_toast(QStringLiteral("Saved %1 to %2  ·  Ctrl+J").arg(path.section(u'/', -1), dir));
    } else {
        tab.pdf->set_status(QStringLiteral("Couldn't save: %1").arg(error));
    }
}
