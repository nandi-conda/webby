/*
 * Sound for the AudioServer in this module (LocalMedia.cpp): its platform playback stream on WASI
 * (wasm/patches/0024, AudioServer/PlatformAudio.cpp) keeps the device's pace itself and hands each buffer it mixed to
 * these hooks, which queue it on latha:gui's audio output (wit/audio, latha-gui 0.8). A host without sound fails the
 * open, and the stream plays into nothing as before.
 */

#include <audio_guest.h>
#include <stddef.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

extern "C" {

int webby_audio_open(unsigned sample_rate, unsigned channels)
{
    static char const name[] = "webby";
    audio_guest_string_t stream_name { reinterpret_cast<uint8_t*>(const_cast<char*>(name)), sizeof(name) - 1 };
    uint32_t id = 0;
    audio_guest_string_t error {};
    if (!latha_gui_audio_open(sample_rate, static_cast<uint8_t>(channels), &stream_name, &id, &error)) {
        static bool warned = false;
        if (!warned)
            fprintf(stderr, "webby: no sound: %.*s\n", static_cast<int>(error.len), reinterpret_cast<char const*>(error.ptr));
        warned = true;
        audio_guest_string_free(&error);
        return 0;
    }
    return static_cast<int>(id);
}

void webby_audio_write(int id, float const* samples, size_t count)
{
    // WEBBY_AUDIO_DEBUG=1: the loudest sample of every second's worth of writes, on stderr.
    static bool const debug = getenv("WEBBY_AUDIO_DEBUG") && *getenv("WEBBY_AUDIO_DEBUG") != '0';
    if (debug) {
        static size_t written = 0;
        static float peak = 0;
        for (size_t i = 0; i < count; ++i)
            peak = fmaxf(peak, fabsf(samples[i]));
        written += count;
        if (written >= 88200) {
            fprintf(stderr, "webby: sound out %zu samples, peak %.3f\n", written, static_cast<double>(peak));
            written = 0;
            peak = 0;
        }
    }
    audio_guest_list_f32_t list { const_cast<float*>(samples), count };
    latha_gui_audio_write(static_cast<uint32_t>(id), &list);
}

void webby_audio_flush(int id) { latha_gui_audio_flush(static_cast<uint32_t>(id)); }

void webby_audio_close(int id) { latha_gui_audio_close(static_cast<uint32_t>(id)); }

}
