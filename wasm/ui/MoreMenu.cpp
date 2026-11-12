/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The toolbar buttons right of the address field and the ⋮ menu, as the Nim front end has them: Bookmarks, History
// and Downloads buttons, then ⋮ with Chrome's grouping (nim/src/browser.nim moreMenuItems: windows, history,
// bookmarks, downloads, this page, settings, help).

#include "BrowserWindow.h"
#include "Omnibox.h"
#include "Pages.h"
#include "Sync.h"

#include <QPainter>
#include <QPainterPath>
#include <QPolygonF>
#include <QtMath>
#include <cmath>
#include <qt2wasm/gui.h>

using namespace WebbyUI;

namespace {

QColor const text_color { 0x20, 0x21, 0x24 };
QColor const button_hover_color { 0xe8, 0xea, 0xed };
constexpr int toolbar_button_size = 32;

QString from_std(std::string const& s) { return QString::fromUtf8(s.data(), qsizetype(s.size())); }

}

QRectF BrowserWindow::toolbar_button_rect(int button) const
{
    qreal right = width() - 8;
    qreal x = right - (button + 1) * (toolbar_button_size + 4) + 4;
    return { x, tab_strip_height + (toolbar_height - toolbar_button_size) / 2.0, qreal(toolbar_button_size), qreal(toolbar_button_size) };
}

void BrowserWindow::paint_toolbar_buttons(QPainter& p)
{
    p.save();
    for (int k = 0; k < ButtonCount; ++k) {
        auto r = toolbar_button_rect(k);
        if (m_hover.hit == Hit::Toolbar && m_hover.tab == k) {
            p.setPen(Qt::NoPen);
            p.setBrush(button_hover_color);
            p.drawEllipse(r);
        }
        auto c = r.center();
        p.setPen(QPen(text_color, 1.7, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.setBrush(Qt::NoBrush);
        switch (k) {
        case ButtonMore:
            p.setPen(Qt::NoPen);
            p.setBrush(text_color);
            for (int d = -1; d <= 1; ++d)
                p.drawEllipse(QPointF(c.x(), c.y() + d * 5.5), 1.8, 1.8);
            break;
        case ButtonDownloads:
            // An arrow down onto a tray.
            p.drawLine(QPointF(c.x(), c.y() - 7), QPointF(c.x(), c.y() + 3));
            p.drawLine(QPointF(c.x() - 4.5, c.y() - 1.5), QPointF(c.x(), c.y() + 3));
            p.drawLine(QPointF(c.x() + 4.5, c.y() - 1.5), QPointF(c.x(), c.y() + 3));
            p.drawLine(QPointF(c.x() - 7, c.y() + 7), QPointF(c.x() + 7, c.y() + 7));
            break;
        case ButtonHistory: {
            // A clock with a turning-back arrow.
            QRectF face(c.x() - 7, c.y() - 7, 14, 14);
            p.drawArc(face, 200 * 16, -310 * 16);
            QPointF tail(c.x() - 7 * std::cos(qDegreesToRadians(200.0)), c.y() + 7 * std::sin(qDegreesToRadians(200.0)));
            p.drawLine(tail, tail + QPointF(-3.5, -1));
            p.drawLine(tail, tail + QPointF(0.5, -3.5));
            p.drawLine(c, QPointF(c.x(), c.y() - 4));
            p.drawLine(c, QPointF(c.x() + 3, c.y() + 2));
            break;
        }
        case ButtonBookmarks: {
            // A bookmark ribbon.
            QPolygonF ribbon;
            ribbon << QPointF(c.x() - 5, c.y() - 7) << QPointF(c.x() + 5, c.y() - 7) << QPointF(c.x() + 5, c.y() + 7)
                   << QPointF(c.x(), c.y() + 3) << QPointF(c.x() - 5, c.y() + 7);
            p.drawPolygon(ribbon);
            break;
        }
        }
    }
    p.restore();
}

void BrowserWindow::toolbar_button(int button)
{
    switch (button) {
    case ButtonBookmarks:
        open_own_page(Pages::bookmarks_page());
        break;
    case ButtonHistory:
        open_own_page(Pages::history_page());
        break;
    case ButtonDownloads:
        open_own_page(Pages::downloads_page());
        break;
    case ButtonMore:
        open_more_menu();
        break;
    }
}

void BrowserWindow::open_more_menu()
{
    m_menu.close();
    auto& menu = m_menu;
    auto* tab = current();
    bool has_page = tab && tab->view;
    QString url = has_page ? from_std(tab->view->url()) : QString {};

    menu.add(QStringLiteral("New tab"), QStringLiteral("Ctrl+T"), [this] { new_tab({}); });
    menu.add_separator();

    auto& history = menu.add_submenu(QStringLiteral("History"));
    history.add(QStringLiteral("History"), QStringLiteral("Ctrl+H"), [this] { open_own_page(Pages::history_page()); });
    if (!m_closed.isEmpty()) {
        history.add_separator();
        history.add_heading(QStringLiteral("Recently closed"));
        history.add(QStringLiteral("Reopen closed tab"), QStringLiteral("Ctrl+Shift+T"), [this] { reopen_closed_tab(); });
        int shown = 0;
        for (auto i = m_closed.size() - 1; i >= 0 && shown < 8; --i, ++shown) {
            auto const& closed = m_closed[i];
            auto label = closed.title.isEmpty() ? closed.url : closed.title;
            if (label.size() > 60)
                label = label.left(58) + QStringLiteral("…");
            auto closed_url = closed.url;
            history.add(label, [this, i, closed_url] {
                if (i < m_closed.size() && m_closed[i].url == closed_url)
                    m_closed.removeAt(i);
                open_in_new_tab(closed_url, true);
            });
        }
    }

    history.add_separator();
    history.add(QStringLiteral("Tabs from other devices"), [this] { open_own_page(Pages::devices_page()); });

    auto& bookmarks = menu.add_submenu(QStringLiteral("Bookmarks"));
    bool marked = has_page && Profile::Bookmarks::the().contains(url);
    bookmarks.add(marked ? QStringLiteral("Remove this bookmark") : QStringLiteral("Bookmark this page"), QStringLiteral("Ctrl+D"),
        [this] { toggle_bookmark(); }, has_page && Profile::is_session_url(url));
    bookmarks.add_check(QStringLiteral("Show bookmarks bar"), Profile::Bookmarks::the().show_bar(), QStringLiteral("Ctrl+Shift+B"), [this] {
        auto& b = Profile::Bookmarks::the();
        b.set_show_bar(!b.show_bar());
        resizeEvent(nullptr);
    });
    bookmarks.add(QStringLiteral("Bookmark manager"), QStringLiteral("Ctrl+Shift+O"), [this] { open_own_page(Pages::bookmarks_page()); });

    menu.add(QStringLiteral("Downloads"), QStringLiteral("Ctrl+J"), [this] { open_own_page(Pages::downloads_page()); });
    menu.add(QStringLiteral("Passwords and passkeys"), [this] { open_passwords_page(); });
    menu.add_separator();

    menu.add(QStringLiteral("Find in page…"), QStringLiteral("Ctrl+F"), [this] { open_find(); }, has_page);
    auto& zoom = menu.add_submenu(has_page ? QStringLiteral("Zoom (%1%)").arg(qRound(tab->view->zoom() * 100)) : QStringLiteral("Zoom"));
    zoom.add(QStringLiteral("Zoom in"), QStringLiteral("Ctrl+="), [this] { zoom_by(1); }, has_page);
    zoom.add(QStringLiteral("Zoom out"), QStringLiteral("Ctrl+-"), [this] { zoom_by(-1); }, has_page);
    zoom.add(QStringLiteral("Actual size"), QStringLiteral("Ctrl+0"), [this] { zoom_by(0); }, has_page);
    menu.add(QStringLiteral("Reload"), QStringLiteral("Ctrl+R"), [this] {
        if (auto* t = current(); t && t->view)
            t->view->reload();
    }, has_page);
    menu.add(QStringLiteral("Copy page address"), [url] { qt2wasm::gui::setClipboardText(url); }, !url.isEmpty());
    menu.add_separator();

    auto& settings = menu.add_submenu(QStringLiteral("Settings"));
    settings.add(WebbyUI::Sync::enabled() ? QStringLiteral("Sync (on)") : QStringLiteral("Sync"), [this] { open_own_page(Pages::sync_page()); });
    settings.add_separator();
    settings.add_check(QStringLiteral("Restore tabs at start"), Profile::ui_setting(QStringLiteral("restoreTabs")).toBool(true), {}, [] {
        Profile::set_ui_setting(QStringLiteral("restoreTabs"), !Profile::ui_setting(QStringLiteral("restoreTabs")).toBool(true));
    });
    settings.add_check(QStringLiteral("Color tabs by age"), Profile::age_colors(), {}, [this] {
        Profile::set_age_colors(!Profile::age_colors());
        update();
    });
    settings.add_check(QStringLiteral("Show bookmarks bar"), Profile::Bookmarks::the().show_bar(), {}, [this] {
        auto& b = Profile::Bookmarks::the();
        b.set_show_bar(!b.show_bar());
        resizeEvent(nullptr);
    });
    auto& engines = settings.add_submenu(QStringLiteral("Search engine"));
    bool custom = !qEnvironmentVariableIsEmpty("WEBBY_SEARCH_URL");
    if (custom)
        engines.add_heading(QStringLiteral("Set by WEBBY_SEARCH_URL"));
    auto current_engine = Omnibox::engine_name();
    for (auto const& engine : Omnibox::engines()) {
        QString name = QString::fromUtf8(engine.name);
        engines.add_check(name, !custom && name == current_engine, {}, [name] { Omnibox::set_engine(name); });
    }

    auto& help = menu.add_submenu(QStringLiteral("Help"));
    help.add(QStringLiteral("Keyboard shortcuts"), [this] { open_own_page(Pages::shortcuts_page()); });
    help.add(QStringLiteral("About Webby"), [this] { open_own_page(Pages::about_page()); });

    auto r = toolbar_button_rect(ButtonMore);
    menu.open(QPointF(r.right(), r.bottom() + 2), size());
    update();
}
