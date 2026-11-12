/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Vault.h"
#include "Keyring.h"
#include "Passkeys.h"
#include "Profile.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QTimer>
#include <QUrl>
#include <algorithm>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <sys/stat.h>

using namespace Qt::StringLiterals;

namespace WebbyUI {

namespace {

constexpr char aad[] = "webby-vault-v1";
QString const sections[] = { u"passwords"_s, u"passkeys"_s, u"neverSave"_s };
QString const deleted_sections[] = { u"passwords"_s, u"passkeys"_s, u"neverSave"_s, u"secrets"_s };

std::unique_ptr<Vault> s_vault;
QString s_error;
bool s_opening = false;
std::vector<std::function<void()>> s_waiting;

qint64 now() { return QDateTime::currentSecsSinceEpoch(); }

QByteArray random_bytes(int n)
{
    QByteArray bytes(n, Qt::Uninitialized);
    if (n > 0 && RAND_bytes(reinterpret_cast<unsigned char*>(bytes.data()), n) != 1)
        qFatal("webby: RAND_bytes failed");
    return bytes;
}

QString profile_name()
{
    // Profile names become directory names (vault.nim's profileName).
    auto name = qEnvironmentVariable("WEBBY_PROFILE");
    bool ok = !name.isEmpty() && name != u"." && name != u"..";
    for (auto c : name) {
        if (!(c.isLetterOrNumber() && c.unicode() < 128) && c != u'.' && c != u'_' && c != u'-')
            ok = false;
    }
    return ok ? name : u"default"_s;
}

bool write_private(QString const& path, QByteArray const& content)
{
    // Atomically, readable only by the user.
    QDir().mkpath(QFileInfo(path).absolutePath());
    auto tmp = path + u".tmp"_s;
    QFile f(tmp);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return false;
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    bool ok = f.write(content) == content.size();
    f.close();
    if (!ok)
        return false;
    ::chmod(QFile::encodeName(tmp).constData(), 0600);
    QFile::remove(path);
    return QFile::rename(tmp, path);
}

QJsonObject tombstone(qint64 at, QString const& id = {})
{
    QJsonObject r;
    if (!id.isEmpty())
        r[u"id"_s] = id;
    r[u"updatedAt"_s] = at;
    r[u"deleted"_s] = true;
    return r;
}

bool is_deleted(QJsonValue const& record) { return record.toObject().value(u"deleted").toBool(); }
qint64 updated_at_of(QJsonValue const& record)
{
    auto t = record.toObject().value(u"updatedAt");
    return t.isDouble() ? qint64(t.toDouble()) : 0;
}

}

QJsonObject SavedPassword::to_json() const
{
    return { { u"id"_s, id }, { u"origin"_s, origin }, { u"username"_s, username }, { u"password"_s, password },
        { u"createdAt"_s, created_at }, { u"updatedAt"_s, updated_at } };
}

SavedPassword SavedPassword::from_json(QJsonObject const& j)
{
    return { j.value(u"id").toString(), j.value(u"origin").toString(), j.value(u"username").toString(),
        j.value(u"password").toString(), qint64(j.value(u"createdAt").toDouble()), qint64(j.value(u"updatedAt").toDouble()) };
}

// ---------------------------------------------------------------------------------------------------------------
// The envelope (crypto.nim: OpenSSL's AES-256-GCM, a 12-byte nonce, the 16-byte tag apart)

QByteArray Vault::encrypt(QByteArray const& key, QJsonObject const& contents)
{
    auto clear = QJsonDocument(contents).toJson(QJsonDocument::Compact);
    auto nonce = random_bytes(12);
    QByteArray cipher(clear.size() + 16, Qt::Uninitialized);
    QByteArray tag(16, '\0');
    auto* ctx = EVP_CIPHER_CTX_new();
    int n = 0, total = 0;
    bool ok = ctx && key.size() == 32
        && EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) == 1
        && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, nullptr) == 1
        && EVP_EncryptInit_ex(ctx, nullptr, nullptr, reinterpret_cast<unsigned char const*>(key.constData()), reinterpret_cast<unsigned char const*>(nonce.constData())) == 1
        && EVP_EncryptUpdate(ctx, nullptr, &n, reinterpret_cast<unsigned char const*>(aad), int(strlen(aad))) == 1
        && (clear.isEmpty() || EVP_EncryptUpdate(ctx, reinterpret_cast<unsigned char*>(cipher.data()), &n, reinterpret_cast<unsigned char const*>(clear.constData()), int(clear.size())) == 1);
    if (ok) {
        total = clear.isEmpty() ? 0 : n;
        ok = EVP_EncryptFinal_ex(ctx, reinterpret_cast<unsigned char*>(cipher.data()) + total, &n) == 1;
        total += n;
        ok = ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag.data()) == 1;
    }
    if (ctx)
        EVP_CIPHER_CTX_free(ctx);
    if (!ok)
        return {};
    cipher.truncate(total);
    QJsonObject envelope { { u"format"_s, u"webby-vault"_s }, { u"version"_s, 1 }, { u"cipher"_s, u"AES-256-GCM"_s },
        { u"nonce"_s, QString::fromLatin1(nonce.toBase64()) }, { u"data"_s, QString::fromLatin1(cipher.toBase64()) },
        { u"mac"_s, QString::fromLatin1(tag.toBase64()) } };
    return QJsonDocument(envelope).toJson(QJsonDocument::Compact);
}

QJsonObject Vault::decrypt(QByteArray const& key, QByteArray const& text, QString& error)
{
    error.clear();
    QJsonParseError parse;
    auto envelope = QJsonDocument::fromJson(text, &parse).object();
    if (parse.error != QJsonParseError::NoError) {
        error = u"The password vault is damaged (%1)."_s.arg(parse.errorString());
        return {};
    }
    if (envelope.value(u"format").toString() != u"webby-vault" || envelope.value(u"version").toInt() != 1) {
        error = u"The password vault was written by a newer webby."_s;
        return {};
    }
    auto nonce = QByteArray::fromBase64(envelope.value(u"nonce").toString().toLatin1());
    auto cipher = QByteArray::fromBase64(envelope.value(u"data").toString().toLatin1());
    auto tag = QByteArray::fromBase64(envelope.value(u"mac").toString().toLatin1());
    if (key.size() != 32 || tag.size() != 16 || nonce.isEmpty()) {
        error = u"The password vault is damaged (bad nonce or tag)."_s;
        return {};
    }
    QByteArray clear(cipher.size() + 16, Qt::Uninitialized);
    auto* ctx = EVP_CIPHER_CTX_new();
    int n = 0, total = 0;
    bool ok = ctx
        && EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) == 1
        && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, int(nonce.size()), nullptr) == 1
        && EVP_DecryptInit_ex(ctx, nullptr, nullptr, reinterpret_cast<unsigned char const*>(key.constData()), reinterpret_cast<unsigned char const*>(nonce.constData())) == 1
        && EVP_DecryptUpdate(ctx, nullptr, &n, reinterpret_cast<unsigned char const*>(aad), int(strlen(aad))) == 1
        && (cipher.isEmpty() || EVP_DecryptUpdate(ctx, reinterpret_cast<unsigned char*>(clear.data()), &n, reinterpret_cast<unsigned char const*>(cipher.constData()), int(cipher.size())) == 1);
    bool authentic = false;
    if (ok) {
        total = cipher.isEmpty() ? 0 : n;
        ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, tag.data()) == 1;
        authentic = ok && EVP_DecryptFinal_ex(ctx, reinterpret_cast<unsigned char*>(clear.data()) + total, &n) == 1;
        total += n;
    }
    if (ctx)
        EVP_CIPHER_CTX_free(ctx);
    if (!ok) {
        error = u"The password vault is damaged (decryption failed)."_s;
        return {};
    }
    if (!authentic) {
        error = u"The password vault doesn't match the key in the keyring."_s;
        return {};
    }
    clear.truncate(total);
    auto doc = QJsonDocument::fromJson(clear, &parse);
    if (parse.error != QJsonParseError::NoError || !doc.isObject()) {
        error = u"The password vault is damaged."_s;
        return {};
    }
    return doc.object();
}

// ---------------------------------------------------------------------------------------------------------------
// Files and opening

QString Vault::file_path()
{
    auto override = qEnvironmentVariable("WEBBY_VAULT_FILE");
    return override.isEmpty() ? Profile::file(u"vault.json"_s) : override;
}

bool Vault::exists() { return QFile::exists(file_path()); }

QString Vault::set_aside()
{
    if (s_vault || !exists())
        return {};
    auto name = file_path() + u".unreadable-"_s + QDateTime::currentDateTime().toString(u"yyyyMMdd'T'HHmmss"_s);
    if (!QFile::rename(file_path(), name))
        return {};
    return name;
}

Vault* Vault::the() { return s_vault.get(); }
QString const& Vault::error() { return s_error; }

struct VaultOpener {
    static void finish(QString const& encoded_key, Vault::KeyStore store, QString const& keyring_error)
    {
        auto file = Vault::file_path();
        auto key = QByteArray::fromBase64(encoded_key.toLatin1());
        if (encoded_key.isEmpty()) {
            if (QFile::exists(file)) {
                // Never replace a vault we can't read with an empty one.
                s_error = keyring_error.isEmpty()
                    ? u"The key for the password vault at %1 is missing from the keyring (or the keyring is locked). Unlock it, or open webby on the desktop once, then try again."_s.arg(file)
                    : u"The password vault at %1 is locked: its key is in the desktop keyring, which this webby could not ask (%2)."_s.arg(file, keyring_error);
                return;
            }
            // A new vault. Its key goes in vault.key: the desktop moves it into the keyring.
            key = random_bytes(32);
            if (!write_private(QFileInfo(file).absolutePath() + u"/vault.key"_s, key.toBase64())) {
                s_error = u"Could not create the password vault's key file."_s;
                return;
            }
            store = Vault::KeyStore::File;
        }
        if (key.size() != 32) {
            s_error = u"The password vault key is damaged."_s;
            return;
        }
        std::unique_ptr<Vault> vault(new Vault);
        vault->m_path = file;
        vault->m_key = key;
        vault->m_key_store = store;
        bool existed = QFile::exists(file);
        QJsonObject contents;
        if (existed) {
            QFile f(file);
            if (!f.open(QIODevice::ReadOnly)) {
                s_error = u"Could not read the password vault at %1."_s.arg(file);
                return;
            }
            contents = Vault::decrypt(key, f.readAll(), s_error);
            if (!s_error.isEmpty())
                return;
        }
        vault->load(contents);
        if (!existed)
            vault->save();
        s_vault = std::move(vault);
        s_error.clear();
    }

    static void done()
    {
        s_opening = false;
        if (!s_vault && !s_error.isEmpty())
            qWarning("webby: %s", qPrintable(s_error));
        auto waiting = std::move(s_waiting);
        s_waiting.clear();
        for (auto& f : waiting)
            f();
    }
};

void Vault::open(std::function<void()> opened)
{
    if (s_vault) {
        if (opened)
            QTimer::singleShot(0, std::move(opened));
        return;
    }
    if (opened)
        s_waiting.push_back(std::move(opened));
    if (s_opening)
        return;
    s_opening = true;
    s_error.clear();
    auto dir = QFileInfo(file_path()).absolutePath();
    QDir().mkpath(dir);
    ::chmod(QFile::encodeName(dir).constData(), 0700);
    auto key_file = dir + u"/vault.key"_s;
    auto from_file = [key_file]() -> QString {
        QFile f(key_file);
        if (!f.open(QIODevice::ReadOnly))
            return {};
        return QString::fromLatin1(f.readAll()).trimmed();
    };
    // No vault yet, or WEBBY_VAULT_KEYRING=0: the keyring is not asked (a new vault's key goes in vault.key).
    if (!exists() || qEnvironmentVariable("WEBBY_VAULT_KEYRING") == u"0") {
        auto key = from_file();
        VaultOpener::finish(key, KeyStore::File, key.isEmpty() && exists() ? u"disabled by WEBBY_VAULT_KEYRING=0"_s : QString {});
        VaultOpener::done();
        return;
    }
    Keyring::lookup(profile_name(), [from_file](Keyring::Lookup found) {
        if (found.found)
            VaultOpener::finish(found.secret, KeyStore::Keyring, {});
        else
            VaultOpener::finish(from_file(), KeyStore::File, found.error);
        VaultOpener::done();
    });
}

// ---------------------------------------------------------------------------------------------------------------
// Contents

void Vault::load(QJsonObject const& contents)
{
    for (auto const& s : deleted_sections)
        m_deleted[s] = {};
    for (auto const& e : contents.value(u"passwords").toArray()) {
        auto o = e.toObject();
        if (o.value(u"id").isString() && o.value(u"origin").isString())
            m_passwords.append(SavedPassword::from_json(o));
    }
    for (auto const& o : contents.value(u"neverSave").toArray()) {
        if (o.isString() && !m_never_save.contains(o.toString()))
            m_never_save.append(o.toString());
    }
    m_never_save.sort();
    for (auto const& p : contents.value(u"passkeys").toArray()) {
        if (p.isObject())
            m_passkeys.append(p);
    }
    auto never_at = contents.value(u"neverSaveAt").toObject();
    for (auto it = never_at.begin(); it != never_at.end(); ++it) {
        if (it->isDouble())
            m_never_save_at[it.key()] = qint64(it->toDouble());
    }
    auto deleted = contents.value(u"deleted").toObject();
    for (auto const& s : deleted_sections) {
        auto section = deleted.value(s).toObject();
        for (auto it = section.begin(); it != section.end(); ++it) {
            if (it->isDouble())
                m_deleted[s][it.key()] = qint64(it->toDouble());
        }
    }
    auto secrets = contents.value(u"secrets").toObject();
    for (auto it = secrets.begin(); it != secrets.end(); ++it) {
        if (it->isString())
            m_secrets[it.key()] = it->toString();
    }
    auto secrets_at = contents.value(u"secretsAt").toObject();
    for (auto it = secrets_at.begin(); it != secrets_at.end(); ++it) {
        if (it->isDouble())
            m_secrets_at[it.key()] = qint64(it->toDouble());
    }
    for (auto const& n : contents.value(u"localSecrets").toArray()) {
        if (n.isString() && !m_local_secrets.contains(n.toString()))
            m_local_secrets.append(n.toString());
    }
    m_local_secrets.sort();
    if (contents.value(u"sync").isObject())
        m_sync_settings = contents.value(u"sync").toObject();
}

QJsonObject Vault::contents() const
{
    QJsonArray passwords;
    for (auto const& p : m_passwords)
        passwords.append(p.to_json());
    QJsonObject never_at;
    for (auto it = m_never_save_at.begin(); it != m_never_save_at.end(); ++it)
        never_at[it.key()] = it.value();
    QJsonObject deleted;
    for (auto const& s : deleted_sections) {
        QJsonObject section;
        auto const& d = m_deleted[s];
        for (auto it = d.begin(); it != d.end(); ++it)
            section[it.key()] = it.value();
        deleted[s] = section;
    }
    QJsonObject result { { u"version"_s, 1 }, { u"passwords"_s, passwords }, { u"neverSave"_s, QJsonArray::fromStringList(m_never_save) },
        { u"neverSaveAt"_s, never_at }, { u"passkeys"_s, m_passkeys }, { u"deleted"_s, deleted } };
    if (!m_sync_settings.isEmpty())
        result[u"sync"_s] = m_sync_settings;
    if (!m_secrets.isEmpty()) {
        QJsonObject secrets, at;
        for (auto it = m_secrets.begin(); it != m_secrets.end(); ++it)
            secrets[it.key()] = it.value();
        result[u"secrets"_s] = secrets;
    }
    if (!m_secrets_at.isEmpty()) {
        QJsonObject at;
        for (auto it = m_secrets_at.begin(); it != m_secrets_at.end(); ++it)
            at[it.key()] = it.value();
        result[u"secretsAt"_s] = at;
    }
    if (!m_local_secrets.isEmpty())
        result[u"localSecrets"_s] = QJsonArray::fromStringList(m_local_secrets);
    return result;
}

void Vault::save() const
{
    auto envelope = encrypt(m_key, contents());
    if (envelope.isEmpty() || !write_private(m_path, envelope))
        qWarning("webby: could not save the password vault");
}

void Vault::on_change(std::function<void()> f) { m_on_change.push_back(std::move(f)); }

void Vault::changed()
{
    save();
    for (auto& f : m_on_change)
        f();
}

// ---------------------------------------------------------------------------------------------------------------
// Passwords

QString Vault::origin_of(QString const& url)
{
    QUrl u(url);
    auto scheme = u.scheme().toLower();
    auto host = u.host().toLower();
    if ((scheme != u"http" && scheme != u"https") || host.isEmpty())
        return {};
    auto result = scheme + u"://"_s + (host.contains(u':') ? u'[' + host + u']' : host);
    int port = u.port();
    if (port >= 0 && !((scheme == u"http" && port == 80) || (scheme == u"https" && port == 443)))
        result += u':' + QString::number(port);
    return result;
}

QString Vault::host_of(QString const& origin)
{
    auto host = QUrl(origin).host();
    return host.isEmpty() ? origin : host;
}

QList<SavedPassword> Vault::passwords_for(QString const& origin) const
{
    QList<SavedPassword> result;
    for (auto const& p : m_passwords) {
        if (p.origin == origin)
            result.append(p);
    }
    std::stable_sort(result.begin(), result.end(), [](auto const& a, auto const& b) { return a.updated_at > b.updated_at; });
    return result;
}

SavedPassword const* Vault::find(QString const& origin, QString const& username) const
{
    for (auto const& p : m_passwords) {
        if (p.origin == origin && p.username == username)
            return &p;
    }
    return nullptr;
}

SavedPassword const* Vault::find_id(QString const& id) const
{
    for (auto const& p : m_passwords) {
        if (p.id == id)
            return &p;
    }
    return nullptr;
}

void Vault::save_password(QString const& origin, QString const& username, QString const& password)
{
    for (auto& p : m_passwords) {
        if (p.origin == origin && p.username == username) {
            p.password = password;
            p.updated_at = now();
            changed();
            return;
        }
    }
    m_passwords.append({ QString::fromLatin1(random_bytes(16).toHex()), origin, username, password, now(), now() });
    changed();
}

void Vault::update_password(QString const& id, QString const& origin, QString const& username, QString const& password)
{
    for (auto& p : m_passwords) {
        if (p.id == id) {
            p.origin = origin;
            p.username = username;
            p.password = password;
            p.updated_at = now();
            changed();
            return;
        }
    }
}

void Vault::delete_password(QString const& id)
{
    m_passwords.removeIf([&](auto const& p) { return p.id == id; });
    m_deleted[u"passwords"_s][id] = now();
    changed();
}

void Vault::set_never_save(QString const& origin, bool never)
{
    if (never == is_never_save(origin))
        return;
    if (never) {
        m_never_save.append(origin);
        m_never_save.sort();
        m_never_save_at[origin] = now();
        m_deleted[u"neverSave"_s].remove(origin);
    } else {
        m_never_save.removeAll(origin);
        m_never_save_at.remove(origin);
        m_deleted[u"neverSave"_s][origin] = now();
    }
    changed();
}

// ---------------------------------------------------------------------------------------------------------------
// Passkeys, secrets, sync settings

void Vault::set_passkeys(QJsonArray const& passkeys)
{
    QStringList kept;
    for (auto const& p : passkeys)
        kept.append(p.toObject().value(u"credentialId").toString());
    for (auto const& old : m_passkeys) {
        auto id = old.toObject().value(u"credentialId");
        if (id.isString() && !kept.contains(id.toString()))
            m_deleted[u"passkeys"_s][id.toString()] = now();
    }
    for (auto const& id : kept)
        m_deleted[u"passkeys"_s].remove(id);
    m_passkeys = passkeys;
    changed();
}

void Vault::set_secret(QString const& name, QString const& value, bool sync)
{
    bool was_syncing = secret_syncs(name);
    if (sync && !was_syncing)
        m_local_secrets.removeAll(name);
    else if (!sync && was_syncing) {
        m_local_secrets.append(name);
        m_local_secrets.sort();
    }
    bool had = m_secrets.contains(name);
    auto old = m_secrets.value(name);
    if (value.isEmpty()) {
        if (!had && sync == was_syncing)
            return;
        m_secrets.remove(name);
        m_secrets_at.remove(name);
        if (had && sync)
            m_deleted[u"secrets"_s][name] = now();
    } else {
        if (had && old == value && sync == was_syncing)
            return;
        if (!had || old != value || sync) {
            // A new value, or one starting to sync: the newest copy wins on the other devices.
            m_secrets[name] = value;
            m_secrets_at[name] = now();
            m_deleted[u"secrets"_s].remove(name);
        }
    }
    changed();
}

void Vault::set_sync_settings(QJsonObject const& settings)
{
    m_sync_settings = settings;
    changed();
}

QJsonObject Vault::to_sync_doc() const
{
    QJsonObject passwords, passkeys, never;
    auto const& dp = m_deleted[u"passwords"_s];
    for (auto it = dp.begin(); it != dp.end(); ++it)
        passwords[it.key()] = tombstone(it.value(), it.key());
    for (auto const& p : m_passwords)
        passwords[p.id] = p.to_json();
    auto const& dk = m_deleted[u"passkeys"_s];
    for (auto it = dk.begin(); it != dk.end(); ++it)
        passkeys[it.key()] = tombstone(it.value());
    for (auto const& v : m_passkeys) {
        auto p = v.toObject();
        if (!p.value(u"credentialId").isString())
            continue;
        p[u"updatedAt"_s] = qint64(p.value(u"createdAt").toDouble());
        passkeys[p.value(u"credentialId").toString()] = p;
    }
    auto const& dn = m_deleted[u"neverSave"_s];
    for (auto it = dn.begin(); it != dn.end(); ++it)
        never[it.key()] = tombstone(it.value());
    for (auto const& o : m_never_save)
        never[o] = QJsonObject { { u"updatedAt"_s, m_never_save_at.value(o) } };
    return { { u"passwords"_s, passwords }, { u"passkeys"_s, passkeys }, { u"neverSave"_s, never } };
}

bool Vault::apply_sync_doc(QJsonObject const& doc)
{
    QStringList before;
    for (auto const& p : m_passkeys)
        before.append(p.toObject().value(u"credentialId").toString());
    m_passwords.clear();
    auto passwords = doc.value(u"passwords").toObject();
    for (auto it = passwords.begin(); it != passwords.end(); ++it) {
        auto r = it->toObject();
        if (!is_deleted(r) && r.value(u"id").isString() && r.value(u"origin").isString())
            m_passwords.append(SavedPassword::from_json(r));
    }
    m_never_save.clear();
    m_never_save_at.clear();
    auto never = doc.value(u"neverSave").toObject();
    for (auto it = never.begin(); it != never.end(); ++it) {
        if (!is_deleted(*it)) {
            m_never_save.append(it.key());
            m_never_save_at[it.key()] = updated_at_of(*it);
        }
    }
    m_never_save.sort();
    m_passkeys = {};
    auto passkeys = doc.value(u"passkeys").toObject();
    for (auto it = passkeys.begin(); it != passkeys.end(); ++it) {
        auto r = it->toObject();
        if (!is_deleted(r) && r.value(u"credentialId").isString()) {
            r.remove(u"updatedAt"_s);
            m_passkeys.append(r);
        }
    }
    for (auto const& s : sections) {
        m_deleted[s] = {};
        auto section = doc.value(s).toObject();
        for (auto it = section.begin(); it != section.end(); ++it) {
            if (is_deleted(*it))
                m_deleted[s][it.key()] = updated_at_of(*it);
        }
    }
    changed();
    QStringList after;
    for (auto const& p : m_passkeys)
        after.append(p.toObject().value(u"credentialId").toString());
    bool passkeys_changed = before.size() != after.size() || std::any_of(after.begin(), after.end(), [&](auto const& id) { return !before.contains(id); });
    if (passkeys_changed) {
        // As passwords/manager.nim's passkeysSynced: the authenticator gets the merged list, without the removed ones.
        for (auto const& id : before) {
            if (!after.contains(id))
                Passkeys::remove(id.toStdString());
        }
        Passkeys::use_vault(QJsonDocument(m_passkeys).toJson(QJsonDocument::Compact).toStdString());
    }
    return passkeys_changed;
}

QJsonObject Vault::secrets_sync_doc() const
{
    QJsonObject secrets;
    auto const& ds = m_deleted[u"secrets"_s];
    for (auto it = ds.begin(); it != ds.end(); ++it) {
        if (!m_local_secrets.contains(it.key()))
            secrets[it.key()] = QJsonObject { { u"updatedAt"_s, it.value() }, { u"deleted"_s, true } };
    }
    for (auto it = m_secrets.begin(); it != m_secrets.end(); ++it) {
        if (!m_local_secrets.contains(it.key()))
            secrets[it.key()] = QJsonObject { { u"value"_s, it.value() }, { u"updatedAt"_s, m_secrets_at.value(it.key()) } };
    }
    return { { u"secrets"_s, secrets } };
}

void Vault::apply_secrets_sync_doc(QJsonObject const& doc)
{
    bool any = false;
    QStringList kept;
    auto secrets = doc.value(u"secrets").toObject();
    auto& deleted = m_deleted[u"secrets"_s];
    for (auto it = secrets.begin(); it != secrets.end(); ++it) {
        auto const& name = it.key();
        if (m_local_secrets.contains(name) || !it->isObject())
            continue;
        auto r = it->toObject();
        auto at = updated_at_of(r);
        if (is_deleted(r)) {
            kept.append(name);
            if (m_secrets.remove(name))
                any = true;
            m_secrets_at.remove(name);
            if (deleted.value(name, -1) != at) {
                deleted[name] = at;
                any = true;
            }
        } else if (r.value(u"value").isString() && !r.value(u"value").toString().isEmpty()) {
            auto value = r.value(u"value").toString();
            if (m_secrets.value(name) != value || m_secrets_at.value(name, -1) != at)
                any = true;
            m_secrets[name] = value;
            m_secrets_at[name] = at;
            deleted.remove(name);
        }
    }
    // Removals too old to remember dropped out of the merged copy.
    QStringList expired;
    for (auto it = deleted.begin(); it != deleted.end(); ++it) {
        if (!kept.contains(it.key()) && !m_local_secrets.contains(it.key()))
            expired.append(it.key());
    }
    for (auto const& name : expired) {
        deleted.remove(name);
        any = true;
    }
    if (any)
        changed();
}

// ---------------------------------------------------------------------------------------------------------------

QString generate_password()
{
    static QString const lower = u"abcdefghijkmnopqrstuvwxyz"_s;
    static QString const upper = u"ABCDEFGHJKLMNPQRSTUVWXYZ"_s;
    static QString const digits = u"23456789"_s;
    static QString const symbols = u"-_.!@#%+="_s;
    static QString const all = lower + upper + digits + symbols;
    // Uniform in 0 ..< n (n <= 256) by rejection.
    auto below = [](int n) {
        int limit = 256 - 256 % n;
        while (true) {
            int b = static_cast<unsigned char>(random_bytes(1)[0]);
            if (b < limit)
                return b % n;
        }
    };
    auto pick = [&](QString const& s) { return s[below(int(s.size()))]; };
    QString result;
    result += pick(lower);
    result += pick(upper);
    result += pick(digits);
    result += pick(symbols);
    for (int i = 4; i < 20; ++i)
        result += pick(all);
    for (int i = int(result.size()) - 1; i > 0; --i)
        std::swap(result[i], result[below(i + 1)]);
    return result;
}

}
