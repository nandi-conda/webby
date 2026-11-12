/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The profile's encrypted store of passwords, passkeys and secrets: the Nim front end's vault
// (nim/src/features/passwords/vault.nim), the same file in the same format, so wasm webby and the desktop share it.
//
// On disk: <profile>/vault.json (or $WEBBY_VAULT_FILE), a JSON envelope {format: "webby-vault", version: 1,
// cipher: "AES-256-GCM", nonce, data, mac} (base64; 12-byte nonce, 16-byte tag, AAD "webby-vault-v1") around the JSON
// contents. The 256-bit key is random. The desktop keeps it in the keyring (Secret Service, {application: webby,
// profile: <profile>}); this module asks the keyring through the host (Keyring.h), else reads <profile>/vault.key,
// where a new vault's key goes too (the desktop moves it into the keyring the next time it opens the vault).
//
// For sync (wasm/ui/Sync.cpp): sync_settings / set_sync_settings (the raw "sync" object of the contents),
// to_sync_doc / apply_sync_doc ({"passwords": {id: record}, "passkeys": {credentialId: record}, "neverSave":
// {origin: record}}, records with "updatedAt" in seconds, deletions as tombstones {"updatedAt", "deleted": true}),
// secrets_sync_doc / apply_secrets_sync_doc ({"secrets": {name: {value, updatedAt}}}), on_change. Every change is
// saved at once.

#pragma once

#include <QByteArray>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QMap>
#include <QString>
#include <QStringList>
#include <functional>
#include <memory>

namespace WebbyUI {

struct SavedPassword {
    QString id;
    QString origin; // scheme://host[:port] of the page it was saved on; only offered there
    QString username;
    QString password;
    qint64 created_at { 0 }; // seconds since the epoch
    qint64 updated_at { 0 };
    QJsonObject to_json() const;
    static SavedPassword from_json(QJsonObject const&);
};

class Vault {
public:
    enum class KeyStore {
        Keyring, // the desktop keyring, the normal case
        File,    // vault.key next to the vault
    };

    // The open vault, or null while it is opening or when it could not be opened (error() says why).
    static Vault* the();
    static QString const& error();
    // Starts opening the profile's vault (once; again after a failure): the keyring lookup goes through the host and
    // takes a moment. `opened` runs when it has, with the().
    static void open(std::function<void()> opened);
    // Keeps an unreadable vault as vault.json.unreadable-<time> so the next open starts an empty one (passwords come
    // back by joining sync); returns the new name or "".
    static QString set_aside();

    static QString file_path();
    static bool exists();
    // The canonical origin of a page URL, or "" for pages that can't have saved passwords (about:, file:, data:...).
    static QString origin_of(QString const& url);
    static QString host_of(QString const& origin);

    KeyStore key_store() const { return m_key_store; }
    void on_change(std::function<void()>);

    // Passwords.
    QList<SavedPassword> const& passwords() const { return m_passwords; }
    // Newest first.
    QList<SavedPassword> passwords_for(QString const& origin) const;
    SavedPassword const* find(QString const& origin, QString const& username) const;
    SavedPassword const* find_id(QString const& id) const;
    // Saves a password, replacing the one for the same site and username.
    void save_password(QString const& origin, QString const& username, QString const& password);
    void update_password(QString const& id, QString const& origin, QString const& username, QString const& password);
    void delete_password(QString const& id);
    QStringList const& never_save() const { return m_never_save; }
    bool is_never_save(QString const& origin) const { return m_never_save.contains(origin); }
    void set_never_save(QString const& origin, bool never);

    // Passkeys: the authenticator's JSON (Passkeys::export_json), as is.
    QJsonArray const& passkeys() const { return m_passkeys; }
    void set_passkeys(QJsonArray const&);

    // Secrets (API keys and such), by name; "" when there is none. A secret syncs unless set with sync false.
    QString secret(QString const& name) const { return m_secrets.value(name); }
    bool secret_syncs(QString const& name) const { return !m_local_secrets.contains(name); }
    void set_secret(QString const& name, QString const& value, bool sync);
    void set_secret(QString const& name, QString const& value) { set_secret(name, value, secret_syncs(name)); }

    // Sync.
    QJsonObject sync_settings() const { return m_sync_settings; }
    void set_sync_settings(QJsonObject const&);
    QJsonObject to_sync_doc() const;
    // Replaces the contents with a merged doc; true if the set of passkeys changed (the authenticator is told here).
    bool apply_sync_doc(QJsonObject const& doc);
    QJsonObject secrets_sync_doc() const;
    void apply_secrets_sync_doc(QJsonObject const& doc);

    // The envelope, for tests and other tools.
    static QByteArray encrypt(QByteArray const& key, QJsonObject const& contents);
    // Empty `error` on success.
    static QJsonObject decrypt(QByteArray const& key, QByteArray const& text, QString& error);

private:
    Vault() = default;
    void load(QJsonObject const&);
    QJsonObject contents() const;
    void save() const;
    void changed();

    QString m_path;
    KeyStore m_key_store { KeyStore::File };
    QByteArray m_key;
    QList<SavedPassword> m_passwords;
    QStringList m_never_save; // sorted
    QMap<QString, qint64> m_never_save_at;
    QJsonArray m_passkeys;
    QMap<QString, QMap<QString, qint64>> m_deleted; // section -> key -> when deleted
    QJsonObject m_sync_settings;                    // empty when sync is off
    QMap<QString, QString> m_secrets;
    QMap<QString, qint64> m_secrets_at;
    QStringList m_local_secrets; // secrets that never sync (sorted)
    std::vector<std::function<void()>> m_on_change;

    friend struct VaultOpener;
};

// Strong passwords: 20 characters from a CSPRNG, no look-alikes (the Nim front end's generator.nim).
QString generate_password();

}
