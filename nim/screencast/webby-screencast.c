// webby-screencast: the screen recorder behind webby's navigator.mediaDevices.getDisplayMedia() and MediaRecorder
// (nim/src/features/site/screencapture.nim, which starts one of these per shared screen).
//
// On Wayland it asks the desktop's ScreenCast portal for a screen or window (the desktop shows its own picker) and
// reads the frames from PipeWire; on X11 (--x11) it grabs the whole screen with ximagesrc. Each recording is
// encoded with GStreamer to WebM (VP8, plus Opus when audio is asked for: the desktop's sound and/or the default
// microphone, through PulseAudio or pipewire-pulse).
//
// stdin, one command per line:  start <system-audio 0|1> <microphone 0|1>,  pause,  resume,  stop.  EOF quits.
// stdout, framed:  READY <width> <height> <monitor|window>\n   the screen is shared (once)
//                  DATA <n>\n<n bytes>                           more of the current recording's WebM
//                  STOPPED\n                                     the current recording is complete
//                  ENDED\n                                       the sharing ended (portal closed, stream gone)
//                  CANCELLED\n                                   the user declined in the portal's picker
//                  ERROR <text>\n
// Diagnostics go to stderr.

#define _GNU_SOURCE  // dladdr
#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <glib-unix.h>
#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/buffers.h>
#include <X11/Xlib.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_WIDTH 1920

static GMainLoop *loop;
static GMutex out_lock;
static gboolean use_x11;
static int src_width, src_height;   // the shared screen or window, as last known
static const char *surface = "monitor";
static gboolean ready_sent, ended;

// The current recording.
static GstElement *pipeline, *appsrc;
static gboolean recording, stopping;
static guint stop_timeout;

// ---------------------------------------------------------------------------------------------------------------
// Output

static void write_all(const void *data, size_t n) {
  const char *p = data;
  while (n > 0) {
    ssize_t w = write(1, p, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      _exit(0);   // webby went away
    }
    p += w;
    n -= (size_t)w;
  }
}

static void out_line(const char *fmt, ...) G_GNUC_PRINTF(1, 2);
static void out_line(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  char *s = g_strdup_vprintf(fmt, ap);
  va_end(ap);
  g_mutex_lock(&out_lock);
  write_all(s, strlen(s));
  write_all("\n", 1);
  g_mutex_unlock(&out_lock);
  g_free(s);
}

static void out_data(const guint8 *data, gsize n) {
  char head[32];
  int len = snprintf(head, sizeof head, "DATA %zu\n", n);
  g_mutex_lock(&out_lock);
  write_all(head, (size_t)len);
  write_all(data, n);
  g_mutex_unlock(&out_lock);
}

static void send_ready(void) {
  if (ready_sent) return;
  ready_sent = TRUE;
  out_line("READY %d %d %s", src_width, src_height, surface);
}

static gboolean quit_idle(gpointer data) {
  (void)data;
  g_main_loop_quit(loop);
  return G_SOURCE_REMOVE;
}

static void stop_recording(void);

static gboolean end_sharing(gpointer data) {
  (void)data;
  if (ended) return G_SOURCE_REMOVE;
  ended = TRUE;
  if (recording) stop_recording();
  out_line("ENDED");
  return G_SOURCE_REMOVE;
}

static void fail(const char *what) {
  fprintf(stderr, "webby-screencast: %s\n", what);
  out_line("ERROR %s", what);
  g_idle_add(quit_idle, NULL);
}

// ---------------------------------------------------------------------------------------------------------------
// Frames from PipeWire (the portal's stream), handed to the recording's appsrc. The latest frame is kept so a
// still screen (a compositor sends frames only when something changes) still fills the video's time.

static struct pw_thread_loop *pw_loop;
static struct pw_stream *pw_stream;
static struct spa_hook stream_listener;
static uint32_t pw_format;
static int pw_width, pw_height;
static gboolean pw_streaming;
static GMutex frame_lock;
static GstBuffer *last_frame;
static GstCaps *frame_caps;
static gboolean frame_caps_changed;
static gint64 last_push;

static const char *gst_format(uint32_t f) {
  switch (f) {
  case SPA_VIDEO_FORMAT_BGRA: return "BGRA";
  case SPA_VIDEO_FORMAT_RGBx: return "RGBx";
  case SPA_VIDEO_FORMAT_RGBA: return "RGBA";
  default: return "BGRx";
  }
}

// Pushes `frame` (a reference is taken) into the recording when it runs. Called with frame_lock held.
static void push_frame_locked(GstBuffer *frame) {
  if (!appsrc || stopping) return;
  if (frame_caps_changed) {
    gst_app_src_set_caps(GST_APP_SRC(appsrc), frame_caps);
    frame_caps_changed = FALSE;
  }
  // appsrc stamps the time on the buffer it gets, so the kept frame goes in as a copy (sharing its memory).
  gst_app_src_push_buffer(GST_APP_SRC(appsrc), gst_buffer_copy(frame));
  last_push = g_get_monotonic_time();
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
  (void)data;
  if (param == NULL || id != SPA_PARAM_Format) return;
  uint32_t media_type, media_subtype;
  if (spa_format_parse(param, &media_type, &media_subtype) < 0) return;
  if (media_type != SPA_MEDIA_TYPE_video || media_subtype != SPA_MEDIA_SUBTYPE_raw) return;
  struct spa_video_info_raw info;
  if (spa_format_video_raw_parse(param, &info) < 0) return;
  pw_format = info.format;
  pw_width = (int)info.size.width;
  pw_height = (int)info.size.height;
  fprintf(stderr, "webby-screencast: stream format %s %dx%d\n", gst_format(pw_format), pw_width, pw_height);
  g_mutex_lock(&frame_lock);
  if (frame_caps) gst_caps_unref(frame_caps);
  frame_caps = gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING, gst_format(pw_format),
    "width", G_TYPE_INT, pw_width, "height", G_TYPE_INT, pw_height, "framerate", GST_TYPE_FRACTION, 0, 1, NULL);
  frame_caps_changed = TRUE;
  g_mutex_unlock(&frame_lock);

  // Buffers in memory we can map (no DMA-BUF: no modifiers were offered, so the compositor uses shared memory).
  uint8_t buffer[256];
  struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof buffer);
  const struct spa_pod *params[1];
  params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
    SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd)));
  pw_stream_update_params(pw_stream, params, 1);
}

static void on_process(void *data) {
  (void)data;
  struct pw_buffer *b = pw_stream_dequeue_buffer(pw_stream);
  if (b == NULL) return;
  struct spa_data *d = &b->buffer->datas[0];
  if (d->data != NULL && d->chunk->size > 0 && !(d->chunk->flags & SPA_CHUNK_FLAG_CORRUPTED) && pw_width > 0) {
    int row = pw_width * 4;
    int stride = d->chunk->stride > 0 ? d->chunk->stride : row;
    if ((gsize)stride * (gsize)(pw_height - 1) + (gsize)row <= d->chunk->size) {
      GstBuffer *frame = gst_buffer_new_allocate(NULL, (gsize)row * (gsize)pw_height, NULL);
      GstMapInfo map;
      gst_buffer_map(frame, &map, GST_MAP_WRITE);
      const guint8 *src = (const guint8 *)d->data + d->chunk->offset;
      for (int y = 0; y < pw_height; y++) memcpy(map.data + (gsize)y * row, src + (gsize)y * stride, (size_t)row);
      gst_buffer_unmap(frame, &map);
      g_mutex_lock(&frame_lock);
      if (last_frame) gst_buffer_unref(last_frame);
      last_frame = frame;
      push_frame_locked(frame);
      g_mutex_unlock(&frame_lock);
    }
  }
  pw_stream_queue_buffer(pw_stream, b);
}

static void on_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
  (void)data;
  (void)old;
  fprintf(stderr, "webby-screencast: stream %s%s%s\n", pw_stream_state_as_string(state), error ? ": " : "",
    error ? error : "");
  if (state == PW_STREAM_STATE_STREAMING) pw_streaming = TRUE;
  if (state == PW_STREAM_STATE_ERROR || (state == PW_STREAM_STATE_UNCONNECTED && pw_streaming))
    g_idle_add(end_sharing, NULL);
}

static const struct pw_stream_events stream_events = {
  PW_VERSION_STREAM_EVENTS,
  .state_changed = on_state_changed,
  .param_changed = on_param_changed,
  .process = on_process,
};

static gboolean repeat_frame(gpointer data) {
  (void)data;
  g_mutex_lock(&frame_lock);
  if (last_frame && g_get_monotonic_time() - last_push > 200000) push_frame_locked(last_frame);
  g_mutex_unlock(&frame_lock);
  return G_SOURCE_CONTINUE;
}

static void start_pipewire(int fd, uint32_t node) {
  pw_init(NULL, NULL);
  pw_loop = pw_thread_loop_new("webby-screencast", NULL);
  struct pw_context *context = pw_context_new(pw_thread_loop_get_loop(pw_loop), NULL, 0);
  if (pw_thread_loop_start(pw_loop) < 0) {
    fail("PipeWire: could not start its loop");
    return;
  }
  pw_thread_loop_lock(pw_loop);
  struct pw_core *core = pw_context_connect_fd(context, fd, NULL, 0);
  if (core == NULL) {
    pw_thread_loop_unlock(pw_loop);
    fail("PipeWire: could not connect");
    return;
  }
  pw_stream = pw_stream_new(core, "webby-screencast", pw_properties_new(PW_KEY_MEDIA_TYPE, "Video",
    PW_KEY_MEDIA_CATEGORY, "Capture", PW_KEY_MEDIA_ROLE, "Screen", NULL));
  pw_stream_add_listener(pw_stream, &stream_listener, &stream_events, NULL);
  uint8_t buffer[1024];
  struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof buffer);
  const struct spa_pod *params[1];
  params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
    SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
    SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
    SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(5, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx,
      SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGBx, SPA_VIDEO_FORMAT_RGBA),
    SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&SPA_RECTANGLE(1920, 1080), &SPA_RECTANGLE(1, 1),
      &SPA_RECTANGLE(16384, 16384)),
    SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(30, 1), &SPA_FRACTION(0, 1),
      &SPA_FRACTION(60, 1)));
  if (pw_stream_connect(pw_stream, PW_DIRECTION_INPUT, node,
        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1) < 0) {
    pw_thread_loop_unlock(pw_loop);
    fail("PipeWire: could not connect the stream");
    return;
  }
  pw_thread_loop_unlock(pw_loop);
  g_timeout_add(100, repeat_frame, NULL);
}

// ---------------------------------------------------------------------------------------------------------------
// The ScreenCast portal: CreateSession, SelectSources, Start (the desktop's picker), OpenPipeWireRemote. Each of
// the first three answers through a Request object's Response signal.

#define PORTAL_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define SCREENCAST "org.freedesktop.portal.ScreenCast"

typedef void (*ResponseFn)(guint32 code, GVariant *results);

static GDBusConnection *bus;
static char *sender;     // our unique bus name as the portal writes it in request paths (":1.42" -> "1_42")
static char *session;
static int token_count;

typedef struct {
  guint sub;
  ResponseFn fn;
} Pending;

static void on_response(GDBusConnection *c, const char *from, const char *path, const char *iface,
                        const char *signal, GVariant *params, gpointer data) {
  (void)from; (void)path; (void)iface; (void)signal;
  Pending *p = data;
  g_dbus_connection_signal_unsubscribe(c, p->sub);
  guint32 code;
  GVariant *results;
  g_variant_get(params, "(u@a{sv})", &code, &results);
  p->fn(code, results);
  g_variant_unref(results);
  g_free(p);
}

// Calls `method` with `options` (handle_token is added here) and waits for the Response in the main loop.
// `session_path` and `parent` lead the arguments when given (SelectSources takes the session, Start both).
static void portal_request(const char *method, const char *session_path, const char *parent, GVariantBuilder *options,
                           ResponseFn fn) {
  char *token = g_strdup_printf("webby%d_%d", getpid(), ++token_count);
  char *path = g_strdup_printf(PORTAL_PATH "/request/%s/%s", sender, token);
  Pending *p = g_new0(Pending, 1);
  p->fn = fn;
  p->sub = g_dbus_connection_signal_subscribe(bus, PORTAL_NAME, "org.freedesktop.portal.Request", "Response",
    path, NULL, G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE, on_response, p, NULL);
  g_variant_builder_add(options, "{sv}", "handle_token", g_variant_new_string(token));
  GVariant *args = session_path == NULL ? g_variant_new("(a{sv})", options)
    : parent == NULL ? g_variant_new("(oa{sv})", session_path, options)
    : g_variant_new("(osa{sv})", session_path, parent, options);
  GError *err = NULL;
  GVariant *r = g_dbus_connection_call_sync(bus, PORTAL_NAME, PORTAL_PATH, SCREENCAST, method, args, NULL,
    G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);
  if (r == NULL) {
    g_dbus_connection_signal_unsubscribe(bus, p->sub);
    g_free(p);
    char *msg = g_strdup_printf("ScreenCast portal %s: %s", method, err->message);
    fail(msg);
    g_free(msg);
    g_error_free(err);
  } else {
    g_variant_unref(r);
  }
  g_free(token);
  g_free(path);
}

static void on_session_closed(GDBusConnection *c, const char *from, const char *path, const char *iface,
                              const char *signal, GVariant *params, gpointer data) {
  (void)c; (void)from; (void)path; (void)iface; (void)signal; (void)params; (void)data;
  fprintf(stderr, "webby-screencast: the portal closed the session\n");
  end_sharing(NULL);
}

static void on_started(guint32 code, GVariant *results) {
  if (code == 1) {
    out_line("CANCELLED");
    g_idle_add(quit_idle, NULL);
    return;
  }
  if (code != 0) {
    fail("the ScreenCast portal could not start");
    return;
  }
  GVariant *streams = g_variant_lookup_value(results, "streams", G_VARIANT_TYPE("a(ua{sv})"));
  if (streams == NULL || g_variant_n_children(streams) == 0) {
    fail("the ScreenCast portal shared no stream");
    return;
  }
  guint32 node;
  GVariant *props;
  g_variant_get_child(streams, 0, "(u@a{sv})", &node, &props);
  g_variant_lookup(props, "size", "(ii)", &src_width, &src_height);
  guint32 type = 0;
  if (g_variant_lookup(props, "source_type", "u", &type) && type == 2) surface = "window";
  g_variant_unref(props);
  g_variant_unref(streams);

  GUnixFDList *fds = NULL;
  GError *err = NULL;
  GVariantBuilder none;
  g_variant_builder_init(&none, G_VARIANT_TYPE_VARDICT);
  GVariant *r = g_dbus_connection_call_with_unix_fd_list_sync(bus, PORTAL_NAME, PORTAL_PATH, SCREENCAST,
    "OpenPipeWireRemote", g_variant_new("(oa{sv})", session, &none), G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE,
    -1, NULL, &fds, NULL, &err);
  if (r == NULL) {
    char *msg = g_strdup_printf("ScreenCast portal OpenPipeWireRemote: %s", err->message);
    fail(msg);
    g_free(msg);
    g_error_free(err);
    return;
  }
  gint32 handle;
  g_variant_get(r, "(h)", &handle);
  g_variant_unref(r);
  int fd = g_unix_fd_list_get(fds, handle, NULL);
  g_object_unref(fds);
  if (fd < 0) {
    fail("ScreenCast portal: no PipeWire connection");
    return;
  }
  fprintf(stderr, "webby-screencast: sharing node %u (%dx%d %s)\n", node, src_width, src_height, surface);
  start_pipewire(fd, node);
  send_ready();
}

static void on_sources_selected(guint32 code, GVariant *results) {
  (void)results;
  if (code == 1) {
    out_line("CANCELLED");
    g_idle_add(quit_idle, NULL);
    return;
  }
  if (code != 0) {
    fail("the ScreenCast portal could not select sources");
    return;
  }
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  portal_request("Start", session, "", &options, on_started);
}

static guint32 portal_property(const char *name) {
  GVariant *r = g_dbus_connection_call_sync(bus, PORTAL_NAME, PORTAL_PATH, "org.freedesktop.DBus.Properties", "Get",
    g_variant_new("(ss)", SCREENCAST, name), G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL);
  if (r == NULL) return 0;
  GVariant *v;
  g_variant_get(r, "(v)", &v);
  guint32 u = g_variant_is_of_type(v, G_VARIANT_TYPE_UINT32) ? g_variant_get_uint32(v) : 0;
  g_variant_unref(v);
  g_variant_unref(r);
  return u;
}

static void on_session_created(guint32 code, GVariant *results) {
  if (code != 0 || !g_variant_lookup(results, "session_handle", "s", &session)) {
    fail("the ScreenCast portal could not create a session");
    return;
  }
  g_dbus_connection_signal_subscribe(bus, PORTAL_NAME, "org.freedesktop.portal.Session", "Closed", session, NULL,
    G_DBUS_SIGNAL_FLAGS_NONE, on_session_closed, NULL, NULL);
  guint32 types = portal_property("AvailableSourceTypes") & 3;   // monitors and windows
  guint32 cursors = portal_property("AvailableCursorModes");
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "types", g_variant_new_uint32(types ? types : 1));
  g_variant_builder_add(&options, "{sv}", "multiple", g_variant_new_boolean(FALSE));
  // The pointer drawn into the frames, as Chrome records it.
  if (cursors & 2) g_variant_builder_add(&options, "{sv}", "cursor_mode", g_variant_new_uint32(2));
  portal_request("SelectSources", session, NULL, &options, on_sources_selected);
}

static void start_portal(void) {
  GError *err = NULL;
  bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
  if (bus == NULL) {
    char *msg = g_strdup_printf("no D-Bus session bus: %s", err->message);
    fail(msg);
    g_free(msg);
    g_error_free(err);
    return;
  }
  sender = g_strdup(g_dbus_connection_get_unique_name(bus) + 1);
  for (char *c = sender; *c; c++)
    if (*c == '.') *c = '_';
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  char *session_token = g_strdup_printf("webby%d", getpid());
  g_variant_builder_add(&options, "{sv}", "session_handle_token", g_variant_new_string(session_token));
  g_free(session_token);
  portal_request("CreateSession", NULL, NULL, &options, on_session_created);
}

static void start_x11(void) {
  Display *display = XOpenDisplay(NULL);
  if (display == NULL) {
    fail("cannot open the X display");
    return;
  }
  src_width = DisplayWidth(display, DefaultScreen(display));
  src_height = DisplayHeight(display, DefaultScreen(display));
  XCloseDisplay(display);
  send_ready();
}

// ---------------------------------------------------------------------------------------------------------------
// Recordings

static GstFlowReturn on_sample(GstAppSink *sink, gpointer data) {
  (void)data;
  GstSample *sample = gst_app_sink_pull_sample(sink);
  if (sample == NULL) return GST_FLOW_EOS;
  GstBuffer *buffer = gst_sample_get_buffer(sample);
  GstMapInfo map;
  if (buffer && gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    if (map.size > 0) out_data(map.data, map.size);
    gst_buffer_unmap(buffer, &map);
  }
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

static void teardown(void) {
  if (stop_timeout) g_source_remove(stop_timeout);
  stop_timeout = 0;
  if (pipeline == NULL) return;
  gst_element_set_state(pipeline, GST_STATE_NULL);
  g_mutex_lock(&frame_lock);
  if (appsrc) gst_object_unref(appsrc);
  appsrc = NULL;
  g_mutex_unlock(&frame_lock);
  gst_object_unref(pipeline);
  pipeline = NULL;
}

static void finished(void) {
  teardown();
  recording = stopping = FALSE;
  out_line("STOPPED");
}

static gboolean on_bus(GstBus *b, GstMessage *msg, gpointer data) {
  (void)b;
  if (data != pipeline) return G_SOURCE_REMOVE;   // a message from an earlier recording
  if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_EOS) {
    finished();
    return G_SOURCE_REMOVE;
  }
  if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
    GError *err = NULL;
    char *debug = NULL;
    gst_message_parse_error(msg, &err, &debug);
    fprintf(stderr, "webby-screencast: %s: %s (%s)\n", GST_OBJECT_NAME(msg->src), err->message, debug ? debug : "");
    out_line("ERROR %s", err->message);
    g_error_free(err);
    g_free(debug);
    finished();
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

static char *audio_branch(gboolean system_audio, gboolean microphone) {
  const char *convert = "audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=2";
  const char *encode = "valve name=avalve ! audioconvert ! audio/x-raw,channels=2 ! opusenc bitrate=128000 ! queue ! mux.";
  if (system_audio && microphone)
    return g_strdup_printf("audiomixer name=amix ! %s  pulsesrc device=@DEFAULT_MONITOR@ ! %s ! queue ! amix.  "
      "pulsesrc ! %s ! queue ! amix.", encode, convert, convert);
  return g_strdup_printf("pulsesrc %s ! %s ! %s", system_audio ? "device=@DEFAULT_MONITOR@" : "", convert, encode);
}

static GstElement *build_pipeline(gboolean system_audio, gboolean microphone) {
  int w = src_width > 0 ? src_width : 1280, h = src_height > 0 ? src_height : 720;
  if (w > MAX_WIDTH) {
    h = (int)((gint64)h * MAX_WIDTH / w);
    w = MAX_WIDTH;
  }
  w &= ~1;
  h &= ~1;
  const char *source = use_x11
    ? "ximagesrc use-damage=false show-pointer=true ! video/x-raw,framerate=30/1"
    : "appsrc name=vsrc is-live=true format=time do-timestamp=true";
  char *audio = system_audio || microphone ? audio_branch(system_audio, microphone) : g_strdup("");
  char *desc = g_strdup_printf(
    "%s ! queue leaky=downstream max-size-buffers=4 ! valve name=vvalve ! videoconvert ! videoscale add-borders=true ! "
    "video/x-raw,format=I420,width=%d,height=%d,pixel-aspect-ratio=1/1 ! "
    "vp8enc deadline=1 cpu-used=8 threads=4 end-usage=vbr target-bitrate=3000000 keyframe-max-dist=150 ! queue ! "
    "webmmux name=mux streamable=true ! appsink name=out sync=false emit-signals=true  %s",
    source, w, h, audio);
  g_free(audio);
  GError *err = NULL;
  GstElement *p = gst_parse_launch(desc, &err);
  g_free(desc);
  if (err != NULL) {
    fprintf(stderr, "webby-screencast: pipeline: %s\n", err->message);
    g_error_free(err);
    if (p) gst_object_unref(p);
    return NULL;
  }
  return p;
}

static void set_valves(gboolean drop) {
  if (pipeline == NULL) return;
  for (int i = 0; i < 2; i++) {
    GstElement *valve = gst_bin_get_by_name(GST_BIN(pipeline), i == 0 ? "vvalve" : "avalve");
    if (valve) {
      g_object_set(valve, "drop", drop, NULL);
      gst_object_unref(valve);
    }
  }
}

static void start_recording(gboolean system_audio, gboolean microphone) {
  if (recording || ended) return;
  // Without a sound server the audio sources fail to start; the recording then goes on without sound.
  for (int attempt = 0; attempt < 2; attempt++) {
    gboolean audio = attempt == 0 && (system_audio || microphone);
    if (attempt == 1 && !(system_audio || microphone)) break;
    GstElement *p = build_pipeline(audio && system_audio, audio && microphone);
    if (p == NULL) continue;
    GstElement *sink = gst_bin_get_by_name(GST_BIN(p), "out");
    g_signal_connect(sink, "new-sample", G_CALLBACK(on_sample), NULL);
    gst_object_unref(sink);
    pipeline = p;
    GstBus *b = gst_element_get_bus(p);
    gst_bus_add_watch(b, on_bus, p);
    gst_object_unref(b);
    if (gst_element_set_state(p, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
      fprintf(stderr, "webby-screencast: the recording could not start%s\n", audio ? " with sound; trying without" : "");
      gst_element_set_state(p, GST_STATE_NULL);
      gst_object_unref(p);
      pipeline = NULL;
      continue;
    }
    g_mutex_lock(&frame_lock);
    appsrc = use_x11 ? NULL : gst_bin_get_by_name(GST_BIN(p), "vsrc");
    if (appsrc) {
      frame_caps_changed = frame_caps != NULL;
      if (last_frame) push_frame_locked(last_frame);
    }
    g_mutex_unlock(&frame_lock);
    recording = TRUE;
    stopping = FALSE;
    return;
  }
  out_line("ERROR the recording could not start");
  out_line("STOPPED");
}

static gboolean stop_timed_out(gpointer data) {
  (void)data;
  stop_timeout = 0;
  fprintf(stderr, "webby-screencast: no end of stream after 5 s\n");
  finished();
  return G_SOURCE_REMOVE;
}

static void stop_recording(void) {
  if (!recording || stopping) return;
  stopping = TRUE;
  set_valves(FALSE);
  g_mutex_lock(&frame_lock);
  if (appsrc) gst_app_src_end_of_stream(GST_APP_SRC(appsrc));
  g_mutex_unlock(&frame_lock);
  gst_element_send_event(pipeline, gst_event_new_eos());
  stop_timeout = g_timeout_add(5000, stop_timed_out, NULL);
}

// ---------------------------------------------------------------------------------------------------------------
// Commands from webby

static GString *input;

static void command(const char *line) {
  int system_audio = 0, microphone = 0;
  if (sscanf(line, "start %d %d", &system_audio, &microphone) >= 0 && g_str_has_prefix(line, "start"))
    start_recording(system_audio != 0, microphone != 0);
  else if (strcmp(line, "pause") == 0) set_valves(TRUE);
  else if (strcmp(line, "resume") == 0) set_valves(FALSE);
  else if (strcmp(line, "stop") == 0) stop_recording();
  else fprintf(stderr, "webby-screencast: unknown command %s\n", line);
}

static gboolean on_stdin(gint fd, GIOCondition cond, gpointer data) {
  (void)cond; (void)data;
  char buf[512];
  ssize_t n = read(fd, buf, sizeof buf);
  if (n < 0 && (errno == EINTR || errno == EAGAIN)) return G_SOURCE_CONTINUE;
  if (n <= 0) {
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
  }
  g_string_append_len(input, buf, n);
  char *nl;
  while ((nl = strchr(input->str, '\n')) != NULL) {
    *nl = 0;
    command(input->str);
    g_string_erase(input, 0, nl - input->str + 1);
  }
  return G_SOURCE_CONTINUE;
}

// GStreamer from webby's own prefix only: plugins a system GStreamer or GST_PLUGIN_PATH would add are built
// against another libgstreamer, and its registry cache belongs to that one too.
static void own_gstreamer(void) {
  Dl_info info;
  if (!dladdr((void *)gst_init, &info) || info.dli_fname == NULL) return;
  char *lib = g_path_get_dirname(info.dli_fname);
  char *prefix = g_path_get_dirname(lib);
  char *plugins = g_build_filename(lib, "gstreamer-1.0", NULL);
  char *scanner = g_build_filename(prefix, "libexec", "gstreamer-1.0", "gst-plugin-scanner", NULL);
  char *registry = g_strdup_printf("%s/webby/gstreamer-registry-%08x.bin", g_get_user_cache_dir(), g_str_hash(prefix));
  g_setenv("GST_PLUGIN_SYSTEM_PATH_1_0", plugins, TRUE);
  g_unsetenv("GST_PLUGIN_PATH_1_0");
  g_unsetenv("GST_PLUGIN_PATH");
  if (g_file_test(scanner, G_FILE_TEST_IS_EXECUTABLE)) g_setenv("GST_PLUGIN_SCANNER_1_0", scanner, TRUE);
  g_setenv("GST_REGISTRY_1_0", registry, TRUE);
  g_free(lib);
  g_free(prefix);
  g_free(plugins);
  g_free(scanner);
  g_free(registry);
}

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--x11") == 0) use_x11 = TRUE;
    else if (strcmp(argv[i], "--portal") == 0) use_x11 = FALSE;
    else {
      fprintf(stderr, "usage: webby-screencast [--portal | --x11]\n");
      return 2;
    }
  }
  own_gstreamer();
  gst_init(NULL, NULL);
  input = g_string_new(NULL);
  loop = g_main_loop_new(NULL, FALSE);
  g_unix_fd_add(0, G_IO_IN | G_IO_HUP | G_IO_ERR, on_stdin, NULL);
  if (use_x11) start_x11();
  else start_portal();
  g_main_loop_run(loop);
  if (recording) {
    // stdin closed mid-recording (webby quit): finish the file anyway, briefly.
    stop_recording();
    GstBus *b = pipeline ? gst_element_get_bus(pipeline) : NULL;
    if (b) {
      GstMessage *m = gst_bus_timed_pop_filtered(b, 2 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
      if (m) gst_message_unref(m);
      gst_object_unref(b);
    }
  }
  teardown();
  if (pw_loop) pw_thread_loop_stop(pw_loop);
  return 0;
}
