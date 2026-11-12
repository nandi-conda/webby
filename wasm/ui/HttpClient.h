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

}
