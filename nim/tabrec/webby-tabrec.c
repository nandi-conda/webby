// webby-tabrec: encodes a recording of a webby tab for bug reports (nim/src/features/bugreport.nim, which starts one
// per recording). webby hands it the page's own frames, so nothing is grabbed from the screen and no portal or
// picker is involved; they are encoded with GStreamer to WebM (VP8, no sound).
//
// Usage: webby-tabrec <width> <height> <out.webm>
// stdin:  F <ms>\n<width*height*4 bytes of BGRA>   a frame, <ms> after the recording started (frames come only
//                                                  when the page changed, so the gaps vary)
//         E <ms>\n                                 the recording is over at <ms>: finish the file and quit
//         EOF without E                            the same
// stdout: DONE <duration-ms>\n  or  ERROR <text>\n
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

int main(int argc, char **argv) {
  gst_init(&argc, &argv);
  if (argc != 4) fail("usage: webby-tabrec <width> <height> <out.webm>");
  int width = atoi(argv[1]), height = atoi(argv[2]);
  if (width < 16 || height < 16 || width > 8192 || height > 8192) fail("bad frame size");
  // Big pages are scaled down to MAX_WIDTH wide; VP8 (and Jam's conversion to H.264) wants even sizes.
  int out_w = width, out_h = height;
  if (out_w > MAX_WIDTH) {
    out_h = (int)((double)out_h * MAX_WIDTH / out_w);
    out_w = MAX_WIDTH;
  }
  out_w &= ~1;
  out_h &= ~1;
  char *desc = g_strdup_printf(
    "appsrc name=src format=time is-live=false do-timestamp=false block=true max-bytes=%d "
    "caps=video/x-raw,format=BGRA,width=%d,height=%d,framerate=0/1 ! "
    "videoconvert ! videoscale ! video/x-raw,format=I420,width=%d,height=%d ! "
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
  GstBus *bus = gst_element_get_bus(pipeline);
  GstMessage *msg = gst_bus_timed_pop_filtered(bus, 60 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
  if (!msg) fail("the encoder did not finish");
  if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
    GError *e = NULL;
    gst_message_parse_error(msg, &e, NULL);
    fail(e ? e->message : "encoder error");
  }
  gst_message_unref(msg);
  gst_object_unref(bus);
  gst_element_set_state(pipeline, GST_STATE_NULL);
  fprintf(stderr, "webby-tabrec: %ld frames, %llu ms\n", frames, (unsigned long long)last_ms);
  printf("DONE %llu\n", (unsigned long long)last_ms);
  fflush(stdout);
  return 0;
}
