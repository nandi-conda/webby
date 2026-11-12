/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Passwords and passkeys for the wasm UI, as the Nim front end's nim/src/features/passwords.nim: the page script
// (nim/src/scripts/passwords.js) reports password fields and submitted logins, and the chrome offers to save, fill
// or generate a password in a bar over the page; passkey requests get a dialog; the vault (Vault.h) keeps it all, the
// authenticator's passkeys included. The "Passwords and passkeys" page lists what is saved.

#pragma once

#include "Vault.h"

#include <QJsonObject>
#include <QList>
#include <QString>
#include <functional>
#include <map>

namespace WebbyUI {

class WebView;

class PasswordManager {
public:
    static PasswordManager& the();

    // Opens the vault (once) and installs the page scripts. `on_vault_state` runs whenever the vault opens or fails to.
    void start();
    std::function<void()> on_vault_state;

    // A tab's view: its page messages and passkey requests come here.
    void attach(WebView&);
    void detach(WebView*);
    // The view's page changed address: offers for another site go.
    void url_changed(WebView*);

    struct Offer {
        enum class Kind { None, Save, Fill, Generate };
        Kind kind { Kind::None };
        QString origin;
        QString username;
        QString password;
        bool update { false }; // Save: a different password for a saved account
        QList<SavedPassword> accounts; // Fill
    };
    Offer const& offer(WebView*) const;
    // The offer changed (the bar shows the current tab's).
    std::function<void(WebView*)> on_offer_changed;

    // The bar's buttons.
    void dismiss(WebView*);
    void save(WebView*);
    void never_save(WebView*);
    void fill(WebView*, SavedPassword const&);
    void use_generated(WebView*);
    void regenerate(WebView*);

    // A page asked for a passkey: the chrome shows `prompt` (WebView::on_webauthn_prompt's JSON) and answers with
    // WebView::webauthn_respond.
    std::function<void(WebView*, QJsonObject const& prompt)> on_passkey_prompt;
    // Saves the authenticator's passkeys into the vault if they changed: after each answered request (a sign-up makes
    // one inside WebView::webauthn_respond).
    void sync_passkeys();

    // The "Passwords and passkeys" page: its file:// URL, written afresh (it holds no secrets: the page asks for
    // them over its own message channel).
    static QString page_url();
    static bool is_page(QString const& url);
    // Copies text to the clipboard (the page's Copy buttons).
    std::function<void(QString const&)> copy_to_clipboard;

private:
    struct Agent {
        QString url;
        QString filled_origin;
        QString generated; // the generated password put in the page, saved without asking once it is sent
        Offer offer;
    };
    void set_offer(WebView*, Offer);
    void page_message(WebView&, QString const& text, QString const& document_url);
    void vault_page_message(WebView&, QJsonObject const& message);
    void send_vault_page_data(WebView&);
    void use_vault_passkeys();
    void open_vault();
    void vault_opened();

    std::map<WebView*, Agent> m_agents;
    bool m_started { false };
    Vault* m_hooked { nullptr };
    bool m_passkeys_in_vault { false };
    uint64_t m_passkey_serial { 0 };
};

}
