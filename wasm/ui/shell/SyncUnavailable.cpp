/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Sync.h for the UI component built without Ladybird: it has no network or libcrypto of its own (the engine
// component's RequestServer is not reachable from here yet), so sync stays off and says why. The in-tree webby.wasm
// (../Sync.cpp) syncs.

#include "../Sync.h"

using namespace Qt::StringLiterals;

namespace WebbyUI::Sync {

static QString const unavailable = u"Sync needs the full webby.wasm (the in-tree build); this composed build has no network for it yet."_s;

QString const& default_server()
{
    static QString const url = u"https://webby-sync.nandithebull.workers.dev"_s;
    return url;
}

void register_blob(Blob, std::function<QJsonObject()>, std::function<void(QJsonObject const&)>) { }
void local_changed(Blob) { }
void set_settings_store(std::function<QJsonObject()>, std::function<void(QJsonObject const&)>) { }
void start() { }
QJsonObject settings() { return {}; }
bool enabled() { return false; }
bool syncing() { return false; }
QString last_error() { return {}; }
qint64 last_sync() { return 0; }
QString where() { return {}; }
void on_status(std::function<void()>) { }
void sync_now() { }
QString enable(QJsonObject const&) { return unavailable; }
void disable(bool, std::function<void(QString const&)> on_done) { on_done({}); }
QString generate_code() { return {}; }
QJsonObject new_settings(QString const& code, bool, QString const&, QString const&, QString const&) { return { { u"code"_s, code } }; }
QString code_of(QJsonObject const& s) { return s.value(u"code").toString(); }
bool is_webdav(QJsonObject const&) { return false; }
QString server_of(QJsonObject const&) { return default_server(); }
QString pairing_link(QJsonObject const&) { return {}; }
QJsonObject from_pairing(QString const&, QString* error)
{
    if (error)
        *error = unavailable;
    return {};
}
QString device_name() { return {}; }
void set_device_name(QString const&) { }
bool sharing() { return false; }
void set_sharing(bool) { }
void set_tabs(QList<DeviceTab> const&) { }
QList<DeviceTab> shared_tabs() { return {}; }
QList<RemoteDevice> devices() { return {}; }
void on_devices(std::function<void()>) { }

}
