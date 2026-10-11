/*
 * Webby: a software passkey authenticator for Ladybird's Web Authentication client.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <AK/ByteString.h>
#include <AK/JsonObject.h>
#include <AK/String.h>
#include <AK/Vector.h>

namespace Webby {

// One passkey: an ES256 (P-256) key pair bound to a relying party and a user. Credential and user ids are unpadded
// base64url, the private key is base64 DER.
struct Passkey {
    String credential_id;
    String rp_id;
    String user_id;
    String user_name;
    String user_display_name;
    String private_key;
    i64 created_at { 0 };
};

// Passkeys live in a JSON file readable only by the user: $WEBBY_PASSKEYS_FILE, or
// ${XDG_DATA_HOME:-~/.local/share}/webby/passkeys.json.
class PasskeyStore {
public:
    static PasskeyStore& the();

    Vector<Passkey> const& passkeys() const { return m_passkeys; }
    Vector<Passkey> passkeys_for(StringView rp_id, Vector<String> const& allowed_credential_ids) const;
    bool contains_any(StringView rp_id, Vector<String> const& credential_ids) const;

    ErrorOr<void> add(Passkey);
    ByteString const& path() const { return m_path; }

private:
    PasskeyStore();
    ErrorOr<void> save() const;

    ByteString m_path;
    Vector<Passkey> m_passkeys;
};

// The authenticator half of a ceremony. `request` is the JSON object LibWeb sent (see LibWeb/WebAuthn/WebAuthn.h); the
// return value is the JSON reply.
String make_credential(JsonObject const& request);
String get_assertion(JsonObject const& request, Passkey const&);
String error_reply(StringView name, StringView message);

}
