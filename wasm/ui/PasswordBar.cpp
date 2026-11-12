/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The window's side of passwords and passkeys (Passwords.h): the bar under the toolbar that offers to save, fill or
// generate a password for the current tab's page, and the passkey dialog, as the Nim front end's passwords.nim.

#include "BrowserWindow.h"
#include "Pages.h"
#include "Passwords.h"

#include <QFontMetricsF>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QJsonArray>
#include <qt2wasm/gui.h>

using namespace WebbyUI;
using Offer = PasswordManager::Offer;

namespace {

QColor const bar_color { 0xf8, 0xf9, 0xfa };
QColor const text_color { 0x20, 0x21, 0x24 };
QColor const accent { 0x1a, 0x73, 0xe8 };
QColor const hover { 0xe8, 0xea, 0xed };

QFont bar_font(bool bold = false)
{
    QFont f;
    f.setPixelSize(13);
    f.setBold(bold);
    return f;
}

QString label_of(Offer const& o)
{
    auto host = Vault::host_of(o.origin);
    switch (o.kind) {
    case Offer::Kind::Save: {
        auto who = o.username.isEmpty() ? QStringLiteral("this account") : o.username;
        return (o.update ? QStringLiteral("Update the saved password for %1 on %2?") : QStringLiteral("Save the password for %1 on %2?")).arg(who, host);
    }
    case Offer::Kind::Generate:
        return QStringLiteral("Use a strong password:  %1").arg(o.password);
    case Offer::Kind::Fill:
        return QStringLiteral("Fill a saved password for %1").arg(host);
    case Offer::Kind::None:
        break;
    }
    return {};
}

// The bar's buttons, left to right, each with what it does.
struct Action {
    QString label;
    bool primary { false };
    std::function<void(WebView*)> run;
};

std::vector<Action> actions_of(Offer const& o)
{
    auto& m = PasswordManager::the();
    std::vector<Action> a;
    switch (o.kind) {
    case Offer::Kind::Save:
        if (!o.update)
            a.push_back({ QStringLiteral("Never for this site"), false, [&m](WebView* v) { m.never_save(v); } });
        a.push_back({ QStringLiteral("Not now"), false, [&m](WebView* v) { m.dismiss(v); } });
        a.push_back({ o.update ? QStringLiteral("Update") : QStringLiteral("Save"), true, [&m](WebView* v) { m.save(v); } });
        break;
    case Offer::Kind::Generate:
        a.push_back({ QStringLiteral("Another one"), false, [&m](WebView* v) { m.regenerate(v); } });
        a.push_back({ QStringLiteral("No thanks"), false, [&m](WebView* v) { m.dismiss(v); } });
        a.push_back({ QStringLiteral("Use password"), true, [&m](WebView* v) { m.use_generated(v); } });
        break;
    case Offer::Kind::Fill:
        for (int i = 0; i < int(o.accounts.size()) && i < 4; ++i) {
            auto account = o.accounts[i];
            a.push_back({ account.username.isEmpty() ? QStringLiteral("(no username)") : account.username, false,
                [&m, account](WebView* v) { m.fill(v, account); } });
        }
        a.push_back({ QStringLiteral("✕"), false, [&m](WebView* v) { m.dismiss(v); } });
        break;
    case Offer::Kind::None:
        break;
    }
    return a;
}

}

void BrowserWindow::setup_passwords()
{
    auto& m = PasswordManager::the();
    m.on_offer_changed = [this](WebView* view) { password_offer_changed(view); };
    m.on_passkey_prompt = [this](WebView* view, QJsonObject const& prompt) { show_passkey_dialog(view, prompt); };
    m.copy_to_clipboard = [this](QString const& text) {
        qt2wasm::gui::setClipboardText(text);
        show_toast(QStringLiteral("Copied"));
    };
    m.start();
}

bool BrowserWindow::show_password_bar() const
{
    auto* tab = const_cast<BrowserWindow*>(this)->current();
    return tab && tab->view && PasswordManager::the().offer(tab->view.get()).kind != Offer::Kind::None;
}

QRectF BrowserWindow::password_bar_rect() const
{
    qreal top = tab_strip_height + toolbar_height + (show_bookmarks_bar() ? bookmarks_bar_height : 0);
    return { 0, top, qreal(width()), qreal(password_bar_height) };
}

std::vector<BrowserWindow::BarButton> BrowserWindow::password_bar_buttons() const
{
    std::vector<BarButton> buttons;
    auto* tab = const_cast<BrowserWindow*>(this)->current();
    if (!tab || !tab->view)
        return buttons;
    auto actions = actions_of(PasswordManager::the().offer(tab->view.get()));
    auto bar = password_bar_rect();
    QFontMetricsF metrics(bar_font());
    qreal x = bar.right() - 12;
    for (int i = int(actions.size()) - 1; i >= 0; --i) {
        qreal w = metrics.horizontalAdvance(actions[i].label) + 28;
        x -= w;
        buttons.insert(buttons.begin(), { actions[i].label, QRectF(x, bar.top() + 6, w, bar.height() - 12), actions[i].primary });
        x -= 6;
    }
    return buttons;
}

void BrowserWindow::paint_password_bar(QPainter& p)
{
    if (!show_password_bar())
        return;
    auto bar = password_bar_rect();
    p.save();
    p.fillRect(bar, bar_color);
    p.fillRect(QRectF(bar.left(), bar.top(), 3, bar.height()), accent);
    p.setPen(QPen(QColor(0xda, 0xdc, 0xe0), 1));
    p.drawLine(QPointF(0, bar.bottom() - 0.5), QPointF(width(), bar.bottom() - 0.5));
    auto buttons = password_bar_buttons();
    qreal text_right = buttons.empty() ? bar.right() - 12 : buttons.front().rect.left() - 12;
    // A key.
    QPointF key(bar.left() + 22, bar.center().y());
    p.setPen(QPen(text_color, 1.6, Qt::SolidLine, Qt::RoundCap));
    p.setBrush(Qt::NoBrush);
    p.drawEllipse(key + QPointF(-4, 0), 4, 4);
    p.drawLine(key + QPointF(0, 0), key + QPointF(9, 0));
    p.drawLine(key + QPointF(6, 0), key + QPointF(6, 3));
    p.drawLine(key + QPointF(9, 0), key + QPointF(9, 3));
    p.setFont(bar_font());
    p.setPen(text_color);
    auto text = QRectF(bar.left() + 42, bar.top(), text_right - bar.left() - 42, bar.height());
    auto* tab = current();
    p.drawText(text, Qt::AlignVCenter | Qt::AlignLeft,
        QFontMetricsF(bar_font()).elidedText(label_of(PasswordManager::the().offer(tab->view.get())), Qt::ElideRight, text.width()));
    for (int i = 0; i < int(buttons.size()); ++i) {
        auto const& b = buttons[i];
        bool hovered = m_hover.hit == Hit::PasswordBar && m_hover.tab == i;
        QPainterPath path;
        path.addRoundedRect(b.rect, b.rect.height() / 2, b.rect.height() / 2);
        if (b.primary) {
            p.fillPath(path, hovered ? accent.darker(115) : accent);
            p.setPen(Qt::white);
        } else {
            p.fillPath(path, hovered ? hover : Qt::white);
            p.setPen(QPen(QColor(0xda, 0xdc, 0xe0), 1));
            p.drawPath(path);
            p.setPen(accent);
        }
        p.drawText(b.rect, Qt::AlignCenter, b.label);
    }
    p.restore();
}

void BrowserWindow::password_bar_click(int button)
{
    auto* tab = current();
    if (!tab || !tab->view)
        return;
    auto actions = actions_of(PasswordManager::the().offer(tab->view.get()));
    if (button >= 0 && button < int(actions.size()))
        actions[button].run(tab->view.get());
}

void BrowserWindow::password_offer_changed(WebView* view)
{
    auto* tab = current();
    if (!tab || tab->view.get() != view)
        return;
    // The bar showing or hiding changes the page's height.
    if (tab->view->height() != page_rect().height())
        resizeEvent(nullptr);
    update();
}

void BrowserWindow::open_passwords_page()
{
    open_own_page(PasswordManager::page_url());
}

// ---------------------------------------------------------------------------------------------------------------
// Passkeys: one dialog at a time, as passwords.nim's runPasskeyDialogs.

void BrowserWindow::show_passkey_dialog(WebView* view, QJsonObject const& prompt)
{
    if (m_dialog.is_open() || m_dialog_view) {
        m_passkey_requests.push_back({ view, prompt });
        return;
    }
    // A site in a background tab asking for a passkey brings its tab forward.
    for (int i = 0; i < int(m_tabs.size()); ++i) {
        if (m_tabs[i].view.get() == view && i != m_current)
            activate_tab(i);
    }
    m_menu.close();
    auto rp_id = prompt.value(u"rpId").toString();
    QString title, text;
    QStringList buttons;
    std::vector<ModalDialog::Row> rows;
    bool get = prompt.value(u"type").toString() != u"create";
    if (!get) {
        auto user = prompt.value(u"userName").toString();
        auto display = prompt.value(u"userDisplayName").toString();
        auto account = !display.isEmpty() && display != user ? QStringLiteral("%1 (%2)").arg(display, user) : user;
        if (prompt.value(u"alreadyRegistered").toBool()) {
            title = QStringLiteral("Passkey already saved");
            text = QStringLiteral("This browser already has a passkey for your account on %1.").arg(rp_id);
            buttons = { QStringLiteral("Cancel"), QStringLiteral("OK") };
        } else {
            title = QStringLiteral("Create a passkey?");
            text = QStringLiteral("Save a passkey for %1 on %2. It stays in this browser's password vault and signs you in without a password.")
                       .arg(account.isEmpty() ? QStringLiteral("your account") : account, rp_id);
            buttons = { QStringLiteral("Cancel"), QStringLiteral("Create") };
        }
    } else {
        auto accounts = prompt.value(u"accounts").toArray();
        if (accounts.isEmpty()) {
            title = QStringLiteral("No passkeys");
            text = QStringLiteral("This browser has no passkeys for %1.").arg(rp_id);
            buttons = { QStringLiteral("OK") };
        } else {
            title = QStringLiteral("Sign in to %1").arg(rp_id);
            text = QStringLiteral("Choose a passkey:");
            buttons = { QStringLiteral("Cancel") };
            for (auto const& a : accounts) {
                auto o = a.toObject();
                auto name = o.value(u"userName").toString();
                auto display = o.value(u"userDisplayName").toString();
                rows.push_back(display.isEmpty() ? ModalDialog::Row { name, {} } : ModalDialog::Row { display, name });
            }
        }
    }
    bool has_accounts = !rows.empty();
    m_dialog_view = view;
    m_dialog.open(title, text, std::move(rows), buttons, [this, get, has_accounts](int result) {
        auto* view = m_dialog_view;
        m_dialog_view = nullptr;
        if (view) {
            if (get && has_accounts) {
                int chosen = result >= ModalDialog::row_result ? result - ModalDialog::row_result : -1;
                view->webauthn_respond(chosen >= 0, chosen);
            } else {
                view->webauthn_respond(!get && result == 1, -1);
            }
            // A sign-up made its passkey just now: into the vault with it.
            PasswordManager::the().sync_passkeys();
        }
        update();
        QTimer::singleShot(0, this, [this] { next_passkey_dialog(); });
    });
    update();
}

void BrowserWindow::next_passkey_dialog()
{
    if (m_dialog.is_open() || m_passkey_requests.empty())
        return;
    auto [view, prompt] = m_passkey_requests.front();
    m_passkey_requests.erase(m_passkey_requests.begin());
    show_passkey_dialog(view, prompt);
}

bool BrowserWindow::dialog_event(QEvent* event)
{
    if (!m_dialog.is_open())
        return false;
    switch (event->type()) {
    case QEvent::MouseButtonPress:
    case QEvent::MouseButtonDblClick:
        if (m_dialog.mouse_press(static_cast<QMouseEvent*>(event)->position(), size()))
            update();
        m_swallow_release = true;
        return true;
    case QEvent::MouseButtonRelease:
        m_swallow_release = false;
        return true;
    case QEvent::MouseMove:
        if (m_dialog.mouse_move(static_cast<QMouseEvent*>(event)->position(), size()))
            update();
        return true;
    case QEvent::Wheel:
    case QEvent::KeyRelease:
        return true;
    case QEvent::KeyPress:
        if (m_dialog.key_press(static_cast<QKeyEvent*>(event)))
            update();
        return true;
    default:
        return false;
    }
}
