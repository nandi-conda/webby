/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The owner of the pages' localStorage and sessionStorage maps. In native webby that's the browser process
// (LibWebView's StorageAreaRegistry over a StorageJar), and each WebContent process keeps a mirror of the maps it
// uses (LibWeb/StorageAPI/StorageAreaMirror). Here LibWeb runs inside the UI module, so this file answers the
// mirrors directly. Without an owner, a mirror never loads: every setItem() throws QuotaExceededError and every
// getItem() returns null.
//
// localStorage is kept in <profile>/local_storage.json ({"<storage key>": {"<key>": "<value>", ...}}), written a
// moment after the last change. sessionStorage lives as long as the module does.

#pragma once

namespace WebbyUI::Storage {

// Installs the owner as the process's StorageAreaMirrorClient and reads the saved localStorage.
void initialize();

// Writes localStorage now, if anything changed since the last write.
void flush();

}
