/*
 * <video>, <audio> and Web Audio in the module itself (LocalMedia.cpp): Ladybird's MediaServer and AudioServer run
 * here, over in-memory IPC, as RequestServer does (Network.cpp). Their worker threads are the cooperative threads of
 * coop/Coop.cpp.
 */

#pragma once

#include <AK/Error.h>
#include <AK/Function.h>
#include <AK/RefPtr.h>
#include <LibMedia/Forward.h>
#include <LibMedia/VideoSinkHandle.h>

namespace Compositing {
class DisplayListResourceStorage;
}

namespace WebbyUI::LocalMedia {

// Installs the decoders, starts the servers and points LibMediaClient and LibAudio at them.
ErrorOr<void> initialize();
bool is_available();

// Gives the frame's resources the video sinks its display list draws (as the Compositor resolves them). A sink seen
// for the first time is asked for from MediaServer; it draws once its first frame has come.
void resolve_video_sinks(Compositing::DisplayListResourceStorage&);

// Called whenever a video has a new frame to show.
void set_new_frame_handler(Function<void()>);

}
