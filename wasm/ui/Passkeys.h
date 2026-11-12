/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The passkey authenticator's store (../../native/Authenticator.h), for the UI: as the Nim front end's webby_passkeys_*
// calls, the passkeys live in the password vault and the authenticator keeps them in memory. No AK types here.

#pragma once

#include <cstdint>
#include <string>

namespace WebbyUI::Passkeys {

// Hands the vault's passkeys (a JSON array: credentialId, rpId, userId, userName, userDisplayName, privateKey,
// createdAt) to the authenticator, which keeps any of its own the list lacks. False if the JSON is not an array.
bool use_vault(std::string const& json);
// Changes whenever the authenticator's passkeys do (a sign-up made one); 0 before use_vault.
uint64_t serial();
// The authenticator's passkeys, in the same JSON.
std::string export_json();
bool remove(std::string const& credential_id);
// Deletes the authenticator's own passkeys.json once its passkeys are in the vault (after use_vault).
bool delete_file();

}
