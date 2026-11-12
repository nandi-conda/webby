/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The UI component has no passwords yet: the vault, the page script and the passkey authenticator need OpenSSL and
// the engine's page hooks, which webby:engine (../wit/engine) does not carry. These keep BrowserWindow's calls.

#include "BrowserWindow.h"
#include "Pages.h"
#include "Passwords.h"

using namespace WebbyUI;

PasswordManager& PasswordManager::the()
{
    static PasswordManager manager;
    return manager;
}
void PasswordManager::start() { }
void PasswordManager::attach(WebView&) { }
void PasswordManager::detach(WebView*) { }
void PasswordManager::url_changed(WebView*) { }
PasswordManager::Offer const& PasswordManager::offer(WebView*) const
{
    static Offer const none;
    return none;
}
void PasswordManager::sync_passkeys() { }
QString PasswordManager::page_url() { return {}; }
bool PasswordManager::is_page(QString const&) { return false; }

void BrowserWindow::setup_passwords() { }
bool BrowserWindow::show_password_bar() const { return false; }
QRectF BrowserWindow::password_bar_rect() const { return {}; }
std::vector<BrowserWindow::BarButton> BrowserWindow::password_bar_buttons() const { return {}; }
void BrowserWindow::paint_password_bar(QPainter&) { }
void BrowserWindow::password_bar_click(int) { }
void BrowserWindow::password_offer_changed(WebView*) { }
void BrowserWindow::show_passkey_dialog(WebView*, QJsonObject const&) { }
void BrowserWindow::next_passkey_dialog() { }
bool BrowserWindow::dialog_event(QEvent*) { return false; }
void BrowserWindow::open_passwords_page() { show_toast(QStringLiteral("Passwords are not in this build of webby yet")); }
