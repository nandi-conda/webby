/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The desktop keyring (Secret Service), where the Nim front end keeps the password vault's key. A wasm module has no
// D-Bus, so the host runs `secret-tool lookup application webby profile <profile>` (libsecret's tool) on a pty
// (latha:gui's pty interface, wit/pty) and the key is what it prints. A host without secret-tool, or a keyring
// without the item, gives nothing.

#pragma once

#include <QString>
#include <functional>

namespace WebbyUI::Keyring {

struct Lookup {
    bool found { false };
    QString secret;
    QString error; // why the keyring could not be asked ("" when it answered, found or not)
};

// Asks, and calls `done` from the event loop when the tool has ended (or after a time limit; an unlock prompt can
// take a while).
void lookup(QString const& profile, std::function<void(Lookup)> done);

}
