/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <AK/ByteBuffer.h>
#include <AK/ByteString.h>
#include <AK/Error.h>
#include <AK/Function.h>
#include <AK/Optional.h>
#include <LibURL/URL.h>

namespace WebbyUI::Network {

// The page's network, as WebContent has it (wasm/patches/0010 does the same for webby-render): RequestServer runs in
// this module over an in-memory socketpair, and the RequestClient it hands back serves LibWeb's ResourceLoader, so
// style sheets, scripts, images, fonts and fetch()es of http(s) pages go through it. Images are decoded in the module.
// The CA bundle is $WEBBY_CA_BUNDLE, or the first of the usual system bundles that exists.
ErrorOr<void> initialize();

struct Document {
    URL::URL url; // after redirects
    u32 status { 0 };
    ByteBuffer body;
    Optional<ByteString> content_type;
    Optional<ByteString> content_disposition;
};

// Fetches a page's document from RequestServer, following redirects, and calls back on a later turn of the event loop.
// The returned id can be passed to cancel(); a cancelled fetch never calls back.
u64 fetch_document(URL::URL const&, Function<void(ErrorOr<Document>)>);
void cancel(u64 id);

}
