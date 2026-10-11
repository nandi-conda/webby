/*
 * Webby: a software passkey authenticator for Ladybird's Web Authentication client.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <AK/Base64.h>
#include <AK/JsonArray.h>
#include <AK/JsonValue.h>
#include <AK/LexicalPath.h>
#include <AK/OwnPtr.h>
#include <AK/ScopeGuard.h>
#include <AK/StringBuilder.h>
#include <Authenticator.h>

#include <errno.h>
#include <fcntl.h>
#include <openssl/core_names.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/x509.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

namespace Webby {

// https://www.iana.org/assignments/cose/cose.xhtml
static constexpr i64 COSE_ALGORITHM_ES256 = -7;

// https://w3c.github.io/webauthn/#authenticator-data
static constexpr u8 FLAG_USER_PRESENT = 0x01;
static constexpr u8 FLAG_USER_VERIFIED = 0x04;
static constexpr u8 FLAG_ATTESTED_CREDENTIAL_DATA = 0x40;

static constexpr size_t CREDENTIAL_ID_LENGTH = 16;

static String string_member(JsonObject const& object, StringView key)
{
    if (auto value = object.get_string(key); value.has_value())
        return *value;
    return {};
}

static String base64url(ReadonlyBytes bytes)
{
    return MUST(encode_base64url(bytes, AK::OmitPadding::Yes));
}

String error_reply(StringView name, StringView message)
{
    JsonObject reply;
    reply.set("error"sv, MUST(String::from_utf8(name)));
    reply.set("message"sv, MUST(String::from_utf8(message)));
    return reply.serialized();
}

// Just enough CBOR (RFC 8949) for attestation objects and COSE keys, in CTAP2 canonical form.
class CborWriter {
public:
    void unsigned_integer(u64 value) { head(0, value); }
    void integer(i64 value)
    {
        if (value >= 0)
            head(0, static_cast<u64>(value));
        else
            head(1, static_cast<u64>(-1 - value));
    }
    void bytes(ReadonlyBytes value)
    {
        head(2, value.size());
        m_buffer.append(value);
    }
    void text(StringView value)
    {
        head(3, value.length());
        m_buffer.append(value.bytes());
    }
    void map(size_t entries) { head(5, entries); }

    ByteBuffer release() { return move(m_buffer); }

private:
    void head(u8 major, u64 value)
    {
        major <<= 5;
        if (value < 24) {
            m_buffer.append(major | static_cast<u8>(value));
        } else if (value <= 0xff) {
            m_buffer.append(major | 24);
            m_buffer.append(static_cast<u8>(value));
        } else if (value <= 0xffff) {
            m_buffer.append(major | 25);
            m_buffer.append(static_cast<u8>(value >> 8));
            m_buffer.append(static_cast<u8>(value));
        } else {
            m_buffer.append(major | 26);
            for (int shift = 24; shift >= 0; shift -= 8)
                m_buffer.append(static_cast<u8>(value >> shift));
        }
    }

    ByteBuffer m_buffer;
};

static ByteBuffer sha256(ReadonlyBytes data)
{
    auto digest = MUST(ByteBuffer::create_uninitialized(SHA256_DIGEST_LENGTH));
    SHA256(data.data(), data.size(), digest.data());
    return digest;
}

static ByteBuffer random_bytes(size_t count)
{
    auto bytes = MUST(ByteBuffer::create_uninitialized(count));
    VERIFY(RAND_bytes(bytes.data(), static_cast<int>(count)) == 1);
    return bytes;
}

static ByteBuffer authenticator_data(StringView rp_id, u8 flags, ReadonlyBytes attested_credential_data = {})
{
    ByteBuffer data;
    auto rp_id_hash = sha256(rp_id.bytes());
    data.append(rp_id_hash);
    data.append(flags);
    // A signature counter of zero tells relying parties this authenticator doesn't count signatures.
    for (int i = 0; i < 4; ++i)
        data.append(static_cast<u8>(0));
    data.append(attested_credential_data);
    return data;
}

static ErrorOr<ByteBuffer> ec_coordinate(EVP_PKEY* key, char const* name)
{
    BIGNUM* number = nullptr;
    if (EVP_PKEY_get_bn_param(key, name, &number) != 1)
        return Error::from_string_literal("Unable to read the public key");
    ScopeGuard free_number = [&] { BN_free(number); };
    auto bytes = TRY(ByteBuffer::create_zeroed(32));
    if (BN_bn2binpad(number, bytes.data(), 32) != 32)
        return Error::from_string_literal("Unexpected public key size");
    return bytes;
}

static ErrorOr<ByteBuffer> der_from(EVP_PKEY* key, int (*encode)(EVP_PKEY const*, unsigned char**))
{
    unsigned char* der = nullptr;
    auto length = encode(key, &der);
    if (length <= 0)
        return Error::from_string_literal("Unable to encode key");
    ScopeGuard free_der = [&] { OPENSSL_free(der); };
    return ByteBuffer::copy(der, static_cast<size_t>(length));
}

static int encode_private_key(EVP_PKEY const* key, unsigned char** out) { return i2d_PrivateKey(key, out); }
static int encode_public_key(EVP_PKEY const* key, unsigned char** out) { return i2d_PUBKEY(key, out); }

static bool user_verification_requested(JsonObject const& request)
{
    // The user confirms every ceremony in the browser's own dialog, so we report them as verified whatever the
    // relying party asked for.
    (void)request;
    return true;
}

// https://w3c.github.io/webauthn/#sctn-op-make-cred
String make_credential(JsonObject const& request)
{
    bool supports_es256 = false;
    if (auto algorithms = request.get_array("algorithms"sv); algorithms.has_value()) {
        algorithms->for_each([&](JsonValue const& value) {
            if (value.get_i64() == COSE_ALGORITHM_ES256)
                supports_es256 = true;
        });
    }
    if (!supports_es256)
        return error_reply("NotSupportedError"sv, "This authenticator only supports ES256 keys"sv);

    auto rp_id = request.get_string("rpId"sv);
    auto user_id = request.get_string("userId"sv);
    if (!rp_id.has_value() || !user_id.has_value())
        return error_reply("UnknownError"sv, "Malformed request"sv);

    EVP_PKEY* key = EVP_PKEY_Q_keygen(nullptr, nullptr, "EC", "P-256");
    if (!key)
        return error_reply("UnknownError"sv, "Unable to generate a key"sv);
    ScopeGuard free_key = [&] { EVP_PKEY_free(key); };

    auto x = ec_coordinate(key, OSSL_PKEY_PARAM_EC_PUB_X);
    auto y = ec_coordinate(key, OSSL_PKEY_PARAM_EC_PUB_Y);
    auto private_key = der_from(key, encode_private_key);
    auto public_key = der_from(key, encode_public_key);
    if (x.is_error() || y.is_error() || private_key.is_error() || public_key.is_error())
        return error_reply("UnknownError"sv, "Unable to export the key"sv);

    auto credential_id = random_bytes(CREDENTIAL_ID_LENGTH);

    // https://w3c.github.io/webauthn/#sctn-encoded-credPubKey-examples
    CborWriter cose_key;
    cose_key.map(5);
    cose_key.integer(1); // kty
    cose_key.integer(2); // EC2
    cose_key.integer(3); // alg
    cose_key.integer(COSE_ALGORITHM_ES256);
    cose_key.integer(-1); // crv
    cose_key.integer(1);  // P-256
    cose_key.integer(-2); // x
    cose_key.bytes(x.value());
    cose_key.integer(-3); // y
    cose_key.bytes(y.value());

    // https://w3c.github.io/webauthn/#sctn-attested-credential-data
    ByteBuffer attested_credential_data;
    auto aaguid = MUST(ByteBuffer::create_zeroed(16));
    attested_credential_data.append(aaguid); // AAGUID
    attested_credential_data.append(static_cast<u8>(CREDENTIAL_ID_LENGTH >> 8));
    attested_credential_data.append(static_cast<u8>(CREDENTIAL_ID_LENGTH & 0xff));
    attested_credential_data.append(credential_id);
    auto cose_key_bytes = cose_key.release();
    attested_credential_data.append(cose_key_bytes);

    u8 flags = FLAG_USER_PRESENT | FLAG_ATTESTED_CREDENTIAL_DATA;
    if (user_verification_requested(request))
        flags |= FLAG_USER_VERIFIED;
    auto auth_data = authenticator_data(*rp_id, flags, attested_credential_data);

    // https://w3c.github.io/webauthn/#sctn-none-attestation
    CborWriter attestation_object;
    attestation_object.map(3);
    attestation_object.text("fmt"sv);
    attestation_object.text("none"sv);
    attestation_object.text("attStmt"sv);
    attestation_object.map(0);
    attestation_object.text("authData"sv);
    attestation_object.bytes(auth_data);

    Passkey passkey;
    passkey.credential_id = base64url(credential_id);
    passkey.rp_id = *rp_id;
    passkey.user_id = *user_id;
    passkey.user_name = string_member(request, "userName"sv);
    passkey.user_display_name = string_member(request, "userDisplayName"sv);
    passkey.private_key = MUST(encode_base64(private_key.value()));
    passkey.created_at = time(nullptr);
    if (auto result = credential_store().create(passkey); result.is_error())
        return error_reply("UnknownError"sv, ByteString::formatted("Unable to save the passkey: {}", result.error()));

    JsonObject reply;
    reply.set("credentialId"sv, passkey.credential_id);
    reply.set("authenticatorData"sv, base64url(auth_data));
    auto attestation_object_bytes = attestation_object.release();
    reply.set("attestationObject"sv, base64url(attestation_object_bytes));
    reply.set("publicKey"sv, base64url(public_key.value()));
    reply.set("publicKeyAlgorithm"sv, COSE_ALGORITHM_ES256);
    reply.set("residentKey"sv, true);
    return reply.serialized();
}

// https://w3c.github.io/webauthn/#sctn-op-get-assertion
String get_assertion(JsonObject const& request, Passkey const& passkey)
{
    auto client_data_hash = request.get_string("clientDataHash"sv);
    if (!client_data_hash.has_value())
        return error_reply("UnknownError"sv, "Malformed request"sv);
    auto hash = decode_base64url(*client_data_hash);
    auto private_key = decode_base64(passkey.private_key);
    if (hash.is_error() || private_key.is_error())
        return error_reply("UnknownError"sv, "Malformed request"sv);

    unsigned char const* der = private_key.value().data();
    EVP_PKEY* key = d2i_AutoPrivateKey(nullptr, &der, static_cast<long>(private_key.value().size()));
    if (!key)
        return error_reply("UnknownError"sv, "The stored passkey is damaged"sv);
    ScopeGuard free_key = [&] { EVP_PKEY_free(key); };

    u8 flags = FLAG_USER_PRESENT;
    if (user_verification_requested(request))
        flags |= FLAG_USER_VERIFIED;
    auto auth_data = authenticator_data(passkey.rp_id, flags);

    // The signature covers authenticatorData || clientDataHash.
    ByteBuffer signed_data;
    signed_data.append(auth_data);
    signed_data.append(hash.value());

    EVP_MD_CTX* context = EVP_MD_CTX_new();
    ScopeGuard free_context = [&] { EVP_MD_CTX_free(context); };
    size_t signature_length = 0;
    if (EVP_DigestSignInit(context, nullptr, EVP_sha256(), nullptr, key) != 1
        || EVP_DigestSign(context, nullptr, &signature_length, signed_data.data(), signed_data.size()) != 1)
        return error_reply("UnknownError"sv, "Unable to sign"sv);
    auto signature = MUST(ByteBuffer::create_uninitialized(signature_length));
    if (EVP_DigestSign(context, signature.data(), &signature_length, signed_data.data(), signed_data.size()) != 1)
        return error_reply("UnknownError"sv, "Unable to sign"sv);
    signature.resize(signature_length);

    JsonObject reply;
    reply.set("credentialId"sv, passkey.credential_id);
    reply.set("authenticatorData"sv, base64url(auth_data));
    reply.set("signature"sv, base64url(signature));
    reply.set("userHandle"sv, passkey.user_id);
    return reply.serialized();
}

static ByteString passkeys_path()
{
    if (auto const* path = getenv("WEBBY_PASSKEYS_FILE"); path && *path)
        return path;
    ByteString data_home;
    if (auto const* xdg = getenv("XDG_DATA_HOME"); xdg && *xdg)
        data_home = xdg;
    else if (auto const* home = getenv("HOME"); home && *home)
        data_home = ByteString::formatted("{}/.local/share", home);
    else
        data_home = "/tmp";
    return ByteString::formatted("{}/webby/passkeys.json", data_home);
}

static void make_directories(ByteString const& directory)
{
    auto parts = directory.split_view('/');
    StringBuilder path;
    for (auto part : parts) {
        path.append('/');
        path.append(part);
        auto string = path.to_byte_string();
        if (mkdir(string.characters(), 0700) < 0 && errno != EEXIST)
            return;
    }
}

static OwnPtr<CredentialStore> s_credential_store;

CredentialStore& credential_store()
{
    if (!s_credential_store)
        s_credential_store = make<FileCredentialStore>();
    return *s_credential_store;
}

void set_credential_store(NonnullOwnPtr<CredentialStore> store)
{
    s_credential_store = move(store);
}

FileCredentialStore::FileCredentialStore()
    : m_path(passkeys_path())
{
    auto* file = fopen(m_path.characters(), "r");
    if (!file)
        return;
    ByteBuffer contents;
    char buffer[4096];
    size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), file)) > 0)
        contents.append(buffer, count);
    fclose(file);

    auto json = JsonValue::from_string(StringView { contents.bytes() });
    if (json.is_error() || !json.value().is_object()) {
        warnln("webby: Ignoring unreadable passkey store {}", m_path);
        return;
    }
    auto passkeys = json.value().as_object().get_array("passkeys"sv);
    if (!passkeys.has_value())
        return;
    passkeys->for_each([&](JsonValue const& value) {
        if (!value.is_object())
            return;
        auto const& object = value.as_object();
        Passkey passkey;
        passkey.credential_id = string_member(object, "credentialId"sv);
        passkey.rp_id = string_member(object, "rpId"sv);
        passkey.user_id = string_member(object, "userId"sv);
        passkey.user_name = string_member(object, "userName"sv);
        passkey.user_display_name = string_member(object, "userDisplayName"sv);
        passkey.private_key = string_member(object, "privateKey"sv);
        passkey.created_at = object.get_integer<i64>("createdAt"sv).value_or(0);
        if (passkey.credential_id.is_empty() || passkey.rp_id.is_empty() || passkey.private_key.is_empty())
            return;
        m_passkeys.append(move(passkey));
    });
}

Vector<Passkey> FileCredentialStore::list(StringView rp_id, Vector<String> const& allowed_credential_ids) const
{
    Vector<Passkey> result;
    for (auto const& passkey : m_passkeys) {
        if (passkey.rp_id != rp_id)
            continue;
        if (!allowed_credential_ids.is_empty() && !allowed_credential_ids.contains_slow(passkey.credential_id))
            continue;
        result.append(passkey);
    }
    return result;
}

Optional<Passkey> FileCredentialStore::get(StringView credential_id) const
{
    for (auto const& passkey : m_passkeys) {
        if (passkey.credential_id == credential_id)
            return passkey;
    }
    return {};
}

ErrorOr<void> FileCredentialStore::create(Passkey passkey)
{
    m_passkeys.remove_all_matching([&](Passkey const& existing) {
        return existing.rp_id == passkey.rp_id && existing.user_id == passkey.user_id;
    });
    m_passkeys.append(move(passkey));
    return save();
}

ErrorOr<void> FileCredentialStore::remove(StringView credential_id)
{
    if (!m_passkeys.remove_all_matching([&](Passkey const& passkey) { return passkey.credential_id == credential_id; }))
        return {};
    return save();
}

ErrorOr<void> FileCredentialStore::save() const
{
    JsonArray passkeys;
    for (auto const& passkey : m_passkeys) {
        JsonObject object;
        object.set("credentialId"sv, passkey.credential_id);
        object.set("rpId"sv, passkey.rp_id);
        object.set("userId"sv, passkey.user_id);
        object.set("userName"sv, passkey.user_name);
        object.set("userDisplayName"sv, passkey.user_display_name);
        object.set("privateKey"sv, passkey.private_key);
        object.set("createdAt"sv, passkey.created_at);
        passkeys.must_append(move(object));
    }
    JsonObject root;
    root.set("version"sv, 1);
    root.set("passkeys"sv, move(passkeys));
    auto contents = root.serialized();

    make_directories(LexicalPath::dirname(m_path));
    auto temporary_path = ByteString::formatted("{}.tmp", m_path);
    auto fd = open(temporary_path.characters(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0)
        return Error::from_errno(errno);
    auto bytes = contents.bytes();
    while (!bytes.is_empty()) {
        auto written = write(fd, bytes.data(), bytes.size());
        if (written < 0) {
            auto error = errno;
            close(fd);
            return Error::from_errno(error);
        }
        bytes = bytes.slice(static_cast<size_t>(written));
    }
    fsync(fd);
    close(fd);
    if (rename(temporary_path.characters(), m_path.characters()) < 0)
        return Error::from_errno(errno);
    return {};
}

}
