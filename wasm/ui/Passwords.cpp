/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Passwords.h"
#include "Summarize.h"
#include "Pages.h"
#include "Passkeys.h"
#include "Resources.h"
#include "Sync.h"
#include "WebView.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QTimer>

using namespace Qt::StringLiterals;

namespace WebbyUI {

namespace {

// After the view's prefix, so other features' messages aren't ours.
QString const password_tag = u"passwords:"_s;
QString const vault_tag = u"vault:"_s;

QString from_std(std::string const& s) { return QString::fromUtf8(s.data(), qsizetype(s.size())); }
std::string to_std(QString const& s) { return s.toUtf8().toStdString(); }

// A JavaScript string literal.
QString js(QString const& s)
{
    auto json = QJsonDocument(QJsonArray { s }).toJson(QJsonDocument::Compact);
    return QString::fromUtf8(json.mid(1, json.size() - 2));
}

// Runs after the current task: the page script that sent the message we answer may not have finished defining
// window.__webbyPasswords yet (passwords.nim's deferred).
QString deferred(QString const& source) { return u"setTimeout(() => { "_s + source + u" }, 0);"_s; }

QString const& password_script()
{
    static QString const script = QString::fromUtf8(webby_builtin_passwords_js);
    return script;
}

// The Passwords page's channel: window.__webbyVault.send(message) posts, window.__webbyVaultShow(data) is called back.
QString vault_page_script(QString const& prefix)
{
    return uR"js((() => {
  const PREFIX = %1;
  const prompt = window.prompt;
  Object.defineProperty(window, '__webbyVault', { value: Object.freeze({
    send(message) { setTimeout(() => { try { prompt.call(window, PREFIX + JSON.stringify(message)); } catch (e) {} }, 0); },
  }) });
})();)js"_s.arg(js(prefix));
}

}

PasswordManager& PasswordManager::the()
{
    static PasswordManager manager;
    return manager;
}

void PasswordManager::start()
{
    if (m_started)
        return;
    m_started = true;
    WebView::add_page_script([](WebView& view) -> std::string {
        auto url = from_std(view.url());
        if (is_page(url))
            return to_std(vault_page_script(from_std(view.message_prefix()) + vault_tag));
        if (Vault::origin_of(url).isEmpty())
            return {};
        auto script = password_script();
        script.replace(u"${jsonEncode(prefix)}"_s, js(from_std(view.message_prefix()) + password_tag));
        return to_std(script);
    });
    open_vault();
}

void PasswordManager::open_vault()
{
    Vault::open([this] { vault_opened(); });
}

void PasswordManager::vault_opened()
{
    if (auto* vault = Vault::the(); vault && vault != m_hooked) {
        m_hooked = vault;
        vault->on_change([this] {
            for (auto& [view, agent] : m_agents) {
                if (is_page(from_std(view->url())))
                    send_vault_page_data(*view);
            }
        });
        use_vault_passkeys();
        hook_sync(*vault);
        // Summarize's API keys and provider choice are vault secrets, as on the desktop.
        Summarize::set_secret_store({
            [](QString const& name) { auto* v = Vault::the(); return v ? v->secret(name) : QString(); },
            [](QString const& name, QString const& value, bool sync) {
                if (auto* v = Vault::the())
                    v->set_secret(name, value, sync);
            },
            [](QString const& name) { auto* v = Vault::the(); return v ? v->secret_syncs(name) : true; },
        });
    }
    for (auto& [view, agent] : m_agents) {
        if (is_page(from_std(view->url())))
            send_vault_page_data(*view);
    }
    if (on_vault_state)
        on_vault_state();
}

// Sync keeps its settings in the vault from now on, and syncs the passwords, passkeys and synced secrets with it.
void PasswordManager::hook_sync(Vault& vault)
{
    namespace Sync = WebbyUI::Sync;
    Sync::set_settings_store([] { auto* v = Vault::the(); return v ? v->sync_settings() : QJsonObject {}; },
        [](QJsonObject const& s) {
            if (auto* v = Vault::the())
                v->set_sync_settings(s);
        });
    Sync::register_blob(Sync::Blob::Vault, [] { auto* v = Vault::the(); return v ? v->to_sync_doc() : QJsonObject {}; },
        [](QJsonObject const& merged) {
            if (auto* v = Vault::the())
                v->apply_sync_doc(merged);
        });
    Sync::register_blob(Sync::Blob::Secrets, [] { auto* v = Vault::the(); return v ? v->secrets_sync_doc() : QJsonObject {}; },
        [](QJsonObject const& merged) {
            if (auto* v = Vault::the())
                v->apply_secrets_sync_doc(merged);
        });
    vault.on_change([] {
        Sync::local_changed(Sync::Blob::Vault);
        Sync::local_changed(Sync::Blob::Secrets);
    });
    // The vault may hold the settings sync was waiting for: a round soon (once sync has started).
    Sync::local_changed(Sync::Blob::Vault);
}

void PasswordManager::use_vault_passkeys()
{
    auto* vault = Vault::the();
    if (!vault || !Passkeys::use_vault(QJsonDocument(vault->passkeys()).toJson(QJsonDocument::Compact).toStdString()))
        return;
    // The authenticator now has the vault's passkeys plus any from its old file: save that, then drop the file.
    m_passkeys_in_vault = true;
    m_passkey_serial = Passkeys::serial();
    vault->set_passkeys(QJsonDocument::fromJson(QByteArray::fromStdString(Passkeys::export_json())).array());
    if (!Passkeys::delete_file())
        qWarning("webby: could not delete the old passkeys file");
}

void PasswordManager::sync_passkeys()
{
    auto* vault = Vault::the();
    if (!vault || !m_passkeys_in_vault)
        return;
    auto serial = Passkeys::serial();
    if (serial == m_passkey_serial)
        return;
    m_passkey_serial = serial;
    vault->set_passkeys(QJsonDocument::fromJson(QByteArray::fromStdString(Passkeys::export_json())).array());
}

void PasswordManager::attach(WebView& view)
{
    m_agents[&view] = Agent { from_std(view.url()), {}, {}, {} };
    view.on_page_message = [this, &view](std::string const& text, std::string const& document_url) {
        page_message(view, from_std(text), from_std(document_url));
    };
    view.on_webauthn_prompt = [this, &view](std::string const& prompt) {
        auto json = QJsonDocument::fromJson(QByteArray::fromStdString(prompt)).object();
        if (on_passkey_prompt)
            on_passkey_prompt(&view, json);
        else
            view.webauthn_respond(false, -1);
    };
}

void PasswordManager::detach(WebView* view)
{
    m_agents.erase(view);
}

void PasswordManager::url_changed(WebView* view)
{
    auto it = m_agents.find(view);
    if (it == m_agents.end())
        return;
    auto url = from_std(view->url());
    auto& agent = it->second;
    if (url == agent.url)
        return;
    agent.url = url;
    agent.filled_origin.clear();
    agent.generated.clear();
    // A save offer outlives the navigation a login form starts; the others belong to the page.
    if ((agent.offer.kind == Offer::Kind::Fill || agent.offer.kind == Offer::Kind::Generate) && agent.offer.origin != Vault::origin_of(url))
        set_offer(view, {});
}

PasswordManager::Offer const& PasswordManager::offer(WebView* view) const
{
    static Offer const none;
    auto it = m_agents.find(view);
    return it == m_agents.end() ? none : it->second.offer;
}

void PasswordManager::set_offer(WebView* view, Offer offer)
{
    auto it = m_agents.find(view);
    if (it == m_agents.end())
        return;
    it->second.offer = std::move(offer);
    if (on_offer_changed)
        on_offer_changed(view);
}

void PasswordManager::dismiss(WebView* view) { set_offer(view, {}); }

void PasswordManager::save(WebView* view)
{
    auto o = offer(view);
    if (auto* vault = Vault::the(); vault && o.kind == Offer::Kind::Save)
        vault->save_password(o.origin, o.username, o.password);
    dismiss(view);
}

void PasswordManager::never_save(WebView* view)
{
    auto o = offer(view);
    if (auto* vault = Vault::the(); vault && o.kind == Offer::Kind::Save)
        vault->set_never_save(o.origin, true);
    dismiss(view);
}

void PasswordManager::fill(WebView* view, SavedPassword const& account)
{
    auto it = m_agents.find(view);
    if (it == m_agents.end())
        return;
    auto origin = Vault::origin_of(from_std(view->url()));
    if (origin.isEmpty() || origin != account.origin)
        return;
    it->second.filled_origin = origin;
    view->run_javascript(to_std(deferred(u"window.__webbyPasswords && window.__webbyPasswords.fill(%1, %2, %3);"_s
                                             .arg(js(account.username), js(account.password), js(origin)))));
    if (it->second.offer.kind == Offer::Kind::Fill)
        dismiss(view);
}

void PasswordManager::use_generated(WebView* view)
{
    auto it = m_agents.find(view);
    if (it == m_agents.end())
        return;
    auto o = it->second.offer;
    if (o.kind != Offer::Kind::Generate || Vault::origin_of(from_std(view->url())) != o.origin)
        return;
    it->second.generated = o.password;
    view->run_javascript(to_std(deferred(u"window.__webbyPasswords && window.__webbyPasswords.fillNew(%1, %2);"_s.arg(js(o.password), js(o.origin)))));
    dismiss(view);
}

void PasswordManager::regenerate(WebView* view)
{
    auto o = offer(view);
    if (o.kind != Offer::Kind::Generate)
        return;
    o.password = generate_password();
    set_offer(view, o);
}

// passwords.nim's onMessage.
void PasswordManager::page_message(WebView& view, QString const& text, QString const& document_url)
{
    if (text.startsWith(vault_tag)) {
        if (is_page(document_url) && is_page(from_std(view.url())))
            vault_page_message(view, QJsonDocument::fromJson(text.mid(vault_tag.size()).toUtf8()).object());
        return;
    }
    if (!text.startsWith(password_tag))
        return;
    auto it = m_agents.find(&view);
    auto* vault = Vault::the();
    // The page that sent it: a login form's submit arrives once its navigation has begun.
    auto origin = Vault::origin_of(document_url);
    if (it == m_agents.end() || !vault || origin.isEmpty())
        return;
    auto& agent = it->second;
    url_changed(&view);
    auto message = QJsonDocument::fromJson(text.mid(password_tag.size()).toUtf8()).object();
    auto kind = message.value(u"type").toString();
    if (kind == u"newPassword") {
        // Not again for the confirm field once a password is in, or while one is on offer.
        if (!agent.generated.isEmpty() || agent.offer.kind == Offer::Kind::Save
            || (agent.offer.kind == Offer::Kind::Generate && agent.offer.origin == origin))
            return;
        Offer o;
        o.kind = Offer::Kind::Generate;
        o.origin = origin;
        o.password = generate_password();
        set_offer(&view, o);
    } else if (kind == u"fields" || kind == u"focus") {
        auto accounts = vault->passwords_for(origin);
        if (accounts.isEmpty() || agent.offer.kind == Offer::Kind::Save)
            return;
        if (accounts.size() == 1 && kind == u"fields" && agent.filled_origin != origin) {
            fill(&view, accounts.first()); // one account: fill it straight away, the way other browsers do
        } else if (agent.filled_origin != origin || accounts.size() > 1) {
            Offer o;
            o.kind = Offer::Kind::Fill;
            o.origin = origin;
            o.accounts = accounts;
            set_offer(&view, o);
        }
    } else if (kind == u"submit") {
        auto username = message.value(u"username").toString();
        auto password = message.value(u"password").toString();
        if (password.isEmpty())
            return;
        if (password == agent.generated) {
            agent.generated.clear();
            vault->save_password(origin, username, password);
            if (agent.offer.kind == Offer::Kind::Generate)
                dismiss(&view);
            return;
        }
        if (vault->is_never_save(origin))
            return;
        auto const* existing = vault->find(origin, username);
        if (existing && existing->password == password)
            return;
        Offer o;
        o.kind = Offer::Kind::Save;
        o.origin = origin;
        o.username = username;
        o.password = password;
        o.update = existing != nullptr;
        set_offer(&view, o);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// The Passwords and passkeys page

QString PasswordManager::page_url() { return Pages::passwords_page(); }

bool PasswordManager::is_page(QString const& url)
{
    return Pages::is_own_page(url) && url.section(u'?', 0, 0).section(u'#', 0, 0).endsWith(u"/passwords.html"_s);
}

void PasswordManager::send_vault_page_data(WebView& view)
{
    QJsonObject data;
    auto* vault = Vault::the();
    if (!vault) {
        data[u"error"_s] = Vault::error().isEmpty() ? u"The password vault is opening…"_s : Vault::error();
        data[u"canStartOver"_s] = !Vault::error().isEmpty() && Vault::exists();
    } else {
        QJsonArray passwords;
        for (auto const& p : vault->passwords())
            passwords.append(p.to_json());
        data[u"passwords"_s] = passwords;
        QJsonArray passkeys;
        for (auto const& v : vault->passkeys()) {
            // Never the private key.
            auto p = v.toObject();
            passkeys.append(QJsonObject { { u"credentialId"_s, p.value(u"credentialId") }, { u"rpId"_s, p.value(u"rpId") },
                { u"userName"_s, p.value(u"userName") }, { u"userDisplayName"_s, p.value(u"userDisplayName") }, { u"createdAt"_s, p.value(u"createdAt") } });
        }
        data[u"passkeys"_s] = passkeys;
        data[u"neverSave"_s] = QJsonArray::fromStringList(vault->never_save());
        data[u"keyInFile"_s] = vault->key_store() == Vault::KeyStore::File;
    }
    auto json = QString::fromUtf8(QJsonDocument(data).toJson(QJsonDocument::Compact));
    view.run_javascript(to_std(deferred(u"window.__webbyVaultShow && window.__webbyVaultShow("_s + json + u");"_s)));
}

void PasswordManager::vault_page_message(WebView& view, QJsonObject const& message)
{
    auto kind = message.value(u"type").toString();
    auto* vault = Vault::the();
    if (kind == u"ready") {
        send_vault_page_data(view);
    } else if (kind == u"retry") {
        open_vault();
    } else if (kind == u"startOver") {
        if (!Vault::the() && !Vault::set_aside().isEmpty())
            open_vault();
    } else if (kind == u"copy") {
        auto id = message.value(u"id").toString();
        if (vault && copy_to_clipboard) {
            if (auto const* p = vault->find_id(id))
                copy_to_clipboard(message.value(u"what").toString() == u"username" ? p->username : p->password);
        }
    } else if (kind == u"delete" && vault) {
        vault->delete_password(message.value(u"id").toString());
    } else if (kind == u"update" && vault) {
        auto id = message.value(u"id").toString();
        if (auto const* p = vault->find_id(id)) {
            auto origin = p->origin;
            vault->update_password(id, origin, message.value(u"username").toString(), message.value(u"password").toString());
        }
    } else if (kind == u"add" && vault) {
        auto origin = Vault::origin_of(message.value(u"site").toString());
        if (!origin.isEmpty() && !message.value(u"password").toString().isEmpty())
            vault->save_password(origin, message.value(u"username").toString(), message.value(u"password").toString());
    } else if (kind == u"generate") {
        view.run_javascript(to_std(deferred(u"window.__webbyVaultGenerated && window.__webbyVaultGenerated(%1);"_s.arg(js(generate_password())))));
    } else if (kind == u"deletePasskey" && vault && m_passkeys_in_vault) {
        Passkeys::remove(to_std(message.value(u"id").toString()));
        sync_passkeys();
    } else if (kind == u"allowSave" && vault) {
        vault->set_never_save(message.value(u"origin").toString(), false);
    }
}

}
