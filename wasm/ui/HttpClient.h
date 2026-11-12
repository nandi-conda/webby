/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Plain HTTP requests for the chrome's own features (sync), through the module's RequestServer (Network.h). Only std
// types, so Qt code can call it without meeting Ladybird's headers. Callbacks come on a later turn of the event loop.

#pragma once

#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace WebbyUI::Http {

using Headers = std::vector<std::pair<std::string, std::string>>;

struct Response {
    int status { 0 };      // 0: no answer (see error)
    std::string reason;
    Headers headers;
    std::string body;
    std::string error;     // why there is no answer
    // The first header of that name (any case), or "".
    std::string header(std::string const& name) const;
};

// No redirects are followed, no cookies sent, nothing cached.
void request(std::string const& method, std::string const& url, Headers const& headers, std::string const& body,
    std::function<void(Response)> on_done);

// The same, with the body handed over as it arrives (server-sent events: Summarize's chat completions). `on_headers`
// gets the status and headers first, `on_data` each piece of the body, then `on_done` once: "" when the body is
// complete, else why it is not. Nothing is called after cancel(id). Callbacks come on a later turn of the event loop.
using StreamId = unsigned long long;
StreamId stream(std::string const& method, std::string const& url, Headers const& headers, std::string const& body,
    std::function<void(int status, Headers const&)> on_headers, std::function<void(std::string const&)> on_data,
    std::function<void(std::string const& error)> on_done);
void cancel(StreamId);

}
