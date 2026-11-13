/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "WebAuthn.h"

#include <AK/JsonArray.h>
#include <AK/JsonObject.h>
#include <AK/JsonValue.h>
#include <AK/Vector.h>
#include <Authenticator.h>

namespace WebbyUI {

static std::string to_std(String const& s)
{
    auto bytes = s.bytes_as_string_view();
    return std::string(bytes.characters_without_null_termination(), bytes.length());
}

struct WebAuthnFlow::Pending {
    uint64_t request_id { 0 };
    JsonObject request;
    Vector<Webby::Passkey> accounts;
    bool already_registered { false };
};

WebAuthnFlow::WebAuthnFlow() = default;

WebAuthnFlow::~WebAuthnFlow()
{
    cancel();
}

bool WebAuthnFlow::waiting() const { return m_pending != nullptr; }

static Vector<String> webauthn_strings(JsonObject const& object, StringView key)
{
    Vector<String> strings;
    if (auto array = object.get_array(key); array.has_value()) {
        array->for_each([&](JsonValue const& value) {
            if (value.is_string())
                strings.append(value.as_string());
        });
    }
    return strings;
}

static String webauthn_string(JsonObject const& object, StringView key)
{
    if (auto value = object.get_string(key); value.has_value())
        return *value;
    return {};
}

// As the Nim desktop's native/WebbyView.cpp handle_webauthn_request: the prompt for the UI, with the passkeys that fit.
void WebAuthnFlow::request(uint64_t request_id, std::string const& request_json, bool can_prompt)
{
    auto send = [&](String const& json) {
        if (reply)
            reply(request_id, to_std(json));
    };
    auto parsed = JsonValue::from_string(StringView { request_json.data(), request_json.size() });
    if (parsed.is_error() || !parsed.value().is_object()) {
        send(Webby::error_reply("UnknownError"sv, "Malformed request"sv));
        return;
    }
    if (m_pending || !can_prompt) {
        send(Webby::error_reply("NotAllowedError"sv, "Another passkey request is waiting for the user"sv));
        return;
    }
    auto request = move(parsed.value().as_object());
    auto type = webauthn_string(request, "type"sv);
    auto rp_id = webauthn_string(request, "rpId"sv);
    auto pending = std::make_unique<Pending>();
    pending->request_id = request_id;
    JsonObject prompt_json;
    prompt_json.set("type"sv, type);
    prompt_json.set("rpId"sv, rp_id);
    prompt_json.set("origin"sv, webauthn_string(request, "origin"sv));
    if (type == "create"sv) {
        bool supports_es256 = false;
        if (auto algorithms = request.get_array("algorithms"sv); algorithms.has_value()) {
            algorithms->for_each([&](JsonValue const& value) {
                if (value.get_i64() == -7)
                    supports_es256 = true;
            });
        }
        if (!supports_es256) {
            send(Webby::error_reply("NotSupportedError"sv, "This browser's passkeys only support ES256"sv));
            return;
        }
        // An empty exclude list means "exclude nothing", not "any passkey for this site".
        if (auto excluded = webauthn_strings(request, "excludeCredentials"sv); !excluded.is_empty())
            pending->already_registered = !Webby::credential_store().list(rp_id, excluded).is_empty();
        prompt_json.set("rpName"sv, webauthn_string(request, "rpName"sv));
        prompt_json.set("userName"sv, webauthn_string(request, "userName"sv));
        prompt_json.set("userDisplayName"sv, webauthn_string(request, "userDisplayName"sv));
        prompt_json.set("alreadyRegistered"sv, pending->already_registered);
    } else if (type == "get"sv) {
        pending->accounts = Webby::credential_store().list(rp_id, webauthn_strings(request, "allowCredentials"sv));
        JsonArray accounts;
        for (auto const& passkey : pending->accounts) {
            JsonObject account;
            account.set("userName"sv, passkey.user_name);
            account.set("userDisplayName"sv, passkey.user_display_name);
            account.set("createdAt"sv, passkey.created_at);
            accounts.must_append(move(account));
        }
        prompt_json.set("accounts"sv, move(accounts));
    } else {
        send(Webby::error_reply("NotSupportedError"sv, "Unknown request"sv));
        return;
    }
    pending->request = move(request);
    m_pending = std::move(pending);
    auto text = prompt_json.serialized().to_byte_string();
    if (prompt)
        prompt(std::string(text.characters(), text.length()));
}

void WebAuthnFlow::respond(bool accepted, int account_index)
{
    if (!m_pending)
        return;
    auto pending = std::move(m_pending);
    String answer;
    auto type = webauthn_string(pending->request, "type"sv);
    if (!accepted) {
        answer = Webby::error_reply("NotAllowedError"sv, "The user cancelled the request"sv);
    } else if (type == "create"sv) {
        // https://w3c.github.io/webauthn/#sctn-op-make-cred step 3: after the user consents, report that one of the
        // excluded credentials is already here.
        if (pending->already_registered)
            answer = Webby::error_reply("InvalidStateError"sv, "A passkey for this account already exists in this browser"sv);
        else
            answer = Webby::make_credential(pending->request);
    } else if (account_index < 0 || static_cast<size_t>(account_index) >= pending->accounts.size()) {
        answer = Webby::error_reply("NotAllowedError"sv, "No passkey was chosen"sv);
    } else {
        answer = Webby::get_assertion(pending->request, pending->accounts[account_index]);
    }
    if (reply)
        reply(pending->request_id, to_std(answer));
}

void WebAuthnFlow::cancel()
{
    if (m_pending)
        respond(false, -1);
}

}
