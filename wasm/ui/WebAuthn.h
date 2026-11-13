/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// A page's Web Authentication request (passkeys, ../../patches/0002), from the page's JSON to the reply: the prompt
// for the user (as the Nim front end's dialog gets it), the passkeys that fit from this instance's credential store,
// and the signed reply. EngineView runs one when the chrome is in the same instance; when the engine runs in a worker
// (EngineWorker.h) the chrome's WebView runs it, so passkeys come from the chrome's store (the vault).

#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace WebbyUI {

class WebAuthnFlow {
public:
    WebAuthnFlow();
    ~WebAuthnFlow();

    // The reply for the page's request (JSON), and the prompt for the user.
    std::function<void(uint64_t request_id, std::string const& reply)> reply;
    std::function<void(std::string const& prompt)> prompt;

    // A new request; `can_prompt` false (no one to ask) refuses it.
    void request(uint64_t request_id, std::string const& request_json, bool can_prompt);
    // The user's answer to the prompt: whether they agreed and, for "get", which account.
    void respond(bool accepted, int account_index);
    // Refuses the waiting request, if any (the view is going away).
    void cancel();
    bool waiting() const;

private:
    struct Pending;
    std::unique_ptr<Pending> m_pending;
};

}
