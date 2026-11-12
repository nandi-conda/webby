/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Sync, as the Nim front end has it (nim/src/features/sync.nim and sync/): bookmarks, this device's open tabs and
// (with the vault, Vault.h) passwords, passkeys and never-save sites, end-to-end encrypted with a sync code and
// stored on the webby-sync server (sync-worker/) or in a WebDAV folder, the same blobs and formats as the desktop
// and Android webby. Each kind of data is its own blob; a round reads each, merges (SyncDoc.h), writes the result back
// with a conditional PUT and takes the merged state in. Rounds run at start, a few seconds after a change, every five
// minutes and when asked, one request at a time, on the UI's event loop.
//
// The settings ({code, backend: "webby-sync" | "webdav", server, username?, password?, etag?, lastSync?,
// lastError?}) live inside the encrypted vault, as on the desktop, once the vault hands them over
// (set_settings_store); until then in <profile>/sync.json.

#pragma once

#include <QJsonObject>
#include <QList>
#include <QString>
#include <functional>

namespace WebbyUI::Sync {

enum class Blob {
    Vault,
    Bookmarks,
    Tabs,
    Summaries,
    Sessions,
    Secrets,
};

QString const& default_server();

// A kind of data that syncs: what this device has now, as a doc (SyncDoc.h), and how to take in the merged state
// after a round. The vault registers Vault and Secrets; Sync itself registers Bookmarks and Tabs.
void register_blob(Blob, std::function<QJsonObject()> current, std::function<void(QJsonObject const& merged)> apply);
// That kind changed here: sync in a few seconds (unless it is what was just synced).
void local_changed(Blob);

// Where the settings are kept: the vault hands over its getter and setter. Settings kept in sync.json so far move
// into it.
void set_settings_store(std::function<QJsonObject()> get, std::function<void(QJsonObject const&)> set);

// Starts syncing (once the first page view has set the network up): now if sync is on, then every five minutes.
void start();

QJsonObject settings(); // empty when sync is off
bool enabled();
bool syncing();
QString last_error();
qint64 last_sync();      // seconds since the epoch, 0 for never
// Where this device syncs, in words ("the webby sync server", "WebDAV folder …").
QString where();
// Syncing started or stopped, or the settings or the last error changed.
void on_status(std::function<void()>);

// One round over every blob now (another follows if one is running).
void sync_now();
// Starts syncing with these settings (from new_settings or from_pairing): "" or why not.
QString enable(QJsonObject const& settings);
// Stops syncing here; with `erase` it first deletes the server's copies, which stops every device syncing.
void disable(bool erase, std::function<void(QString const& error)> on_done);

// A new random sync code (webby1-…).
QString generate_code();
QJsonObject new_settings(QString const& code, bool webdav = false, QString const& server = default_server(),
    QString const& username = {}, QString const& password = {});
QString code_of(QJsonObject const& settings);
bool is_webdav(QJsonObject const& settings);
QString server_of(QJsonObject const& settings);
// What another device needs to join: webby-sync:pair?code=…, plus where to sync when it isn't the default.
QString pairing_link(QJsonObject const& settings);
// Settings from a pairing link or a bare code; empty (and `error`) if it is neither.
QJsonObject from_pairing(QString const& text, QString* error);

// Tabs from other devices. This device is <profile>/wasm_device.json ({id, name, share}; $WEBBY_DEVICE_FILE), its own
// device apart from the desktop webby that may share the profile folder.
struct DeviceTab {
    QString title;
    QString url;
    bool operator==(DeviceTab const&) const = default;
};
struct RemoteDevice {
    QString id;
    QString name;
    QString platform;
    qint64 seen_at { 0 };
    QList<DeviceTab> tabs;
};
QString device_name();
void set_device_name(QString const&);
bool sharing();
void set_sharing(bool);
// The browser's tabs changed: the ones that make sense on another device are published.
void set_tabs(QList<DeviceTab> const&);
QList<DeviceTab> shared_tabs();
// The other devices, most recently seen first.
QList<RemoteDevice> devices();
// The name, sharing, this device's tabs or the other devices changed.
void on_devices(std::function<void()>);

}
