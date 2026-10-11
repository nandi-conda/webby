/*
 * Webby: a software passkey authenticator for Ladybird's Web Authentication client.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <AK/ByteString.h>
#include <AK/JsonArray.h>
#include <AK/JsonObject.h>
#include <AK/NonnullOwnPtr.h>
#include <AK/Optional.h>
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

// Where passkeys are kept. The authenticator and the UI only go through this interface, so storage can move (into
// the password manager's encrypted vault, say) without touching the ceremonies.
class CredentialStore {
public:
    AK_ALLOC_WITH_KMALLOC;

    virtual ~CredentialStore() = default;

    // The passkeys for `rp_id`; when `allowed_credential_ids` isn't empty, only those among them.
    virtual Vector<Passkey> list(StringView rp_id, Vector<String> const& allowed_credential_ids = {}) const = 0;
    virtual Optional<Passkey> get(StringView credential_id) const = 0;
    // Saves a new passkey. One for the same relying party and user replaces the old one.
    virtual ErrorOr<void> create(Passkey) = 0;
    virtual ErrorOr<void> remove(StringView credential_id) = 0;
    // Every passkey, for the UI's list.
    virtual Vector<Passkey> all() const = 0;
};

// The store in use: a FileCredentialStore unless set_credential_store() swapped in another.
CredentialStore& credential_store();
void set_credential_store(NonnullOwnPtr<CredentialStore>);

// Passkeys in a JSON file readable only by the user: $WEBBY_PASSKEYS_FILE, or
// ${XDG_DATA_HOME:-~/.local/share}/webby/passkeys.json.
class FileCredentialStore final : public CredentialStore {
public:
    FileCredentialStore();

    virtual Vector<Passkey> list(StringView rp_id, Vector<String> const& allowed_credential_ids = {}) const override;
    virtual Optional<Passkey> get(StringView credential_id) const override;
    virtual ErrorOr<void> create(Passkey) override;
    virtual ErrorOr<void> remove(StringView credential_id) override;
    virtual Vector<Passkey> all() const override { return m_passkeys; }

    ByteString const& path() const { return m_path; }

private:
    ErrorOr<void> save() const;

    ByteString m_path;
    Vector<Passkey> m_passkeys;
};

// Passkeys kept in memory on behalf of the password manager's encrypted vault: the UI hands them over at startup and
// saves the list again whenever serial() changes (see webby_passkeys_* in webby_ffi.h).
class VaultCredentialStore final : public CredentialStore {
public:
    explicit VaultCredentialStore(Vector<Passkey>);

    virtual Vector<Passkey> list(StringView rp_id, Vector<String> const& allowed_credential_ids = {}) const override;
    virtual Optional<Passkey> get(StringView credential_id) const override;
    virtual ErrorOr<void> create(Passkey) override;
    virtual ErrorOr<void> remove(StringView credential_id) override;
    virtual Vector<Passkey> all() const override { return m_passkeys; }

    // Changes whenever the passkeys do. Starts at 1 so the first look always saves.
    u64 serial() const { return m_serial; }

private:
    Vector<Passkey> m_passkeys;
    u64 m_serial { 1 };
};

// Passkeys as JSON, the form both passkeys.json and the vault use: objects with credentialId, rpId, userId, userName,
// userDisplayName, privateKey and createdAt. Entries without an id, relying party or key are skipped.
JsonArray passkeys_to_json(Vector<Passkey> const&);
Vector<Passkey> passkeys_from_json(JsonArray const&);

// Where FileCredentialStore keeps passkeys.
ByteString passkeys_file_path();

// The authenticator half of a ceremony. `request` is the JSON object LibWeb sent (see LibWeb/WebAuthn/WebAuthn.h); the
// return value is the JSON reply.
String make_credential(JsonObject const& request);
String get_assertion(JsonObject const& request, Passkey const&);
String error_reply(StringView name, StringView message);

}
