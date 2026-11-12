/*
 * <video>, <audio> and Web Audio in the module itself: Ladybird's MediaServer and AudioServer run here, as they run
 * in processes of their own natively, connected over in-memory IPC transports. This file is the part of the Browser
 * (LibWebView's HelperProcess) that brokers their connections, and the part of the Compositor that draws video:
 *
 *  - MediaServer's controller connection is ours. LibMediaClient's transport factory asks it for a renderer
 *    connection (connect_new_client) and gives that renderer a video presentation channel, whose client end
 *    (VideoPresentationClientConnection) lives here and turns each video sink handle into a DisplayingVideoSink.
 *  - AudioServer's control connection is ours too. Every client (MediaServer's playback streams, the page's Web Audio)
 *    gets a connection of one tab whose playback group 1 is authorized. With no platform audio backend the mix plays
 *    into a null stream that keeps the device's pace, which is the clock video plays to.
 *  - Paint resolves the video sinks the display list draws, as the Compositor does, and a timer updates them
 *    (DisplayingVideoSink::update picks the frame for now) and asks for a paint when one has a new frame.
 *
 * MediaServer's sessions decode on worker threads: the cooperative threads of coop/Coop.cpp, which run while the
 * event loop waits.
 */

#include "LocalMedia.h"

#include <AK/HashMap.h>
#include <AK/HashTable.h>
#include <AK/NeverDestroyed.h>
#include <AK/Time.h>
#include <AudioServer/AudioServerControlClientEndpoint.h>
#include <AudioServer/AudioServerControlEndpoint.h>
#include <AudioServer/ControlConnection.h>
#include <AudioServer/Tabs.h>
#include <LibAudio/ClientConnection.h>
#include <LibAudio/PlaybackGroupId.h>
#include <LibCompositing/DisplayList/DisplayListResourceStorage.h>
#include <LibCore/Timer.h>
#include <LibIPC/ConnectionToServer.h>
#include <LibIPC/Transport.h>
#include <LibIPC/TransportHandle.h>
#include <LibMedia/DecoderRegistrations.h>
#include <LibMedia/Sinks/DisplayingVideoSink.h>
#include <LibMedia/VideoPresentation/VideoPresentationClientConnection.h>
#include <LibMediaClient/Client.h>
#include <LibMediaCodecs/AudioDecoderRegistry.h>
#include <LibMediaCodecs/VideoDecoderRegistry.h>
#include <MediaServer/ConnectionFromClient.h>

extern "C" __attribute__((weak)) int webby_coop_available();

namespace WebbyUI::LocalMedia {

namespace {

// The Browser's end of AudioServer's control connection.
class AudioControl final
    : public IPC::ConnectionToServer<AudioServerControlClientEndpoint, AudioServerControlEndpoint>
    , public AudioServerControlClientEndpoint {
    C_OBJECT(AudioControl);

private:
    explicit AudioControl(NonnullOwnPtr<IPC::Transport> transport)
        : IPC::ConnectionToServer<AudioServerControlClientEndpoint, AudioServerControlEndpoint>(*this, move(transport))
    {
    }

    virtual void die() override { warnln("webby: AudioServer's control connection went away"); }
    // No microphone in wasm webby: every capture request is refused.
    virtual void capture_requested(u64, u64 request_id, ByteString) override { async_capture_decided(request_id, false); }
    virtual void playback_group_audibility_changed(u64, Audio::PlaybackGroupId, Audio::Audibility) override { }
};

constexpr u64 AUDIO_TAB_ID = 1;
constexpr Audio::PlaybackGroupId PLAYBACK_GROUP { 1 };

struct State {
    RefPtr<AudioServer::ControlConnection> audio_server;
    RefPtr<AudioControl> audio_control;
    RefPtr<MediaServer::ConnectionFromClient> media_server;
    RefPtr<MediaClient::Client> media_control;
    RefPtr<Media::VideoPresentationClientConnection> presentation;

    struct Sink {
        RefPtr<Media::DisplayingVideoSink> sink;
        MonotonicTime last_drawn;
    };
    HashMap<Media::VideoSinkHandle, Sink> sinks;
    RefPtr<Core::Timer> update_timer;
    Function<void()> on_new_frame;
};

State& state()
{
    static NeverDestroyed<State> s_state;
    return *s_state;
}

bool s_available = false;

// How long a sink stays after the display list last drew it (a video scrolled out of view and back keeps its edge).
constexpr auto SINK_LINGER = AK::Duration::from_seconds(10);

ErrorOr<IPC::TransportHandle> connect_audio_client()
{
    auto& s = state();
    auto response = s.audio_control->send_sync_but_allow_failure<Messages::AudioServerControl::ConnectNewClient>(AUDIO_TAB_ID);
    if (!response || !response->handle().has_value())
        return Error::from_string_literal("AudioServer did not connect a client");
    return response->take_handle().release_value();
}

void update_sinks()
{
    auto& s = state();
    auto now = MonotonicTime::now();
    bool new_frame = false;
    bool keep_ticking = false;
    Vector<Media::VideoSinkHandle> stale;
    for (auto& entry : s.sinks) {
        auto& sink = entry.value;
        if (!sink.sink)
            continue;
        if (now - sink.last_drawn > SINK_LINGER) {
            stale.append(entry.key);
            continue;
        }
        auto result = sink.sink->update(now);
        new_frame |= result.new_frame_available;
        keep_ticking |= result.may_require_updates;
    }
    for (auto handle : stale) {
        s.sinks.remove(handle);
        if (s.presentation)
            s.presentation->release_edge(handle);
    }
    if (new_frame && s.on_new_frame)
        s.on_new_frame();
    if (!keep_ticking && s.update_timer)
        s.update_timer->stop();
}

void start_updates()
{
    auto& s = state();
    if (!s.update_timer)
        s.update_timer = Core::Timer::create_repeating(AK::Duration::from_milliseconds(8), [] { update_sinks(); });
    if (!s.update_timer->is_active())
        s.update_timer->start();
}

}

bool is_available() { return s_available; }

void set_new_frame_handler(Function<void()> handler) { state().on_new_frame = move(handler); }

ErrorOr<void> initialize()
{
    // Without cooperative threads MediaServer's decoders would run their loops inline, forever.
    if (!&webby_coop_available)
        return Error::from_string_literal("this build has no threads for media");
    auto& s = state();

    Media::install_video_decoders({ Media::ffmpeg_video_decoders() });
    Media::install_audio_decoders({ Media::audio_decoders() });

    // AudioServer: its control connection, and one tab whose playback group plays.
    {
        auto [local, remote_handle] = TRY(IPC::Transport::create_paired());
        s.audio_server = AudioServer::ControlConnection::construct(move(local));
        AudioServer::Tabs::the().set_control_connection(*s.audio_server);
        s.audio_control = AudioControl::construct(TRY(remote_handle.create_transport()));
        (void)s.audio_control->send_sync_but_allow_failure<Messages::AudioServerControl::AuthorizePlaybackGroup>(AUDIO_TAB_ID, PLAYBACK_GROUP);
    }
    // Every LibAudio client in the module (MediaServer's sessions, the page's AudioContexts) connects as that tab.
    Audio::ClientConnection::set_transport_factory([]() -> ErrorOr<NonnullOwnPtr<IPC::Transport>> {
        auto handle = TRY(connect_audio_client());
        return handle.create_transport();
    });

    // MediaServer: the controller connection.
    {
        auto [local, remote_handle] = TRY(IPC::Transport::create_paired());
        s.media_server = MediaServer::ConnectionFromClient::construct(move(local), MediaServer::ConnectionFromClient::Role::Controller);
        s.media_control = TRY(try_make_ref_counted<MediaClient::Client>(TRY(remote_handle.create_transport())));
        s.media_control->on_request_audio_server_connection = [] { return connect_audio_client(); };
        // No hardware decoders: FFmpeg decodes in MediaServer itself.
        s.media_control->on_request_video_decoder_server_connection = [](auto answer) {
            answer(Error::from_string_literal("wasm webby has no video decoder server"));
        };
    }

    // The renderer's connection, which LibMediaClient asks for when a page first plays media (and again after it
    // dropped an idle one), with its video presentation channel.
    MediaClient::Client::set_transport_factory([]() -> ErrorOr<NonnullOwnPtr<IPC::Transport>> {
        auto& s = state();
        auto response = s.media_control->send_sync_but_allow_failure<Messages::MediaServer::ConnectNewClient>();
        if (!response || !response->handle().has_value())
            return Error::from_string_literal("MediaServer did not connect a client");
        auto client_id = response->client_id();
        auto transport = TRY(response->take_handle()->create_transport());

        auto [local, remote_handle] = TRY(IPC::Transport::create_paired());
        s.media_control->async_connect_video_presentation_channel(client_id, move(remote_handle));
        s.presentation = TRY(try_make_ref_counted<Media::VideoPresentationClientConnection>(move(local)));
        // Edges of the previous connection's channel are gone with it.
        s.sinks.clear();
        return transport;
    });

    s_available = true;
    return {};
}

void resolve_video_sinks(Compositing::DisplayListResourceStorage& resources)
{
    auto& s = state();
    if (!s_available)
        return;
    auto now = MonotonicTime::now();
    for (auto const& entry : resources.video_sink_handles()) {
        auto handle = entry.value;
        auto existing = s.sinks.find(handle);
        if (existing != s.sinks.end()) {
            existing->value.last_drawn = now;
            if (existing->value.sink)
                resources.set_video_sink(Compositing::VideoSinkResourceId { entry.key }, existing->value.sink);
            continue;
        }
        if (!s.presentation)
            continue;
        s.sinks.set(handle, { nullptr, now });
        auto result = s.presentation->create_edge(handle, [handle](NonnullRefPtr<Media::DisplayingVideoSink> sink) {
            auto& s = state();
            auto it = s.sinks.find(handle);
            if (it == s.sinks.end())
                return;
            it->value.sink = sink;
            sink->set_on_present_needed([] {
                start_updates();
            });
            start_updates();
            if (s.on_new_frame)
                s.on_new_frame();
        });
        if (result.is_error()) {
            warnln("webby: no video edge for sink {}: {}", handle.value(), result.error());
            s.sinks.remove(handle);
        }
    }
}

}
