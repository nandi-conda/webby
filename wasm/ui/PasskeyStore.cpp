/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Passkeys.h"

#include <AK/JsonArray.h>
#include <AK/JsonValue.h>
#include <Authenticator.h>
#include <errno.h>
#include <unistd.h>

namespace WebbyUI::Passkeys {

static Webby::VaultCredentialStore* s_vault_store;

// As native/webby_ffi.cpp's webby_passkeys_use_vault.
bool use_vault(std::string const& json)
{
    auto parsed = JsonValue::from_string(StringView { json.data(), json.size() });
    if (parsed.is_error() || !parsed.value().is_array())
        return false;
    auto passkeys = Webby::passkeys_from_json(parsed.value().as_array());
    for (auto& passkey : Webby::credential_store().all()) {
        if (!passkeys.find_if([&](auto const& existing) { return existing.credential_id == passkey.credential_id; }).is_end())
            continue;
        passkeys.append(move(passkey));
    }
    auto store = make<Webby::VaultCredentialStore>(move(passkeys));
    s_vault_store = store.ptr();
    Webby::set_credential_store(move(store));
    return true;
}

uint64_t serial() { return s_vault_store ? s_vault_store->serial() : 0; }

std::string export_json()
{
    auto exported = Webby::passkeys_to_json(Webby::credential_store().all()).serialized().to_byte_string();
    return std::string(exported.characters(), exported.length());
}

bool remove(std::string const& credential_id)
{
    return !Webby::credential_store().remove(StringView { credential_id.data(), credential_id.size() }).is_error();
}

}

namespace WebbyUI::Passkeys {

bool delete_file()
{
    if (!s_vault_store)
        return false;
    auto path = Webby::passkeys_file_path();
    return unlink(path.characters()) == 0 || errno == ENOENT;
}

}
