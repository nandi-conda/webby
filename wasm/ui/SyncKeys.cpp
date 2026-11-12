/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "SyncKeys.h"
#include "SyncDoc.h"

#include <QJsonDocument>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <cstring>

using namespace Qt::StringLiterals;

namespace WebbyUI::SyncKeys {

static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
static auto const code_prefix = "webby1"_ba;
static auto const version = "webby-sync-v1"_ba;

QByteArray random_bytes(int n)
{
    QByteArray out(n, '\0');
    if (n > 0 && RAND_bytes(reinterpret_cast<unsigned char*>(out.data()), n) != 1)
        qFatal("webby: RAND_bytes failed");
    return out;
}

QByteArray hmac_sha256(QByteArray const& key, QByteArray const& data)
{
    QByteArray out(32, '\0');
    unsigned int n = 0;
    if (!HMAC(EVP_sha256(), key.constData(), int(key.size()), reinterpret_cast<unsigned char const*>(data.constData()),
            size_t(data.size()), reinterpret_cast<unsigned char*>(out.data()), &n)
        || n != 32)
        qFatal("webby: HMAC failed");
    return out;
}

QByteArray hkdf32(QByteArray const& ikm, QByteArray const& salt, QByteArray const& info)
{
    // RFC 5869 HKDF-SHA256 with 32 bytes out (one block).
    return hmac_sha256(hmac_sha256(salt, ikm), info + '\x01');
}

// ---------------------------------------------------------------------------------------------------------------
// Codes

static QByteArray base32_encode(QByteArray const& bytes)
{
    QByteArray out;
    int buffer = 0, bits = 0;
    for (char c : bytes) {
        buffer = (buffer << 8) | (unsigned char)c;
        bits += 8;
        while (bits >= 5) {
            out += alphabet[(buffer >> (bits - 5)) & 31];
            bits -= 5;
        }
        buffer &= (1 << bits) - 1;
    }
    if (bits > 0)
        out += alphabet[(buffer << (5 - bits)) & 31];
    return out;
}

static std::optional<QByteArray> base32_decode(QByteArray const& text)
{
    QByteArray out;
    int buffer = 0, bits = 0;
    for (char c : text) {
        auto const* p = strchr(alphabet, c);
        if (!p || !c)
            return {};
        buffer = (buffer << 5) | int(p - alphabet);
        bits += 5;
        if (bits >= 8) {
            out += char((buffer >> (bits - 8)) & 0xFF);
            bits -= 8;
        }
        buffer &= (1 << bits) - 1;
    }
    return out;
}

static QByteArray check(QByteArray const& key)
{
    // CRC-16/CCITT: plenty for catching typos.
    int crc = 0xFFFF;
    for (char c : key) {
        crc ^= (unsigned char)c << 8;
        for (int i = 0; i < 8; ++i)
            crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
    QByteArray out;
    out += char(crc >> 8);
    out += char(crc & 0xFF);
    return out;
}

QString code_for(QByteArray const& key)
{
    auto text = base32_encode(key + check(key));
    QByteArray out = code_prefix;
    for (qsizetype i = 0; i < text.size(); i += 5)
        out += '-' + text.mid(i, 5);
    return QString::fromLatin1(out);
}

QString generate_code() { return code_for(random_bytes(32)); }

std::optional<QByteArray> key_from_code(QString const& text, QString* error)
{
    auto fail = [&](QString const& why) -> std::optional<QByteArray> {
        if (error)
            *error = why;
        return {};
    };
    QByteArray cleaned;
    for (auto c : text.toUpper().toUtf8()) {
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r' && c != '\v' && c != '\f' && c != '-')
            cleaned += c;
    }
    if (cleaned.startsWith(code_prefix.toUpper()))
        cleaned = cleaned.mid(code_prefix.size());
    cleaned.replace('0', 'O').replace('1', 'I').replace('8', 'B');
    if (cleaned.size() != 55)
        return fail(u"That sync code is the wrong length."_s);
    auto bytes = base32_decode(cleaned);
    if (!bytes || bytes->size() < 34)
        return fail(u"That isn't a sync code."_s);
    auto key = bytes->left(32);
    if (bytes->mid(32, 2) != check(key))
        return fail(u"That sync code has a typo in it."_s);
    return key;
}

QString normalize_code(QString const& text, QString* error)
{
    auto key = key_from_code(text, error);
    return key ? code_for(*key) : QString();
}

// ---------------------------------------------------------------------------------------------------------------
// Keys and blobs

Keys derive(QString const& code)
{
    auto key = key_from_code(code);
    if (!key)
        return {};
    auto part = [&](char const* info) { return hkdf32(*key, version, QByteArray(info)); };
    auto hex = [&](char const* info) { return QString::fromLatin1(part(info).toHex()); };
    Keys k;
    k.blob_id = hex("id");
    k.bookmarks_blob_id = hex("id-bookmarks");
    k.tabs_blob_id = hex("id-tabs");
    k.summaries_blob_id = hex("id-summaries");
    k.sessions_blob_id = hex("id-sessions");
    k.secrets_blob_id = hex("id-secrets");
    k.auth_token = QString::fromLatin1(part("auth").toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
    k.encryption_key = part("enc");
    return k;
}

std::optional<Sealed> aes_gcm_seal(QByteArray const& key, QByteArray const& clear, QByteArray const& aad)
{
    if (key.size() != 32)
        return {};
    Sealed box;
    box.nonce = random_bytes(12);
    auto* ctx = EVP_CIPHER_CTX_new();
    if (!ctx)
        return {};
    auto const* k = reinterpret_cast<unsigned char const*>(key.constData());
    auto const* iv = reinterpret_cast<unsigned char const*>(box.nonce.constData());
    int n = 0;
    bool ok = EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) == 1
        && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, nullptr) == 1
        && EVP_EncryptInit_ex(ctx, nullptr, nullptr, k, iv) == 1
        && (aad.isEmpty() || EVP_EncryptUpdate(ctx, nullptr, &n, reinterpret_cast<unsigned char const*>(aad.constData()), int(aad.size())) == 1);
    QByteArray out(clear.size() + 16, '\0');
    int total = 0;
    if (ok && !clear.isEmpty()) {
        ok = EVP_EncryptUpdate(ctx, reinterpret_cast<unsigned char*>(out.data()), &n, reinterpret_cast<unsigned char const*>(clear.constData()), int(clear.size())) == 1;
        total = n;
    }
    if (ok) {
        ok = EVP_EncryptFinal_ex(ctx, reinterpret_cast<unsigned char*>(out.data()) + total, &n) == 1;
        total += n;
    }
    box.mac = QByteArray(16, '\0');
    if (ok)
        ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, box.mac.data()) == 1;
    EVP_CIPHER_CTX_free(ctx);
    if (!ok)
        return {};
    out.truncate(total);
    box.cipher_text = out;
    return box;
}

std::optional<QByteArray> aes_gcm_open(QByteArray const& key, Sealed const& box, QByteArray const& aad)
{
    if (key.size() != 32 || box.mac.size() != 16 || box.nonce.isEmpty())
        return {};
    auto* ctx = EVP_CIPHER_CTX_new();
    if (!ctx)
        return {};
    auto const* k = reinterpret_cast<unsigned char const*>(key.constData());
    auto const* iv = reinterpret_cast<unsigned char const*>(box.nonce.constData());
    int n = 0;
    bool ok = EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) == 1
        && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, int(box.nonce.size()), nullptr) == 1
        && EVP_DecryptInit_ex(ctx, nullptr, nullptr, k, iv) == 1
        && (aad.isEmpty() || EVP_DecryptUpdate(ctx, nullptr, &n, reinterpret_cast<unsigned char const*>(aad.constData()), int(aad.size())) == 1);
    QByteArray out(box.cipher_text.size() + 16, '\0');
    int total = 0;
    if (ok && !box.cipher_text.isEmpty()) {
        ok = EVP_DecryptUpdate(ctx, reinterpret_cast<unsigned char*>(out.data()), &n, reinterpret_cast<unsigned char const*>(box.cipher_text.constData()), int(box.cipher_text.size())) == 1;
        total = n;
    }
    QByteArray tag = box.mac;
    if (ok)
        ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, tag.data()) == 1;
    if (ok) {
        ok = EVP_DecryptFinal_ex(ctx, reinterpret_cast<unsigned char*>(out.data()) + total, &n) == 1;
        total += n;
    }
    EVP_CIPHER_CTX_free(ctx);
    if (!ok)
        return {};
    out.truncate(total);
    return out;
}

QByteArray seal(Keys const& keys, QJsonObject const& doc)
{
    auto box = aes_gcm_seal(keys.encryption_key, SyncDoc::canonical(doc), version);
    if (!box)
        return {};
    // dartJson keeps the envelope's key order.
    return "{\"format\":\"webby-sync\",\"version\":1,\"nonce\":\"" + box->nonce.toBase64() + "\",\"data\":\""
        + box->cipher_text.toBase64() + "\",\"mac\":\"" + box->mac.toBase64() + "\"}";
}

std::optional<QJsonObject> open(Keys const& keys, QByteArray const& sealed, QString* error)
{
    auto fail = [&](QString const& why) -> std::optional<QJsonObject> {
        if (error)
            *error = why;
        return {};
    };
    QJsonParseError parse_error;
    auto envelope_doc = QJsonDocument::fromJson(sealed, &parse_error);
    if (parse_error.error != QJsonParseError::NoError || !envelope_doc.isObject())
        return envelope_doc.isNull() ? fail(u"The synced data on the server is damaged."_s) : fail(u"The server has something else stored."_s);
    auto envelope = envelope_doc.object();
    if (envelope.value(u"format").toString() != u"webby-sync")
        return fail(u"The server has something else stored."_s);
    auto v = envelope.value(u"version");
    if (!v.isDouble() || v.toDouble() != 1)
        return fail(u"Another device synced with a newer webby. Update webby here to keep syncing."_s);
    Sealed box;
    auto decode = [](QJsonValue const& s, QByteArray& out) {
        auto r = QByteArray::fromBase64Encoding(s.toString().toLatin1(), QByteArray::AbortOnBase64DecodingErrors);
        if (!r)
            return false;
        out = *r;
        return true;
    };
    if (!decode(envelope.value(u"nonce"), box.nonce) || !decode(envelope.value(u"data"), box.cipher_text) || !decode(envelope.value(u"mac"), box.mac))
        return fail(u"The synced data on the server is damaged (bad base64)."_s);
    auto clear = aes_gcm_open(keys.encryption_key, box, version);
    if (!clear)
        return fail(u"The synced data doesn't match this sync code."_s);
    auto doc = QJsonDocument::fromJson(*clear, &parse_error);
    if (parse_error.error != QJsonParseError::NoError)
        return fail(u"The synced data on the server is damaged ("_s + parse_error.errorString() + u")."_s);
    return SyncDoc::from_json(doc.object());
}

}
