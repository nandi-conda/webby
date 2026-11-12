/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Network.h"

#include <AK/HashMap.h>
#include <LibCore/EventLoop.h>
#include <LibCore/Promise.h>
#include <LibFileSystem/FileSystem.h>
#include <LibGfx/Bitmap.h>
#include <LibGfx/ImageFormats/ImageDecoder.h>
#include <LibHTTP/Cache/DiskCache.h>
#include <LibHTTP/HeaderList.h>
#include <LibIPC/ConnectionFromClient.h>
#include <LibIPC/Transport.h>
#include <LibRequests/Request.h>
#include <LibRequests/RequestClient.h>
#include <LibRequests/RequestControlClient.h>
#include <LibURL/Parser.h>
#include <LibWeb/Loader/ResourceLoader.h>
#include <LibWeb/Platform/ImageCodecPlugin.h>
#include <LibWebCommon/Loader/UserAgent.h>
#include <RequestServer/CURL.h>
#include <RequestServer/ConnectionFromClient.h>
#include <RequestServer/ControlConnectionFromClient.h>
#include <RequestServer/Resolver.h>
#include <RequestServer/ResourceSubstitutionMap.h>
#include <stdlib.h>

namespace RequestServer {

// Defined by RequestServer's main.cpp, which is not part of this program.
OwnPtr<ResourceSubstitutionMap> g_resource_substitution_map;

}

namespace WebbyUI::Network {

namespace {

// Images are decoded here with LibGfx's decoders: there is no ImageDecoder process. Every frame of an animation is
// decoded up front, so LibWeb never asks for more (session id 0).
class InProcessImageCodecPlugin final : public Web::Platform::ImageCodecPlugin {
public:
    virtual ~InProcessImageCodecPlugin() override = default;

    virtual NonnullRefPtr<Core::Promise<Web::Platform::DecodedImage>> decode_image(ReadonlyBytes bytes, Function<ErrorOr<void>(Web::Platform::DecodedImage&)> on_resolved, Function<void(Error&)> on_rejected) override
    {
        auto promise = Core::Promise<Web::Platform::DecodedImage>::construct();
        if (on_resolved)
            promise->on_resolution = move(on_resolved);
        if (on_rejected)
            promise->on_rejection = move(on_rejected);
        auto copy = ByteBuffer::copy(bytes);
        if (copy.is_error()) {
            promise->reject(copy.release_error());
            return promise;
        }
        // Settled on a later turn of the event loop, as an answer from ImageDecoder would be.
        Core::deferred_invoke([promise, data = copy.release_value()] {
            auto decoded = decode(data);
            if (decoded.is_error())
                promise->reject(decoded.release_error());
            else
                promise->resolve(decoded.release_value());
        });
        return promise;
    }

    virtual ErrorOr<Web::Platform::DecodedFirstFrame> decode_first_frame_synchronously(ReadonlyBytes bytes) override
    {
        auto decoder = TRY(create_decoder(bytes));
        auto frame = TRY(decoder->frame(0));
        frame.image->set_alpha_type_destructive(Gfx::AlphaType::Premultiplied);
        return Web::Platform::DecodedFirstFrame { *frame.image, color_space_of(*decoder) };
    }

    virtual void request_animation_frames(i64, u32, u32) override { }
    virtual void stop_animation_decode(i64) override { }

private:
    static ErrorOr<NonnullRefPtr<Gfx::ImageDecoder>> create_decoder(ReadonlyBytes bytes)
    {
        auto decoder = TRY(Gfx::ImageDecoder::try_create_for_raw_bytes(bytes));
        if (!decoder || decoder->frame_count() == 0)
            return Error::from_string_literal("No image decoder for this data");
        return decoder.release_nonnull();
    }

    static Gfx::ColorSpace color_space_of(Gfx::ImageDecoder& decoder)
    {
        auto color_space = decoder.color_space();
        return color_space.is_error() ? Gfx::ColorSpace {} : color_space.release_value();
    }

    static ErrorOr<Web::Platform::DecodedImage> decode(ReadonlyBytes bytes)
    {
        auto decoder = TRY(create_decoder(bytes));
        Web::Platform::DecodedImage result;
        result.is_animated = decoder->is_animated();
        result.loop_count = decoder->loop_count();
        result.color_space = color_space_of(*decoder);
        for (size_t i = 0; i < decoder->frame_count(); ++i) {
            auto frame = decoder->frame(i);
            if (frame.is_error())
                break;
            auto descriptor = frame.release_value();
            descriptor.image->set_alpha_type_destructive(Gfx::AlphaType::Premultiplied);
            result.all_durations.append(descriptor.duration);
            result.frames.append({ descriptor.image, static_cast<size_t>(descriptor.duration) });
        }
        if (result.frames.is_empty())
            return Error::from_string_literal("Could not decode image");
        result.frame_count = result.frames.size();
        return result;
    }
};

// RequestServer's side, in this module, and the clients that reach it.
struct State {
    AK_ALLOC_WITH_KMALLOC;

    RequestServer::ConnectionFromClient::ConnectionMap connections;
    RequestServer::ConnectionFromClient::RequestTransferLeaseMap request_transfer_leases;
    Optional<HTTP::DiskCache> disk_cache;
    RefPtr<RequestServer::ControlConnectionFromClient> server;
    RefPtr<Requests::RequestControlClient> control;
    RefPtr<Requests::RequestClient> client;

    struct Fetch {
        AK_ALLOC_WITH_KMALLOC;

        URL::URL url;
        int redirects { 0 };
        RefPtr<Requests::Request> request;
        Function<void(ErrorOr<Document>)> on_done;
    };
    HashMap<u64, NonnullOwnPtr<Fetch>> fetches;
    u64 next_fetch_id { 1 };
};

State* s_state;

Optional<ByteString> ca_bundle()
{
    if (auto const* path = getenv("WEBBY_CA_BUNDLE"); path && *path)
        return ByteString { path };
    for (auto path : { "/etc/ssl/certs/ca-certificates.crt"sv, "/etc/pki/tls/certs/ca-bundle.crt"sv, "/etc/ssl/cert.pem"sv,
             "/etc/ca-certificates/extracted/tls-ca-bundle.pem"sv }) {
        if (FileSystem::exists(path))
            return ByteString { path };
    }
    return {};
}

void start(u64 id);

void finish(u64 id, ErrorOr<Document> result)
{
    // Not from inside RequestClient's callback: the caller may start the next fetch or tear things down. The fetch
    // stays in the map until then, so a cancel() in between still keeps it from calling back.
    Core::deferred_invoke([id, result = move(result)]() mutable {
        auto fetch = s_state ? s_state->fetches.take(id) : Optional<NonnullOwnPtr<State::Fetch>> {};
        if (fetch.has_value())
            (*fetch)->on_done(move(result));
    });
}

void start(u64 id)
{
    auto it = s_state->fetches.find(id);
    if (it == s_state->fetches.end())
        return;
    auto& fetch = *it->value;
    auto headers = HTTP::HeaderList::create();
    headers->append(HTTP::Header::isomorphic_encode("User-Agent"sv, Web::default_user_agent));
    headers->append(HTTP::Header::isomorphic_encode("Accept"sv, "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"sv));
    headers->append(HTTP::Header::isomorphic_encode("Accept-Language"sv, "en-US,en;q=0.9"sv));
    fetch.request = s_state->client->start_request("GET"sv, fetch.url, *headers);
    if (!fetch.request) {
        finish(id, Error::from_string_literal("RequestServer did not start the request"));
        return;
    }
    fetch.request->set_buffered_request_finished_callback(
        [id](u64, Requests::RequestTimingInfo const&, Optional<Requests::NetworkError> const& network_error,
            NonnullRefPtr<HTTP::HeaderList> headers, Optional<u32> response_code, Optional<String>, Optional<Core::ImmutableBytes>,
            Optional<u64>, Requests::CacheState, Core::ImmutableBytes payload) {
            auto it = s_state->fetches.find(id);
            if (it == s_state->fetches.end())
                return;
            auto& fetch = *it->value;
            if (network_error.has_value()) {
                finish(id, Error::from_string_view(Requests::network_error_to_string(*network_error)));
                return;
            }
            if (!response_code.has_value()) {
                finish(id, Error::from_string_literal("No HTTP status"));
                return;
            }
            auto status = *response_code;
            if (status >= 300 && status < 400 && status != 304) {
                auto location = headers->get("Location"sv);
                auto next = location.has_value() ? URL::Parser::basic_parse(*location, fetch.url) : Optional<URL::URL> {};
                if (!next.has_value()) {
                    finish(id, Error::from_string_literal("A redirect to something that is not a URL"));
                    return;
                }
                if (++fetch.redirects > 20) {
                    finish(id, Error::from_string_literal("Too many redirects"));
                    return;
                }
                fetch.url = next.release_value();
                Core::deferred_invoke([id] { start(id); });
                return;
            }
            auto body = ByteBuffer::copy(payload.bytes());
            if (body.is_error()) {
                finish(id, body.release_error());
                return;
            }
            finish(id, Document { fetch.url, status, body.release_value(), headers->get("Content-Type"sv), headers->get("Content-Disposition"sv) });
        });
}

}

ErrorOr<void> initialize()
{
    if (s_state)
        return {};
    Web::Platform::ImageCodecPlugin::install(*new InProcessImageCodecPlugin);

    auto state = make<State>();
    if (auto bundle = ca_bundle(); bundle.has_value())
        RequestServer::set_default_certificate_path(*bundle);
    else
        warnln("webby: no CA bundle found (set WEBBY_CA_BUNDLE); https pages will fail");
    TRY(RequestServer::initialize_libcurl());
    auto [local, remote_handle] = TRY(IPC::Transport::create_paired());
    state->server = IPC::new_client_connection<RequestServer::ControlConnectionFromClient>(
        TRY(remote_handle.create_transport()), state->connections, state->request_transfer_leases, state->disk_cache);
    state->control = adopt_ref(*new Requests::RequestControlClient(move(local)));
    state->control->on_request_server_died = [] { warnln("webby: RequestServer went away"); };

    // A synchronous request: the answer only comes once RequestServer's side has run.
    auto response = state->control->send_sync_but_allow_failure<Messages::RequestServerControl::ConnectNewClient>(RequestServer::IsPrivate::No, RequestServer::SiteBinding::Unrestricted);
    if (!response || response->client_id() < 0)
        return Error::from_string_literal("RequestServer's connect_new_client failed");
    state->client = TRY(try_make_ref_counted<Requests::RequestClient>(TRY(response->take_handle().create_transport()), response->client_id()));
    Web::ResourceLoader::the().set_client({}, *state->client);
    s_state = state.leak_ptr();
    return {};
}

u64 fetch_document(URL::URL const& url, Function<void(ErrorOr<Document>)> on_done)
{
    if (!s_state) {
        Core::deferred_invoke([on_done = move(on_done)] { on_done(Error::from_string_literal("The network did not start")); });
        return 0;
    }
    auto id = s_state->next_fetch_id++;
    auto fetch = make<State::Fetch>();
    fetch->url = url;
    fetch->on_done = move(on_done);
    s_state->fetches.set(id, move(fetch));
    start(id);
    return id;
}

void cancel(u64 id)
{
    if (!s_state)
        return;
    if (auto fetch = s_state->fetches.take(id); fetch.has_value() && (*fetch)->request)
        (void)(*fetch)->request->stop();
}

}
