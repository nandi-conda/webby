/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Sync.h"
#include "HttpClient.h"
#include "Profile.h"
#include "Sessions.h"
#include "Summarize.h"
#include "SyncDoc.h"
#include "SyncKeys.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMap>
#include <QSysInfo>
#include <QTimer>
#include <QUrl>
#include <algorithm>
#include <memory>
#include <optional>

using namespace Qt::StringLiterals;

namespace WebbyUI::Sync {

static std::string to_std(QString const& s) { return s.toStdString(); }
static QString from_std(std::string const& s) { return QString::fromStdString(s); }

QString const& default_server()
{
    static QString const url = u"https://webby-sync.nandithebull.workers.dev"_s;
    return url;
}

// Earlier defaults, still saved in older settings and pairing links; they mean the default server now.
static bool is_retired_server(QString const& s) { return s == u"https://webby-sync.fly.dev" || s == u"https://webby-sync.fly.dev/"; }

// ---------------------------------------------------------------------------------------------------------------
// Settings

QString generate_code() { return SyncKeys::generate_code(); }

QJsonObject new_settings(QString const& code, bool webdav, QString const& server, QString const& username, QString const& password)
{
    QJsonObject s { { u"code"_s, code }, { u"backend"_s, webdav ? u"webdav"_s : u"webby-sync"_s }, { u"server"_s, server } };
    if (!username.isEmpty())
        s.insert(u"username"_s, username);
    if (!password.isEmpty())
        s.insert(u"password"_s, password);
    return s;
}

QString code_of(QJsonObject const& s) { return s.value(u"code").toString(); }
bool is_webdav(QJsonObject const& s) { return s.value(u"backend").toString() == u"webdav"; }

QString server_of(QJsonObject const& s)
{
    auto v = s.value(u"server");
    if (!v.isString() || is_retired_server(v.toString()))
        return default_server();
    return v.toString();
}

// Nim's encodeQuery/decodeQuery (encodeUrl with spaces as '+').
static QString encode_component(QString const& s)
{
    QString out;
    for (char c : s.toUtf8()) {
        auto u = (unsigned char)c;
        if ((u >= 'a' && u <= 'z') || (u >= 'A' && u <= 'Z') || (u >= '0' && u <= '9') || u == '-' || u == '.' || u == '_' || u == '~')
            out += QChar(u);
        else if (u == ' ')
            out += u'+';
        else
            out += u'%' + QString::number(u, 16).toUpper().rightJustified(2, u'0');
    }
    return out;
}

static QString decode_component(QString const& s)
{
    auto bytes = s.toUtf8().replace('+', ' ');
    return QString::fromUtf8(QByteArray::fromPercentEncoding(bytes));
}

QString pairing_link(QJsonObject const& s)
{
    QString link = u"webby-sync:pair?code="_s + encode_component(code_of(s));
    if (is_webdav(s))
        link += u"&webdav="_s + encode_component(server_of(s));
    else if (server_of(s) != default_server())
        link += u"&server="_s + encode_component(server_of(s));
    return link;
}

QJsonObject from_pairing(QString const& text, QString* error)
{
    auto t = text.trimmed();
    if (t.startsWith(u"webby-sync:")) {
        QString code, webdav, server;
        bool has_webdav = false;
        auto q = t.indexOf(u'?');
        if (q >= 0) {
            for (auto const& pair : t.mid(q + 1).split(u'&', Qt::SkipEmptyParts)) {
                auto eq = pair.indexOf(u'=');
                auto k = decode_component(eq < 0 ? pair : pair.left(eq));
                auto v = eq < 0 ? QString() : decode_component(pair.mid(eq + 1));
                if (k == u"code")
                    code = v;
                else if (k == u"webdav") {
                    webdav = v;
                    has_webdav = true;
                } else if (k == u"server")
                    server = v;
            }
        }
        if (!SyncKeys::key_from_code(code, error))
            return {};
        if (has_webdav)
            return new_settings(code, true, webdav);
        return new_settings(code, false, !server.isEmpty() && !is_retired_server(server) ? server : default_server());
    }
    auto code = SyncKeys::normalize_code(t, error);
    if (code.isEmpty())
        return {};
    return new_settings(code);
}

// The settings' home: the vault's (set_settings_store), else sync.json.
static std::function<QJsonObject()> s_get_settings;
static std::function<void(QJsonObject const&)> s_set_settings;

static QString settings_file() { return Profile::file(u"sync.json"_s); }

static QJsonObject stored_settings()
{
    if (s_get_settings)
        return s_get_settings();
    return Profile::read_json(settings_file()).value(u"settings").toObject();
}

static void store_settings(QJsonObject const& s)
{
    if (s_set_settings) {
        s_set_settings(s);
        return;
    }
    if (s.isEmpty()) {
        QFile::remove(settings_file());
        return;
    }
    // The code unlocks the passwords: readable by this user only.
    Profile::write_atomic(settings_file(), QJsonDocument(QJsonObject { { u"settings"_s, s } }).toJson(QJsonDocument::Indented));
    QFile::setPermissions(settings_file(), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
}

QJsonObject settings()
{
    auto s = stored_settings();
    return code_of(s).isEmpty() ? QJsonObject {} : s;
}

static QList<std::function<void()>> s_status_listeners;
static bool s_running = false;
static bool s_again = false;

bool enabled() { return !settings().isEmpty(); }
bool syncing() { return s_running; }
QString last_error() { return settings().value(u"lastError").toString(); }
qint64 last_sync() { return settings().value(u"lastSync").toInteger(); }

QString where()
{
    auto s = settings();
    if (is_webdav(s))
        return u"WebDAV folder "_s + server_of(s);
    return server_of(s) == default_server() ? u"the webby sync server"_s : server_of(s);
}

void on_status(std::function<void()> listener) { s_status_listeners.append(std::move(listener)); }

static void notify_status()
{
    for (auto const& h : s_status_listeners)
        h();
}

static void update_settings(std::function<void(QJsonObject&)> const& change)
{
    auto s = settings();
    if (s.isEmpty())
        return;
    change(s);
    store_settings(s);
}

// ---------------------------------------------------------------------------------------------------------------
// Blobs: one per kind behind GET/PUT with ETags, on the webby-sync server (sync-worker/) or in a WebDAV folder.

struct BlobStore {
    QString url;
    QString auth;
    bool webdav { false };
};

static BlobStore store_for(QJsonObject const& s, SyncKeys::Keys const& k, Blob blob)
{
    auto base = server_of(s);
    if (base.endsWith(u'/'))
        base.chop(1);
    QString id;
    switch (blob) {
    case Blob::Vault: id = k.blob_id; break;
    case Blob::Bookmarks: id = k.bookmarks_blob_id; break;
    case Blob::Tabs: id = k.tabs_blob_id; break;
    case Blob::Summaries: id = k.summaries_blob_id; break;
    case Blob::Sessions: id = k.sessions_blob_id; break;
    case Blob::Secrets: id = k.secrets_blob_id; break;
    }
    if (is_webdav(s)) {
        auto login = (s.value(u"username").toString() + u':' + s.value(u"password").toString()).toUtf8().toBase64();
        return { base + u"/webby-sync-"_s + id.left(32) + u".json"_s, u"Basic "_s + QString::fromLatin1(login), true };
    }
    return { base + u"/v1/blobs/"_s + id, u"Bearer "_s + k.auth_token, false };
}

static QString failure(BlobStore const& b, Http::Response const& r)
{
    if (r.status == 0)
        return from_std(r.error);
    switch (r.status) {
    case 401:
    case 403:
        return b.webdav ? u"The WebDAV server didn't accept the username and password."_s : u"The sync server refused this device's key."_s;
    case 404:
    case 405:
    case 409:
        return u"There's no sync folder at "_s + b.url + u'.';
    case 413:
        return u"The vault is too big for the sync server."_s;
    case 507:
        return u"The sync server is out of space."_s;
    default:
        return u"The sync server answered "_s + QString::number(r.status) + u' ' + from_std(r.reason) + u'.';
    }
}

static void http(QString const& method, QString const& url, Http::Headers headers, QByteArray const& body, std::function<void(Http::Response const&)> done)
{
    Http::request(to_std(method), to_std(url), headers, body.toStdString(), [done = std::move(done)](Http::Response r) { done(r); });
}

static void read_blob(BlobStore const& b, std::function<void(bool found, QByteArray bytes, QString etag, QString error)> done)
{
    http(u"GET"_s, b.url, { { "Authorization", to_std(b.auth) }, { "Cache-Control", "no-cache" } }, {}, [b, done](Http::Response const& r) {
        if (r.status == 404)
            done(false, {}, {}, {});
        else if (r.status != 200)
            done(false, {}, {}, failure(b, r));
        else
            done(true, QByteArray::fromStdString(r.body), from_std(r.header("etag")), {});
    });
}

// A conditional PUT: if still at `if_match`, or (`create`) still absent.
static void write_blob(BlobStore const& b, QByteArray const& bytes, QString const& if_match, bool create,
    std::function<void(QString etag, bool conflict, QString error)> done)
{
    Http::Headers headers { { "Authorization", to_std(b.auth) }, { "Content-Type", "application/octet-stream" } };
    if (create)
        headers.emplace_back("If-None-Match", "*");
    else
        headers.emplace_back("If-Match", to_std(if_match));
    http(u"PUT"_s, b.url, headers, bytes, [b, done](Http::Response const& r) {
        if (r.status == 412)
            done({}, true, {});
        else if (r.status < 200 || r.status > 299)
            done({}, false, failure(b, r));
        else
            done(from_std(r.header("etag")), false, {});
    });
}

static void delete_blob(BlobStore const& b, std::function<void(QString error)> done)
{
    http(u"DELETE"_s, b.url, { { "Authorization", to_std(b.auth) } }, {}, [b, done](Http::Response const& r) {
        if (r.status != 404 && (r.status < 200 || r.status > 299))
            done(failure(b, r));
        else
            done({});
    });
}

static constexpr Blob all_blobs[] = { Blob::Vault, Blob::Bookmarks, Blob::Tabs, Blob::Summaries, Blob::Sessions, Blob::Secrets };

// Deletes every blob of the sync key, one after another; stops at the first error.
static void erase_all(QJsonObject const& s, std::function<void(QString)> done)
{
    auto keys = SyncKeys::derive(code_of(s));
    if (keys.encryption_key.isEmpty()) {
        done(u"That isn't a sync code."_s);
        return;
    }
    auto step = std::make_shared<std::function<void(size_t)>>();
    *step = [s, keys, done, step](size_t i) {
        if (i == std::size(all_blobs)) {
            done({});
            return;
        }
        delete_blob(store_for(s, keys, all_blobs[i]), [done, step, i](QString error) {
            if (!error.isEmpty())
                done(error);
            else
                (*step)(i + 1);
        });
    };
    (*step)(0);
}

struct Outcome {
    QJsonObject doc; // the merged state the server now holds
    QString etag;
    QString error;
};

// Merges `local` with the server's copy and makes the server hold the result, retrying when another device writes
// in between.
static void sync_once(QJsonObject const& s, QJsonObject const& local, Blob blob, std::function<void(Outcome)> done)
{
    auto keys = SyncKeys::derive(code_of(s));
    if (keys.encryption_key.isEmpty()) {
        done({ {}, {}, u"That isn't a sync code."_s });
        return;
    }
    auto b = store_for(s, keys, blob);
    auto attempt = std::make_shared<std::function<void(int)>>();
    *attempt = [b, keys, local, done, attempt](int n) {
        if (n >= 5) {
            done({ {}, {}, u"Other devices kept syncing at the same moment; try again."_s });
            return;
        }
        read_blob(b, [b, keys, local, done, attempt, n](bool found, QByteArray bytes, QString etag, QString error) {
            if (!error.isEmpty()) {
                done({ {}, {}, error });
                return;
            }
            QJsonObject remote = SyncDoc::new_doc();
            if (found) {
                QString why;
                auto opened = SyncKeys::open(keys, bytes, &why);
                if (!opened) {
                    done({ {}, {}, why });
                    return;
                }
                remote = *opened;
            }
            auto merged = SyncDoc::merge(local, remote, Profile::now_seconds());
            if (found && SyncDoc::same(merged, remote)) {
                done({ merged, etag, {} });
                return;
            }
            auto sealed = SyncKeys::seal(keys, merged);
            if (sealed.isEmpty()) {
                done({ {}, {}, u"Encrypting the synced data failed."_s });
                return;
            }
            write_blob(b, sealed, etag.isEmpty() ? u"*"_s : etag, !found, [merged, done, attempt, n](QString new_tag, bool conflict, QString error) {
                if (conflict)
                    (*attempt)(n + 1);
                else if (!error.isEmpty())
                    done({ {}, {}, error });
                else
                    done({ merged, new_tag, {} });
            });
        });
    };
    (*attempt)(0);
}

// ---------------------------------------------------------------------------------------------------------------
// This device's tabs as other devices see them, and the tabs they published (nim sync/devicetabs.nim).

static constexpr qint64 heartbeat = 3600; // seconds between republishing an unchanged record
static constexpr int max_tabs = 200;
static constexpr int max_title = 300;
static constexpr int max_url = 4096;

static struct {
    bool loaded { false };
    QString id;
    QString name;
    bool share { true };
    QList<DeviceTab> open_tabs;
    std::optional<QJsonObject> published; // what this device last put on the server
    QJsonObject remote;
    QList<std::function<void()>> listeners;
} s_device;

static void notify_devices()
{
    for (auto const& h : s_device.listeners)
        h();
}

void on_devices(std::function<void()> listener) { s_device.listeners.append(std::move(listener)); }

static QString device_file()
{
    auto o = qEnvironmentVariable("WEBBY_DEVICE_FILE");
    return o.isEmpty() ? Profile::file(u"wasm_device.json"_s) : o;
}

static QString default_device_name()
{
    auto host = QSysInfo::machineHostName();
    if (!host.isEmpty() && host != u"localhost" && host != u"wasi")
        return host + u" (webby wasm)"_s;
    return u"webby (wasm)"_s;
}

static void save_device()
{
    Profile::write_atomic(device_file(), QJsonDocument(QJsonObject { { u"id"_s, s_device.id }, { u"name"_s, s_device.name }, { u"share"_s, s_device.share } }).toJson(QJsonDocument::Indented));
}

static void load_device()
{
    if (s_device.loaded)
        return;
    s_device.loaded = true;
    auto j = Profile::read_json(device_file());
    if (!j.value(u"id").toString().isEmpty()) {
        s_device.id = j.value(u"id").toString();
        auto n = j.value(u"name").toString();
        s_device.name = n.trimmed().isEmpty() ? default_device_name() : n;
        s_device.share = j.value(u"share").toBool(true);
        return;
    }
    s_device.id = QString::fromLatin1(SyncKeys::random_bytes(16).toHex());
    s_device.name = default_device_name();
    save_device();
}

QString device_name()
{
    load_device();
    return s_device.name;
}

void set_device_name(QString const& value)
{
    load_device();
    auto t = value.trimmed();
    if (t.isEmpty() || t == s_device.name)
        return;
    s_device.name = t;
    save_device();
    notify_devices();
}

bool sharing()
{
    load_device();
    return s_device.share;
}

void set_sharing(bool on)
{
    load_device();
    if (on == s_device.share)
        return;
    s_device.share = on;
    save_device();
    notify_devices();
}

QList<DeviceTab> shared_tabs() { return s_device.open_tabs; }

// Worth showing on another device: not blank pages, nothing only this device can open.
static bool is_shareable_url(QString const& url)
{
    QUrl u(url);
    auto scheme = u.scheme().toLower();
    if (scheme != u"http" && scheme != u"https" && scheme != u"ftp" && scheme != u"file")
        return false;
    if (scheme == u"file")
        return !url.startsWith(u"file://"_s + Profile::dir() + u"/pages/"_s); // not webby's own pages
    return !u.host().isEmpty();
}

// The first `max` UTF-16 code units, as Dart's substring would keep (without half a surrogate pair).
static QString cut(QString const& text, int max)
{
    if (text.size() <= max)
        return text;
    auto out = text.left(max);
    if (!out.isEmpty() && out.back().isHighSurrogate())
        out.chop(1);
    return out;
}

void set_tabs(QList<DeviceTab> const& list)
{
    QList<DeviceTab> shareable;
    for (auto const& t : list) {
        if (is_shareable_url(t.url) && shareable.size() < max_tabs)
            shareable.append({ cut(t.title, max_title), cut(t.url, max_url) });
    }
    if (shareable == s_device.open_tabs)
        return;
    s_device.open_tabs = shareable;
    notify_devices();
}

QList<RemoteDevice> devices()
{
    load_device();
    QList<RemoteDevice> out;
    for (auto it = s_device.remote.begin(); it != s_device.remote.end(); ++it) {
        auto r = it.value().toObject();
        if (it.key() == s_device.id || SyncDoc::is_deleted(r))
            continue;
        RemoteDevice d;
        d.id = it.key();
        d.name = r.value(u"name").isString() ? r.value(u"name").toString() : u"Unnamed device"_s;
        d.platform = r.value(u"platform").toString();
        d.seen_at = SyncDoc::updated_at(r);
        for (auto const& t : r.value(u"tabs").toArray()) {
            auto o = t.toObject();
            if (o.value(u"url").isString() && !o.value(u"url").toString().isEmpty())
                d.tabs.append({ o.value(u"title").toString(), o.value(u"url").toString() });
        }
        out.append(d);
    }
    std::stable_sort(out.begin(), out.end(), [](auto const& a, auto const& b) { return a.seen_at > b.seen_at; });
    return out;
}

static QJsonObject device_record(qint64 updated)
{
    if (!s_device.share)
        return { { u"updatedAt"_s, updated }, { u"deleted"_s, true } };
    QJsonArray tabs;
    for (auto const& t : s_device.open_tabs)
        tabs.append(QJsonObject { { u"title"_s, t.title }, { u"url"_s, t.url } });
    return { { u"name"_s, s_device.name }, { u"platform"_s, u"wasm"_s }, { u"updatedAt"_s, updated }, { u"tabs"_s, tabs } };
}

static QByteArray without_time(QJsonObject r)
{
    r.remove(u"updatedAt"_s);
    return SyncDoc::canonical_value(r);
}

// This device's record changed, or is due for the heartbeat.
static bool needs_publish()
{
    load_device();
    if (!s_device.published)
        return true;
    if (without_time(device_record(0)) != without_time(*s_device.published))
        return true;
    return !SyncDoc::is_deleted(*s_device.published) && Profile::now_seconds() - SyncDoc::updated_at(*s_device.published) >= heartbeat;
}

static QJsonObject devices_doc()
{
    load_device();
    auto r = needs_publish() ? device_record(std::max(Profile::now_seconds(), s_device.published ? SyncDoc::updated_at(*s_device.published) + 1 : 0))
                             : *s_device.published;
    return SyncDoc::doc_with(u"devices"_s, QJsonObject { { s_device.id, r } });
}

// Takes in the merged tabs blob. True if this device's record there differs from what it would publish.
static bool apply_devices_doc(QJsonObject const& d)
{
    load_device();
    auto all = SyncDoc::section(d, u"devices"_s);
    if (all.value(s_device.id).isObject())
        s_device.published = all.value(s_device.id).toObject();
    else
        s_device.published.reset();
    QJsonObject others = all;
    others.remove(s_device.id);
    bool changed = SyncDoc::canonical_value(others) != SyncDoc::canonical_value(s_device.remote);
    s_device.remote = others;
    if (changed)
        notify_devices();
    return needs_publish();
}

static void reset_devices()
{
    s_device.published.reset();
    if (s_device.remote.isEmpty())
        return;
    s_device.remote = {};
    notify_devices();
}

// ---------------------------------------------------------------------------------------------------------------
// Scheduling (nim sync/engine.nim)

struct Kind {
    Blob blob;
    std::function<QJsonObject()> current;
    std::function<void(QJsonObject const&)> apply;
};
// In the order a round takes them, as on the desktop: vault, secrets, bookmarks, tabs.
static QList<Kind> s_kinds;
static QMap<int, QByteArray> s_last_synced; // canonical form of what the server held after the last round, by Blob
static QTimer* s_debounce;
static QTimer* s_tabs_debounce;
static QTimer* s_every;
static bool s_started = false;

static int order_of(Blob b)
{
    switch (b) {
    case Blob::Vault: return 0;
    case Blob::Secrets: return 1;
    case Blob::Bookmarks: return 2;
    case Blob::Tabs: return 3;
    case Blob::Summaries: return 4;
    case Blob::Sessions: return 5;
    }
    return 6;
}

void register_blob(Blob blob, std::function<QJsonObject()> current, std::function<void(QJsonObject const&)> apply)
{
    s_kinds.removeIf([&](Kind const& k) { return k.blob == blob; });
    auto at = std::find_if(s_kinds.begin(), s_kinds.end(), [&](Kind const& k) { return order_of(k.blob) > order_of(blob); });
    s_kinds.insert(at, Kind { blob, std::move(current), std::move(apply) });
    s_last_synced.remove(int(blob));
    // A kind that comes later (the vault, once it opens) syncs straight away.
    if (s_started && enabled())
        QTimer::singleShot(500, [] { sync_now(); });
}

void local_changed(Blob blob)
{
    if (!enabled() || s_running || !s_debounce)
        return;
    for (auto const& k : s_kinds) {
        if (k.blob == blob && s_last_synced.contains(int(blob)) && SyncDoc::canonical(k.current()) == s_last_synced.value(int(blob)))
            return;
    }
    s_debounce->start(3000);
}

static void tabs_changed()
{
    // Tabs change with every page load; publish once browsing settles.
    if (!enabled() || s_running || !needs_publish() || !s_tabs_debounce)
        return;
    s_tabs_debounce->start(10'000);
}

static void forget()
{
    s_last_synced.clear();
    reset_devices();
}

void sync_now()
{
    if (s_running) {
        s_again = true;
        return;
    }
    auto s = settings();
    if (s.isEmpty())
        return;
    auto code = code_of(s);
    s_running = true;
    if (s_debounce)
        s_debounce->stop();
    if (s_tabs_debounce)
        s_tabs_debounce->stop();
    notify_status();
    auto still_on = [code] { return code_of(settings()) == code; };

    auto finish = [still_on](QString const& error, QString const& etag) {
        if (!error.isEmpty()) {
            qWarning("webby: sync failed: %s", qPrintable(error));
            if (still_on())
                update_settings([&](QJsonObject& c) { c.insert(u"lastError"_s, error); });
        } else if (still_on()) {
            update_settings([&](QJsonObject& c) {
                if (!etag.isEmpty())
                    c.insert(u"etag"_s, etag);
                c.insert(u"lastSync"_s, Profile::now_seconds());
                c.remove(u"lastError"_s);
            });
        }
        s_running = false;
        notify_status();
        if (s_again) {
            s_again = false;
            QTimer::singleShot(0, [] { sync_now(); });
        }
    };

    // Each kind in turn: read + merge + write its blob, then take the merged state in.
    auto kinds = s_kinds;
    auto step = std::make_shared<std::function<void(qsizetype, QString)>>();
    *step = [s, kinds, finish, still_on, step](qsizetype i, QString first_etag) {
        if (i == kinds.size()) {
            finish({}, first_etag);
            return;
        }
        auto const& kind = kinds[i];
        sync_once(s, kind.current(), kind.blob, [kind, finish, still_on, step, i, first_etag](Outcome o) {
            if (!o.error.isEmpty()) {
                finish(o.error, {});
                return;
            }
            if (!still_on()) {
                finish({}, {});
                return;
            }
            if (kind.blob == Blob::Tabs) {
                // Tabs that changed during the round, or this device's record lost to another's, go up next round.
                if (apply_devices_doc(o.doc))
                    s_again = true;
            } else {
                // The store may have changed while we were talking to the server; keep those changes too.
                auto merged = SyncDoc::merge(kind.current(), o.doc, Profile::now_seconds());
                s_last_synced.insert(int(kind.blob), SyncDoc::canonical(o.doc));
                kind.apply(merged);
                if (!SyncDoc::same(merged, o.doc))
                    s_again = true;
            }
            (*step)(i + 1, kind.blob == Blob::Vault ? o.etag : first_etag);
        });
    };
    (*step)(0, {});
}

QString enable(QJsonObject const& s)
{
    QString error;
    if (!SyncKeys::key_from_code(code_of(s), &error))
        return error;
    forget();
    store_settings(s);
    notify_status();
    sync_now();
    return {};
}

void disable(bool erase, std::function<void(QString const&)> on_done)
{
    auto s = settings();
    if (s.isEmpty()) {
        on_done({});
        return;
    }
    auto off = [on_done] {
        if (s_debounce)
            s_debounce->stop();
        if (s_tabs_debounce)
            s_tabs_debounce->stop();
        forget();
        store_settings({});
        notify_status();
        on_done({});
    };
    if (!erase) {
        off();
        return;
    }
    erase_all(s, [off, on_done](QString const& error) {
        if (!error.isEmpty())
            on_done(error);
        else
            off();
    });
}

void set_settings_store(std::function<QJsonObject()> get, std::function<void(QJsonObject const&)> set)
{
    auto kept = Profile::read_json(settings_file()).value(u"settings").toObject();
    s_get_settings = std::move(get);
    s_set_settings = std::move(set);
    // Settings kept in sync.json before the vault was there move into it (unless it has its own).
    if (!code_of(kept).isEmpty()) {
        if (code_of(stored_settings()).isEmpty())
            store_settings(kept);
        QFile::remove(settings_file());
    }
    notify_status();
}

void start()
{
    if (s_started)
        return;
    s_started = true;
    register_blob(Blob::Bookmarks, [] { return SyncDoc::doc_with(u"bookmarks"_s, Profile::Bookmarks::the().to_sync_records()); },
        [](QJsonObject const& merged) { Profile::Bookmarks::the().apply_sync_records(SyncDoc::section(merged, u"bookmarks"_s)); });
    register_blob(Blob::Tabs, [] { return devices_doc(); }, [](QJsonObject const&) { });
    Profile::Bookmarks::the().on_change([] { local_changed(Blob::Bookmarks); });
    register_blob(Blob::Sessions, [] { return SyncDoc::doc_with(u"sessions"_s, Sessions::to_sync_doc()); },
        [](QJsonObject const& merged) { Sessions::apply_sync_doc(SyncDoc::section(merged, u"sessions"_s)); });
    Sessions::on_change([] { local_changed(Blob::Sessions); });
    register_blob(Blob::Summaries, [] { return SyncDoc::doc_with(u"summaries"_s, Summarize::to_sync_records()); },
        [](QJsonObject const& merged) { Summarize::apply_sync_records(SyncDoc::section(merged, u"summaries"_s)); });
    Summarize::on_saved_change([] { local_changed(Blob::Summaries); });
    on_devices([] { tabs_changed(); });

    s_debounce = new QTimer;
    s_debounce->setSingleShot(true);
    QObject::connect(s_debounce, &QTimer::timeout, [] { sync_now(); });
    s_tabs_debounce = new QTimer;
    s_tabs_debounce->setSingleShot(true);
    QObject::connect(s_tabs_debounce, &QTimer::timeout, [] { sync_now(); });
    s_every = new QTimer;
    s_every->setInterval(5 * 60 * 1000);
    QObject::connect(s_every, &QTimer::timeout, [] { sync_now(); });
    s_every->start();
    if (enabled())
        QTimer::singleShot(500, [] { sync_now(); });
}

}
