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
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QPolygonF>
#include <QStyleHints>
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
        auto saved = Profile::read_open_tabs(active);
        for (auto const& tab : saved)
            new_tab(tab.url, -1, true, tab.title, tab.created);
    }
    bool blank = urls.isEmpty() && m_tabs.empty();
    if (blank)
        new_tab({});
    for (auto const& url : urls)
        new_tab(url);
    activate_tab(active);
    if (blank)
        focus_address(true);

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

int BrowserWindow::chrome_height() const
{
    return tab_strip_height + toolbar_height + (show_bookmarks_bar() ? bookmarks_bar_height : 0) + (show_password_bar() ? password_bar_height : 0);
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
    Profile::write_open_tabs(tabs, m_current);
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
    if (auto* view = m_tabs[index].view.get()) {
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
}

void BrowserWindow::activate_tab(int index)
{
    if (index < 0 || index >= int(m_tabs.size()))
        return;
    if (index != m_current) {
        m_menu.close();
        close_find();
    }
    m_current = index;
    auto page = page_rect();
    if (!m_tabs[index].view)
        wake(m_tabs[index]);
    if (!m_tabs[index].view)
        return;
    m_tabs[index].view->resize(page.width(), page.height());
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
    } else {
        hide_suggestions();
        if (auto* tab = current(); tab && tab->view)
            m_address_text = from_std(tab->view->url());
    }
    update_chrome();
}

// Geometry, in logical pixels.

QRectF BrowserWindow::tab_rect(int index) const
{
    qreal available = width() - 8 - 40;
    qreal w = m_tabs.empty() ? max_tab_width : qBound<qreal>(min_tab_width, available / m_tabs.size(), max_tab_width);
    return { 8 + index * w, 6, w - 2, qreal(tab_strip_height - 6) };
}

QRectF BrowserWindow::tab_close_rect(int index) const
{
    auto r = tab_rect(index);
    return { r.right() - 26, r.top() + (r.height() - 18) / 2, 18, 18 };
}

QRectF BrowserWindow::new_tab_rect() const
{
    auto r = tab_rect(int(m_tabs.size()));
    return { r.left() + 4, r.top() + (r.height() - 26) / 2, 26, 26 };
}

QRectF BrowserWindow::button_rect(int index) const
{
    return { 8.0 + index * (button_size + 4), tab_strip_height + (toolbar_height - button_size) / 2.0, qreal(button_size), qreal(button_size) };
}

QRectF BrowserWindow::address_rect() const
{
    auto left = button_rect(3).left() + 4;
    qreal right = toolbar_button_rect(ButtonCount - 1).left() - 6;
    return { left, tab_strip_height + 6.0, qMax<qreal>(80, right - left), toolbar_height - 12.0 };
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
            return { x, qreal(tab_strip_height + toolbar_height + 3), w, bookmarks_bar_height - 6.0 };
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
    return { 0, chrome_height(), qMax(1, width()), qMax(1, height() - chrome_height()) };
}

BrowserWindow::HitResult BrowserWindow::hit_test(QPointF p) const
{
    for (int i = 0; i < int(m_suggestions.size()); ++i) {
        if (suggestion_rect(i).contains(p))
            return { Hit::Suggestion, i };
    }
    for (int i = 0; i < int(m_tabs.size()); ++i) {
        if (tab_close_rect(i).contains(p))
            return { Hit::TabClose, i };
        if (tab_rect(i).contains(p))
            return { Hit::Tab, i };
    }
    if (new_tab_rect().contains(p))
        return { Hit::NewTab };
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
    p.fillRect(QRectF(0, 0, width(), tab_strip_height), strip_color);
    QFont font = p.font();
    font.setPixelSize(13);
    p.setFont(font);
    QFontMetricsF metrics(font);
    auto now = Profile::now_seconds();
    for (int i = 0; i < int(m_tabs.size()); ++i) {
        auto r = tab_rect(i);
        if (m_dragging_tab && i == m_current)
            r.translate(m_drag_offset, 0);
        if (!needs_paint(r))
            continue;
        bool active = i == m_current;
        bool hovered = m_hover.tab == i && (m_hover.hit == Hit::Tab || m_hover.hit == Hit::TabClose);
        if (active || hovered) {
            QPainterPath path;
            path.addRoundedRect(r.adjusted(0, 0, 0, 8), 8, 8);
            p.save();
            p.setClipRect(QRectF(0, 0, width(), tab_strip_height));
            p.fillPath(path, active ? tab_color : tab_hover_color);
            p.restore();
        }
        auto text_rect = r.adjusted(12, 0, -30, 0);
        auto title = m_tabs[i].loading ? QStringLiteral("Loading…") : m_tabs[i].title;
        // A young tab gets a small orange dot before its close button, fainter at each step (the Nim strip's).
        int step = -1;
        for (int k = 0; k < int(std::size(age_steps)) && Profile::age_colors(); ++k) {
            if (m_tabs[i].created > 0 && now - m_tabs[i].created < age_steps[k]) {
                step = k;
                break;
            }
        }
        if (step >= 0) {
            text_rect.adjust(0, 0, -10, 0);
            QColor dot = age_color;
            dot.setAlphaF(1.0 - step * 0.18);
            p.setPen(Qt::NoPen);
            p.setBrush(dot);
            p.drawEllipse(QPointF(r.right() - 34, r.center().y()), 3, 3);
        }
        p.setPen(active ? text_color : dim_text_color);
        p.drawText(text_rect, Qt::AlignVCenter | Qt::AlignLeft, metrics.elidedText(title, Qt::ElideRight, text_rect.width()));
        auto c = tab_close_rect(i).translated(r.left() - tab_rect(i).left(), 0);
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
    auto n = new_tab_rect();
    if (!needs_paint(n))
        return;
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

void BrowserWindow::paint_toolbar(QPainter& p)
{
    QRectF bar(0, tab_strip_height, width(), toolbar_height);
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
    QRectF bar(0, tab_strip_height + toolbar_height, width(), bookmarks_bar_height);
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
    if (auto* tab = current(); tab && tab->view) {
        auto page = page_rect();
        tab->view->resize(page.width(), page.height());
        if (tab->pdf)
            tab->pdf->resize(page.size());
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
            update();
        }
    }
    if (hit.hit == Hit::Suggestion) {
        if (event->button() == Qt::LeftButton && hit.tab < m_suggestions.size()) {
            auto url = m_suggestions[hit.tab].url;
            m_address_focused = false;
            load_in_current(url);
        }
        m_pressed = {};
        return;
    }
    if (hit.hit != Hit::Address && hit.hit != Hit::None && m_address_focused)
        focus_address(false);
    auto* tab = current();
    if (tab && !tab->view)
        tab = nullptr;
    switch (hit.hit) {
    case Hit::Tab:
        if (event->button() == Qt::MiddleButton) {
            close_tab(hit.tab);
        } else {
            activate_tab(hit.tab);
            m_press_x = event->position().x();
            m_drag_offset = 0;
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
    if (hit.hit == Hit::None && event->position().y() < tab_strip_height) {
        new_tab({});
        activate_tab(int(m_tabs.size()) - 1);
        focus_address(true);
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
        m_drag_offset = 0;
        m_save_timer.start();
        update();
        return;
    }
    auto* tab = current();
    if (tab && !tab->view)
        tab = nullptr;
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
        // Dragging a tab: it follows the pointer and changes places with a neighbour it passes half of.
        m_drag_offset = event->position().x() - m_press_x;
        if (!m_dragging_tab && qAbs(m_drag_offset) > 5)
            m_dragging_tab = true;
        if (m_dragging_tab) {
            qreal w = tab_rect(0).width() + 2;
            while (m_drag_offset > w / 2 && m_current + 1 < int(m_tabs.size())) {
                std::swap(m_tabs[m_current], m_tabs[m_current + 1]);
                ++m_current;
                m_press_x += w;
                m_drag_offset -= w;
            }
            while (m_drag_offset < -w / 2 && m_current > 0) {
                std::swap(m_tabs[m_current], m_tabs[m_current - 1]);
                --m_current;
                m_press_x -= w;
                m_drag_offset += w;
            }
            update();
        }
        return;
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
    qreal w = qMin<qreal>(420, width() - 24);
    // Under the PDF viewer's bar when a PDF shows.
    qreal below = const_cast<BrowserWindow*>(this)->current_pdf() ? 40 : 0;
    return { width() - w - 12, chrome_height() + 8.0 + below, w, 40 };
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
