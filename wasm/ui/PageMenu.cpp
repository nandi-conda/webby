/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The page's right-click menu, with the rows the Nim desktop front end offers (nim/src/features/tabs/contextmenu.nim):
// link, image and text rows first, then navigation.

#include "BrowserWindow.h"

#include <QUrl>
#include <qt2wasm/gui.h>

namespace {

QString from_std(std::string const& s) { return QString::fromUtf8(s.data(), qsizetype(s.size())); }
std::string to_std(QString const& s) { return s.toUtf8().toStdString(); }

QString ellipsize(QString const& text, int n)
{
    auto one = text.simplified();
    return one.size() <= n ? one : one.left(n) + QChar(0x2026);
}

}

void BrowserWindow::show_page_menu(WebbyUI::WebView* view, WebbyUI::ContextMenu const& info)
{
    auto* tab = current();
    if (!tab || tab->view.get() != view)
        return;
    // The view may be gone (its tab closed) by the time a row runs: look it up again.
    auto alive = [this, view] {
        for (auto const& t : m_tabs) {
            if (t.view.get() == view)
                return true;
        }
        return false;
    };
    auto with_view = [alive, view](auto f) {
        return [alive, view, f] {
            if (alive())
                f(*view);
        };
    };
    auto in_new_tab = [this](QString url) {
        return [this, url] { new_tab(url); };
    };
    auto copy = [](QString text) {
        return [text] { qt2wasm::gui::setClipboardText(text); };
    };

    auto link = from_std(info.link);
    auto link_text = from_std(info.link_text).simplified();
    auto image = from_std(info.image);
    auto selection = from_std(info.selection);

    m_menu.close();
    if (!link.isEmpty()) {
        m_menu.add(QStringLiteral("Open link in new tab"), in_new_tab(link));
        m_menu.add(QStringLiteral("Open link"), with_view([link](WebbyUI::WebView& v) { v.load(to_std(link)); }));
        m_menu.add(QStringLiteral("Copy link address"), copy(link));
        if (!link_text.isEmpty())
            m_menu.add(QStringLiteral("Copy link text"), copy(link_text));
        m_menu.add_separator();
    }
    if (!image.isEmpty()) {
        m_menu.add(QStringLiteral("Open image in new tab"), in_new_tab(image));
        m_menu.add(QStringLiteral("Copy image address"), copy(image));
        m_menu.add_separator();
    }
    if (info.editable) {
        bool has = !selection.isEmpty();
        m_menu.add(QStringLiteral("Cut"), with_view([](WebbyUI::WebView& v) {
            auto text = v.cut_selection();
            if (!text.empty())
                qt2wasm::gui::setClipboardText(from_std(text));
        }), has);
        m_menu.add(QStringLiteral("Copy"), copy(selection), has);
        m_menu.add(QStringLiteral("Paste"), with_view([](WebbyUI::WebView& v) { v.insert_text(to_std(qt2wasm::gui::clipboardText())); }));
        m_menu.add(QStringLiteral("Select all"), with_view([](WebbyUI::WebView& v) { v.select_all(); }));
        m_menu.add_separator();
    } else if (!selection.trimmed().isEmpty()) {
        auto query = selection.simplified();
        m_menu.add(QStringLiteral("Copy"), copy(selection));
        m_menu.add(QStringLiteral("Ask AI about this"), [this, alive, view, selection] {
            if (alive())
                ask_about_selection(view, selection.trimmed());
        });
        m_menu.add(QStringLiteral("Search the web for “%1”").arg(ellipsize(query, 30)),
            in_new_tab(QStringLiteral("https://duckduckgo.com/?q=") + QString::fromLatin1(QUrl::toPercentEncoding(query))));
        m_menu.add_separator();
    }
    if (link.isEmpty() && image.isEmpty() && !info.editable) {
        m_menu.add(QStringLiteral("Back"), with_view([](WebbyUI::WebView& v) { v.go_back(); }), view->can_go_back());
        m_menu.add(QStringLiteral("Forward"), with_view([](WebbyUI::WebView& v) { v.go_forward(); }), view->can_go_forward());
        m_menu.add(QStringLiteral("Reload"), with_view([](WebbyUI::WebView& v) { v.reload(); }));
        m_menu.add_separator();
        m_menu.add(QStringLiteral("Select all"), with_view([](WebbyUI::WebView& v) { v.select_all(); }));
        auto url = from_std(view->url());
        m_menu.add(QStringLiteral("Copy page address"), copy(url), !url.isEmpty());
    }
    auto page = page_rect();
    m_menu.open(QPointF(page.left() + info.x, page.top() + info.y), size());
    update();
}
