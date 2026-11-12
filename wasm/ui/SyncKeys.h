/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The sync key, the code devices pair with, and the encryption of what goes to the server: a port of
// nim/src/features/sync/keys.nim, the same algorithms and formats on every device.
//   code: "webby1-" + base32(key ‖ CRC-16/CCITT(key)) in groups of five
//   HKDF-SHA256(key, salt "webby-sync-v1", info) → blob ids (hex), auth token (base64url, unpadded), AES key
//   blob: {"format":"webby-sync","version":1,"nonce","data","mac"} around AES-256-GCM(canonical doc, AAD "webby-sync-v1")
// OpenSSL's libcrypto (the engine's, from the WASI sysroot) does the cryptography.

#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QString>
#include <optional>

namespace WebbyUI::SyncKeys {

struct Keys {
    QString blob_id, bookmarks_blob_id, tabs_blob_id, summaries_blob_id, sessions_blob_id, secrets_blob_id; // 64 hex each
    QString auth_token;        // Bearer token for the webby-sync server, which keeps only its hash
    QByteArray encryption_key; // 32 bytes
};

QByteArray random_bytes(int n);
QByteArray hmac_sha256(QByteArray const& key, QByteArray const& data);
QByteArray hkdf32(QByteArray const& ikm, QByteArray const& salt, QByteArray const& info);

QString code_for(QByteArray const& key);
QString generate_code();
// The 32 key bytes of a code, ignoring case, spaces and dashes and taking 0/1/8 for O/I/B; nothing (and `error`
// says why) when it is mistyped, cut short or not a code.
std::optional<QByteArray> key_from_code(QString const& text, QString* error = nullptr);
// The code in its usual form, or "" (and `error`).
QString normalize_code(QString const& text, QString* error = nullptr);

// The keys of a valid code (an empty Keys for anything else).
Keys derive(QString const& code);

// The encrypted envelope of a doc, as the server stores it.
QByteArray seal(Keys const&, QJsonObject const& doc);
// The doc in an envelope, or nothing (and `error`).
std::optional<QJsonObject> open(Keys const&, QByteArray const& sealed, QString* error);

// AES-256-GCM with a fresh 12-byte nonce and a 16-byte tag (nim passwords/crypto.nim seal/unseal).
struct Sealed {
    QByteArray nonce, cipher_text, mac;
};
std::optional<Sealed> aes_gcm_seal(QByteArray const& key, QByteArray const& clear, QByteArray const& aad);
std::optional<QByteArray> aes_gcm_open(QByteArray const& key, Sealed const&, QByteArray const& aad);

}
