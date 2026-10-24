// webby-tabrec: encodes a recording of a webby tab for bug reports (nim/src/features/bugreport.nim, which starts one
// per recording). webby hands it the page's own frames, so nothing is grabbed from the screen and no portal or
// picker is involved; they are encoded with GStreamer to WebM (VP8, no sound).
//
// Usage: webby-tabrec <width> <height> <out.webm> [max-width]   (frames wider than max-width, 1920 by default,
//                                                               are scaled down)
// stdin:  F <ms>\n<width*height*4 bytes of BGRA>   a frame, <ms> after the recording started (frames come only
//                                                  when the page changed, so the gaps vary)
//         E <ms>\n                                 the recording is over at <ms>: finish the file and quit
//         EOF without E                            the same
// stdout: DONE <duration-ms>\n  or  ERROR <text>\n
//
// Usage: webby-tabrec --join <out.webm> <width> <height> <in.webm>...   one WebM of the inputs one after another,
//        at one size; for instant replay, which keeps the last minutes as short pieces
// Diagnostics go to stderr.

#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_WIDTH 1920

static GstElement *pipeline, *appsrc;
static guint64 last_ms;

static void fail(const char *what) {
  printf("ERROR %s\n", what);
  fflush(stdout);
  exit(1);
}

static gboolean read_exact(void *buf, size_t n) {
  return fread(buf, 1, n, stdin) == n;
}

static void wait_done(GstElement *p) {
  GstBus *bus = gst_element_get_bus(p);
  GstMessage *msg = gst_bus_timed_pop_filtered(bus, 120 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
  if (!msg) fail("the encoder did not finish");
  if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
    // GStreamer's message is generic ("Could not multiplex stream."); its debug text names the real cause.
    GError *e = NULL;
    gchar *debug = NULL;
    gst_message_parse_error(msg, &e, &debug);
    gchar *text = g_strdup_printf("%s%s%s", e ? e->message : "encoder error", debug ? " | " : "", debug ? debug : "");
    for (gchar *c = text; *c; c++) if (*c == '\n') *c = ' ';
    fail(text);
  }
  gst_message_unref(msg);
  gst_object_unref(bus);
}

static int join(int count, char **inputs, const char *out, int width, int height) {
  // Decoded and encoded again: pieces made at different window sizes come out at one size, and concat keeps the
  // timestamps running on from piece to piece. Every piece is converted to one fixed format (colorimetry and chroma
  // siting too: GStreamer picks bt709 for taller frames and bt601 for shorter ones) before concat, so the encoder
  // and muxer never see caps change mid-stream, which Matroska can't take ("Could not multiplex stream").
  GString *desc = g_string_new("");
  g_string_append_printf(desc,
    "concat name=c ! vp8enc deadline=1 cpu-used=8 end-usage=vbr target-bitrate=2000000 keyframe-max-dist=150 "
    "threads=4 ! webmmux ! filesink name=sink");
  for (int i = 0; i < count; i++) {
    char *quoted = g_strescape(inputs[i], NULL);
    g_string_append_printf(desc, "  filesrc location=\"%s\" ! matroskademux ! vp8dec ! videoscale ! "
      "video/x-raw,width=%d,height=%d,pixel-aspect-ratio=1/1 ! videoconvert ! "
      "video/x-raw,format=I420,colorimetry=bt601,chroma-site=jpeg,interlace-mode=progressive ! c.",
      quoted, width, height);
    g_free(quoted);
  }
  GError *err = NULL;
  GstElement *p = gst_parse_launch(desc->str, &err);
  g_string_free(desc, TRUE);
  if (!p) fail(err ? err->message : "could not join");
  GstElement *sink = gst_bin_get_by_name(GST_BIN(p), "sink");
  g_object_set(sink, "location", out, NULL);
  gst_object_unref(sink);
  if (gst_element_set_state(p, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) fail("could not start joining");
  wait_done(p);
  gst_element_set_state(p, GST_STATE_NULL);
  printf("DONE\n");
  fflush(stdout);
  return 0;
}

int main(int argc, char **argv) {
  gst_init(&argc, &argv);
  if (argc >= 6 && strcmp(argv[1], "--join") == 0)
    return join(argc - 5, argv + 5, argv[2], atoi(argv[3]) & ~1, atoi(argv[4]) & ~1);
  if (argc != 4 && argc != 5) fail("usage: webby-tabrec <width> <height> <out.webm> [max-width]");
  int max_width = argc == 5 ? atoi(argv[4]) : MAX_WIDTH;
  if (max_width < 64) max_width = MAX_WIDTH;
  int width = atoi(argv[1]), height = atoi(argv[2]);
  if (width < 16 || height < 16 || width > 8192 || height > 8192) fail("bad frame size");
  // Big pages are scaled down to max_width wide; VP8 (and Jam's conversion to H.264) wants even sizes.
  int out_w = width, out_h = height;
  if (out_w > max_width) {
    out_h = (int)((double)out_h * max_width / out_w);
    out_w = max_width;
  }
  out_w &= ~1;
  out_h &= ~1;
  char *desc = g_strdup_printf(
    "appsrc name=src format=time is-live=false do-timestamp=false block=true max-bytes=%d "
    "caps=video/x-raw,format=BGRA,width=%d,height=%d,framerate=0/1 ! "
    "videoscale method=bilinear ! video/x-raw,width=%d,height=%d,pixel-aspect-ratio=1/1 ! videoconvert ! "
    "video/x-raw,format=I420,colorimetry=bt601,chroma-site=jpeg ! "
    "vp8enc deadline=1 cpu-used=8 end-usage=vbr target-bitrate=2500000 keyframe-max-dist=150 threads=4 ! "
    "webmmux ! filesink name=sink",
    width * height * 4 * 4, width, height, out_w, out_h);
  GError *err = NULL;
  pipeline = gst_parse_launch(desc, &err);
  g_free(desc);
  if (!pipeline) fail(err ? err->message : "could not make the encoder");
  appsrc = gst_bin_get_by_name(GST_BIN(pipeline), "src");
  GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
  g_object_set(sink, "location", argv[3], NULL);
  gst_object_unref(sink);
  if (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) fail("could not start the encoder");

  gsize frame_bytes = (gsize)width * height * 4;
  char line[64];
  long frames = 0;
  guint64 end = 0;
  GstBuffer *previous = NULL;
  while (fgets(line, sizeof line, stdin)) {
    if (line[0] == 'E') {
      end = g_ascii_strtoull(line + 1, NULL, 10);
      break;
    }
    if (line[0] != 'F') continue;
    guint64 ms = g_ascii_strtoull(line + 2, NULL, 10);
    GstBuffer *buf = gst_buffer_new_allocate(NULL, frame_bytes, NULL);
    GstMapInfo map;
    gst_buffer_map(buf, &map, GST_MAP_WRITE);
    gboolean ok = read_exact(map.data, frame_bytes);
    gst_buffer_unmap(buf, &map);
    if (!ok) {
      gst_buffer_unref(buf);
      break;
    }
    if (frames > 0 && ms <= last_ms) ms = last_ms + 1;
    GST_BUFFER_PTS(buf) = ms * GST_MSECOND;
    last_ms = ms;
    if (previous) gst_buffer_unref(previous);
    previous = gst_buffer_ref(buf);
    if (gst_app_src_push_buffer(GST_APP_SRC(appsrc), buf) != GST_FLOW_OK) fail("the encoder stopped");
    frames++;
  }
  if (frames == 0) fail("no frames");
  // The last frame again at the end, so the video lasts until Stop rather than until the page last changed.
  if (previous) {
    GstBuffer *tail = gst_buffer_copy(previous);
    GST_BUFFER_PTS(tail) = MAX(end, last_ms + 100) * GST_MSECOND;
    last_ms = MAX(end, last_ms + 100);
    gst_app_src_push_buffer(GST_APP_SRC(appsrc), tail);
    gst_buffer_unref(previous);
  }
  gst_app_src_end_of_stream(GST_APP_SRC(appsrc));
  wait_done(pipeline);
  gst_element_set_state(pipeline, GST_STATE_NULL);
  fprintf(stderr, "webby-tabrec: %ld frames, %llu ms\n", frames, (unsigned long long)last_ms);
  printf("DONE %llu\n", (unsigned long long)last_ms);
  fflush(stdout);
  return 0;
}
