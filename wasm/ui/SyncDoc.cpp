/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "SyncDoc.h"

#include <QCborValue>
#include <QHash>
#include <QJsonArray>
#include <QList>
#include <QMap>
#include <QSet>
#include <algorithm>
#include <cmath>

using namespace Qt::StringLiterals;

namespace WebbyUI::SyncDoc {

QStringList const& section_names()
{
    static QStringList const names { u"passwords"_s, u"passkeys"_s, u"neverSave"_s, u"bookmarks"_s, u"devices"_s,
        u"summaries"_s, u"sessions"_s, u"secrets"_s };
    return names;
}

static QStringList const bookmark_roots { u"bar"_s, u"other"_s };

// ---------------------------------------------------------------------------------------------------------------
// Dart's jsonEncode

QString dart_double(double x)
{
    if (std::isnan(x))
        return u"NaN"_s;
    if (std::isinf(x))
        return x > 0 ? u"Infinity"_s : u"-Infinity"_s;
    if (x == 0)
        return std::signbit(x) ? u"-0.0"_s : u"0.0"_s;
    bool negative = x < 0;
    double a = std::fabs(x);
    // The shortest digits that read back as `a`, and their exponent.
    auto sci = QString::number(a, 'e', QLocale::FloatingPointShortest);
    auto e = sci.indexOf(u'e');
    auto digits = sci.left(e).remove(u'.');
    int exp10 = sci.mid(e + 1).toInt();
    while (digits.size() > 1 && digits.endsWith(u'0'))
        digits.chop(1);
    int k = int(digits.size());
    int n = exp10 + 1;
    QString result;
    if (k <= n && n <= 21)
        result = digits + QString(n - k, u'0') + u".0"_s;
    else if (0 < n && n <= 21)
        result = digits.left(n) + u'.' + digits.mid(n);
    else if (-6 < n && n <= 0)
        result = u"0."_s + QString(-n, u'0') + digits;
    else {
        int ex = n - 1;
        result = digits.left(1) + (k > 1 ? u"."_s + digits.mid(1) : QString()) + u'e' + (ex >= 0 ? u'+' : u'-') + QString::number(std::abs(ex));
    }
    return negative ? u'-' + result : result;
}

static qsizetype utf8_length(QByteArray const& s, qsizetype i)
{
    auto b0 = uint8_t(s[i]);
    if (b0 < 0x80)
        return 1;
    qsizetype n = 0;
    uint8_t lo = 0x80, hi = 0xBF;
    if (b0 >= 0xC2 && b0 <= 0xDF)
        n = 2;
    else if (b0 == 0xE0)
        n = 3, lo = 0xA0;
    else if (b0 == 0xED)
        n = 3, hi = 0x9F;
    else if (b0 >= 0xE1 && b0 <= 0xEF)
        n = 3;
    else if (b0 == 0xF0)
        n = 4, lo = 0x90;
    else if (b0 == 0xF4)
        n = 4, hi = 0x8F;
    else if (b0 >= 0xF1 && b0 <= 0xF3)
        n = 4;
    else
        return 0;
    if (i + n > s.size())
        return 0;
    auto b1 = uint8_t(s[i + 1]);
    if (b1 < lo || b1 > hi)
        return 0;
    for (qsizetype k = 2; k < n; ++k) {
        if ((uint8_t(s[i + k]) & 0xC0) != 0x80)
            return 0;
    }
    return n;
}

QByteArray well_formed_utf8(QByteArray const& bytes)
{
    qsizetype i = 0;
    while (i < bytes.size()) {
        auto n = utf8_length(bytes, i);
        if (n == 0)
            break;
        i += n;
    }
    if (i == bytes.size())
        return bytes;
    QByteArray out = bytes.left(i);
    while (i < bytes.size()) {
        auto n = utf8_length(bytes, i);
        if (n == 0) {
            out += "\xEF\xBF\xBD";
            ++i;
        } else {
            out += bytes.mid(i, n);
            i += n;
        }
    }
    return out;
}

static void encode_string(QString const& s, QString& out)
{
    out += u'"';
    for (QChar c : s) {
        switch (c.unicode()) {
        case '"': out += u"\\\""_s; break;
        case '\\': out += u"\\\\"_s; break;
        case '\b': out += u"\\b"_s; break;
        case '\t': out += u"\\t"_s; break;
        case '\n': out += u"\\n"_s; break;
        case '\f': out += u"\\f"_s; break;
        case '\r': out += u"\\r"_s; break;
        default:
            if (c.unicode() < 0x20)
                out += u"\\u00"_s + QString::number(c.unicode(), 16).rightJustified(2, u'0');
            else
                out += c;
        }
    }
    out += u'"';
}

static void encode(QJsonValue const& v, QString& out, bool is_double = false)
{
    switch (v.type()) {
    case QJsonValue::Null:
    case QJsonValue::Undefined:
        out += u"null"_s;
        return;
    case QJsonValue::Bool:
        out += v.toBool() ? u"true"_s : u"false"_s;
        return;
    case QJsonValue::Double: {
        // Dart prints a double 5.0 as "5.0" and an int as "5". Qt's JSON keeps no such difference (it holds 5.0 as
        // the integer 5, parsed or made), so the one double field the docs have, a bookmark's "pos", says it.
        auto cbor = QCborValue::fromJsonValue(v);
        if (cbor.isInteger() && !is_double)
            out += QString::number(cbor.toInteger());
        else
            out += dart_double(v.toDouble());
        return;
    }
    case QJsonValue::String:
        encode_string(v.toString(), out);
        return;
    case QJsonValue::Array: {
        out += u'[';
        bool first = true;
        for (auto const& e : v.toArray()) {
            if (!first)
                out += u',';
            first = false;
            encode(e, out);
        }
        out += u']';
        return;
    }
    case QJsonValue::Object: {
        auto o = v.toObject();
        auto keys = o.keys();
        // QString's order is by UTF-16 code units, as Dart's String.compareTo.
        std::sort(keys.begin(), keys.end());
        out += u'{';
        bool first = true;
        for (auto const& k : keys) {
            if (!first)
                out += u',';
            first = false;
            encode_string(k, out);
            out += u':';
            encode(o.value(k), out, k == u"pos");
        }
        out += u'}';
        return;
    }
    }
}

QByteArray canonical_value(QJsonValue const& v)
{
    QString out;
    encode(v, out);
    return out.toUtf8();
}

// ---------------------------------------------------------------------------------------------------------------
// Docs

QJsonObject new_doc()
{
    QJsonObject doc;
    for (auto const& s : section_names())
        doc.insert(s, QJsonObject {});
    return doc;
}

QJsonObject section(QJsonObject const& doc, QString const& name)
{
    auto v = doc.value(name);
    return v.isObject() ? v.toObject() : QJsonObject {};
}

QJsonObject from_json(QJsonValue const& j)
{
    auto doc = new_doc();
    if (!j.isObject())
        return doc;
    auto o = j.toObject();
    for (auto const& s : section_names()) {
        auto v = o.value(s);
        if (!v.isObject())
            continue;
        QJsonObject records;
        auto in = v.toObject();
        for (auto it = in.begin(); it != in.end(); ++it) {
            if (it.value().isObject())
                records.insert(it.key(), it.value());
        }
        doc.insert(s, records);
    }
    return doc;
}

QJsonObject doc_with(QString const& name, QJsonObject const& records)
{
    auto doc = new_doc();
    QJsonObject kept;
    for (auto it = records.begin(); it != records.end(); ++it) {
        if (it.value().isObject())
            kept.insert(it.key(), it.value());
    }
    doc.insert(name, kept);
    return doc;
}

QJsonObject to_json(QJsonObject const& doc)
{
    QJsonObject j { { u"version"_s, 1 } };
    for (auto const& s : section_names()) {
        auto sec = section(doc, s);
        if (s == u"passwords" || s == u"passkeys" || s == u"neverSave" || !sec.isEmpty())
            j.insert(s, sec);
    }
    return j;
}

QByteArray canonical(QJsonObject const& doc) { return canonical_value(to_json(doc)); }

bool same(QJsonObject const& a, QJsonObject const& b) { return canonical(a) == canonical(b); }

qint64 updated_at(QJsonObject const& r)
{
    auto v = r.value(u"updatedAt");
    if (!v.isDouble())
        return 0;
    auto cbor = QCborValue::fromJsonValue(v);
    return cbor.isInteger() ? cbor.toInteger() : qint64(v.toDouble());
}

bool is_deleted(QJsonObject const& r)
{
    auto v = r.value(u"deleted");
    return v.isBool() && v.toBool();
}

bool wins(QJsonObject const& a, QJsonObject const& b)
{
    auto ta = updated_at(a);
    auto tb = updated_at(b);
    if (ta != tb)
        return ta > tb;
    if (is_deleted(a) != is_deleted(b))
        return is_deleted(a);
    return QString::fromUtf8(canonical_value(a)) >= QString::fromUtf8(canonical_value(b));
}

using Records = QMap<QString, QJsonObject>; // by key, in UTF-16 order

static Records merge_section(QJsonObject const& a, QJsonObject const& b, qint64 expire_before)
{
    Records out;
    QSet<QString> keys;
    for (auto const& k : a.keys())
        keys.insert(k);
    for (auto const& k : b.keys())
        keys.insert(k);
    for (auto const& k : keys) {
        bool in_a = a.value(k).isObject();
        bool in_b = b.value(k).isObject();
        if (!in_a && !in_b)
            continue;
        QJsonObject winner;
        if (!in_a)
            winner = b.value(k).toObject();
        else if (!in_b)
            winner = a.value(k).toObject();
        else {
            auto x = a.value(k).toObject();
            auto y = b.value(k).toObject();
            winner = wins(x, y) ? x : y;
        }
        if (is_deleted(winner) && updated_at(winner) < expire_before)
            continue;
        out.insert(k, winner);
    }
    return out;
}

static QJsonObject to_object(Records const& records)
{
    QJsonObject o;
    for (auto it = records.begin(); it != records.end(); ++it)
        o.insert(it.key(), it.value());
    return o;
}

static void trim_summaries(Records& records)
{
    QStringList live;
    for (auto it = records.begin(); it != records.end(); ++it) {
        if (!is_deleted(it.value()))
            live.append(it.key());
    }
    std::sort(live.begin(), live.end(), [&](QString const& a, QString const& b) {
        auto ta = updated_at(records[a]);
        auto tb = updated_at(records[b]);
        if (ta != tb)
            return ta > tb;
        return a < b;
    });
    for (int i = summary_limit; i < live.size(); ++i)
        records.remove(live[i]);
}

static bool is_folder(QJsonObject const& r)
{
    auto v = r.value(u"folder");
    return v.isBool() && v.toBool();
}

static QString resolve_parent(Records const& records, QJsonValue start)
{
    auto parent = start;
    QSet<QString> seen;
    while (parent.isString() && !bookmark_roots.contains(parent.toString()) && !seen.contains(parent.toString())) {
        auto p = parent.toString();
        seen.insert(p);
        if (!records.contains(p))
            return u"other"_s;
        auto const& r = records[p];
        if (!is_deleted(r))
            return is_folder(r) ? p : u"other"_s;
        parent = r.value(u"mergedInto");
    }
    if (parent.isString() && bookmark_roots.contains(parent.toString()))
        return parent.toString();
    return u"other"_s;
}

static void set_parent(Records& records, QString const& id, QString const& parent)
{
    auto r = records[id];
    r.insert(u"parent"_s, parent);
    records[id] = r;
}

// _repairBookmarks: re-homes orphans in Other bookmarks, cuts folder loops and collapses duplicates.
static void repair_bookmarks(Records& records)
{
    auto ids = records.keys(); // sorted by UTF-16 code units
    bool changed = true;
    while (changed) {
        changed = false;
        for (auto const& id : ids) {
            auto const& r = records[id];
            if (is_deleted(r))
                continue;
            auto parent = resolve_parent(records, r.value(u"parent"));
            auto cur = r.value(u"parent");
            if (!cur.isString() || cur.toString() != parent)
                set_parent(records, id, parent);
        }
        for (auto const& id : ids) {
            if (is_deleted(records[id]))
                continue;
            QSet<QString> seen;
            QString at = id;
            while (!bookmark_roots.contains(at)) {
                if (seen.contains(at)) {
                    set_parent(records, at, u"other"_s);
                    break;
                }
                seen.insert(at);
                at = records[at].value(u"parent").toString();
            }
        }
        for (bool folders : { true, false }) {
            auto key = folders ? u"title"_s : u"url"_s;
            QList<QByteArray> order;
            QHash<QByteArray, QStringList> groups;
            for (auto const& id : ids) {
                auto const& r = records[id];
                if (is_deleted(r) || is_folder(r) != folders)
                    continue;
                auto value = r.value(key);
                auto g = canonical_value(QJsonArray { r.value(u"parent"), value.isUndefined() ? QJsonValue() : value });
                if (!groups.contains(g))
                    order.append(g);
                groups[g].append(id);
            }
            for (auto const& g : order) {
                auto const& group = groups[g];
                if (group.size() < 2)
                    continue;
                auto keep = group[0];
                for (int i = 1; i < group.size(); ++i) {
                    if (!wins(records[keep], records[group[i]]))
                        keep = group[i];
                }
                for (auto const& id : group) {
                    if (id == keep)
                        continue;
                    QJsonObject tomb { { u"updatedAt"_s, updated_at(records[id]) }, { u"deleted"_s, true } };
                    if (folders)
                        tomb.insert(u"mergedInto"_s, keep);
                    records[id] = tomb;
                }
                if (folders)
                    changed = true;
            }
            if (changed)
                break;
        }
    }
}

QJsonObject merge(QJsonObject const& a, QJsonObject const& b, qint64 now)
{
    auto expire_before = now - tombstone_lifetime;
    auto result = new_doc();

    auto passwords = merge_section(section(a, u"passwords"_s), section(b, u"passwords"_s), expire_before);
    // The same site and username saved on two devices: keep the newest, delete the rest.
    QList<QByteArray> order;
    QHash<QByteArray, QStringList> by_account;
    for (auto it = passwords.begin(); it != passwords.end(); ++it) {
        if (is_deleted(it.value()))
            continue;
        auto origin = it.value().value(u"origin");
        auto username = it.value().value(u"username");
        auto account = canonical_value(QJsonArray { origin.isUndefined() ? QJsonValue() : origin, username.isUndefined() ? QJsonValue() : username });
        if (!by_account.contains(account))
            order.append(account);
        by_account[account].append(it.key());
    }
    for (auto const& account : order) {
        auto const& ids = by_account[account];
        if (ids.size() < 2)
            continue;
        auto keep = ids[0];
        for (int i = 1; i < ids.size(); ++i) {
            if (!wins(passwords[keep], passwords[ids[i]]))
                keep = ids[i];
        }
        for (auto const& id : ids) {
            if (id != keep)
                passwords[id] = QJsonObject { { u"id"_s, id }, { u"updatedAt"_s, updated_at(passwords[id]) }, { u"deleted"_s, true } };
        }
    }
    result.insert(u"passwords"_s, to_object(passwords));
    result.insert(u"passkeys"_s, to_object(merge_section(section(a, u"passkeys"_s), section(b, u"passkeys"_s), expire_before)));
    result.insert(u"neverSave"_s, to_object(merge_section(section(a, u"neverSave"_s), section(b, u"neverSave"_s), expire_before)));

    auto bookmarks = merge_section(section(a, u"bookmarks"_s), section(b, u"bookmarks"_s), expire_before);
    repair_bookmarks(bookmarks);
    result.insert(u"bookmarks"_s, to_object(bookmarks));

    auto devices = merge_section(section(a, u"devices"_s), section(b, u"devices"_s), expire_before);
    for (auto it = devices.begin(); it != devices.end();) {
        if (!is_deleted(it.value()) && updated_at(it.value()) < now - device_lifetime)
            it = devices.erase(it);
        else
            ++it;
    }
    result.insert(u"devices"_s, to_object(devices));

    auto summaries = merge_section(section(a, u"summaries"_s), section(b, u"summaries"_s), expire_before);
    trim_summaries(summaries);
    result.insert(u"summaries"_s, to_object(summaries));
    result.insert(u"sessions"_s, to_object(merge_section(section(a, u"sessions"_s), section(b, u"sessions"_s), expire_before)));
    result.insert(u"secrets"_s, to_object(merge_section(section(a, u"secrets"_s), section(b, u"secrets"_s), expire_before)));
    return result;
}

}
