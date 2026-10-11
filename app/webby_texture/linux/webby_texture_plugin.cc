// An FlPixelBufferTexture that Dart feeds Ladybird frames into over FFI, so frames reach the engine without a
// round trip through Dart objects or image decoding.
//
// Dart creates and disposes textures over the "webby_texture" method channel (that runs on the platform thread,
// where the registrar lives) and pushes frames with webby_texture_push() from its own thread. The engine reads
// pixels on the raster thread.

#include "include/webby_texture/webby_texture_plugin.h"

#include <cstdint>
#include <cstring>
#include <mutex>
#include <utility>
#include <vector>

namespace {

struct Frame {
  std::vector<uint32_t> pixels;
  uint32_t width = 0;
  uint32_t height = 0;
};

// Three frames: the producer writes `spare`, publishes it as `pending`, and the raster thread takes `pending` as
// `front`. The engine keeps reading `front` after copy_pixels returns, so nothing else may touch it until the next
// copy_pixels call.
struct FrameQueue {
  std::mutex mutex;
  Frame frames[3];
  Frame* front = &frames[0];
  Frame* pending = &frames[1];
  Frame* spare = &frames[2];
  bool has_pending = false;
};

// Ladybird frames are BGRA; FlPixelBufferTexture uploads RGBA. Copying is needed anyway (Ladybird reuses its
// buffer on the next pump), so swap the channels on the way.
void copy_bgra_to_rgba(uint32_t* dst, uint32_t const* src, size_t count) {
  for (size_t i = 0; i < count; ++i) {
    uint32_t p = src[i];
    dst[i] = (p & 0xff00ff00u) | ((p >> 16) & 0xffu) | ((p & 0xffu) << 16);
  }
}

}  // namespace

G_DECLARE_FINAL_TYPE(WebbyFrameTexture, webby_frame_texture, WEBBY, FRAME_TEXTURE, FlPixelBufferTexture)

struct _WebbyFrameTexture {
  FlPixelBufferTexture parent_instance;
  FrameQueue* queue;
  FlTextureRegistrar* registrar;
};

G_DEFINE_TYPE(WebbyFrameTexture, webby_frame_texture, fl_pixel_buffer_texture_get_type())

static gboolean webby_frame_texture_copy_pixels(FlPixelBufferTexture* texture, const uint8_t** buffer,
                                                uint32_t* width, uint32_t* height, GError** error) {
  FrameQueue* queue = WEBBY_FRAME_TEXTURE(texture)->queue;
  {
    std::lock_guard<std::mutex> lock(queue->mutex);
    if (queue->has_pending) {
      std::swap(queue->front, queue->pending);
      queue->has_pending = false;
    }
  }
  Frame* front = queue->front;
  if (front->width == 0) {
    // Nothing pushed yet; hand over one transparent pixel rather than failing (which logs a warning per paint).
    front->pixels.assign(1, 0);
    front->width = front->height = 1;
  }
  *buffer = reinterpret_cast<const uint8_t*>(front->pixels.data());
  *width = front->width;
  *height = front->height;
  return TRUE;
}

static void webby_frame_texture_dispose(GObject* object) {
  WebbyFrameTexture* self = WEBBY_FRAME_TEXTURE(object);
  delete self->queue;
  self->queue = nullptr;
  g_clear_object(&self->registrar);
  G_OBJECT_CLASS(webby_frame_texture_parent_class)->dispose(object);
}

static void webby_frame_texture_class_init(WebbyFrameTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = webby_frame_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->dispose = webby_frame_texture_dispose;
}

static void webby_frame_texture_init(WebbyFrameTexture* self) { self->queue = new FrameQueue(); }

// Copies one BGRA frame (stride width * 4) into the texture and tells the engine to redraw it. `handle` comes
// from the "create" method; callers must stop pushing before they dispose it.
extern "C" __attribute__((visibility("default"))) void webby_texture_push(intptr_t handle, uint8_t const* bgra,
                                                                          int32_t width, int32_t height) {
  auto* texture = reinterpret_cast<WebbyFrameTexture*>(handle);
  if (texture == nullptr || bgra == nullptr || width <= 0 || height <= 0) return;
  FrameQueue* queue = texture->queue;

  // Only this thread touches `spare`, so fill it without the lock.
  Frame* frame = queue->spare;
  size_t count = static_cast<size_t>(width) * static_cast<size_t>(height);
  frame->pixels.resize(count);
  copy_bgra_to_rgba(frame->pixels.data(), reinterpret_cast<uint32_t const*>(bgra), count);
  frame->width = static_cast<uint32_t>(width);
  frame->height = static_cast<uint32_t>(height);
  {
    std::lock_guard<std::mutex> lock(queue->mutex);
    std::swap(queue->spare, queue->pending);
    queue->has_pending = true;
  }
  fl_texture_registrar_mark_texture_frame_available(texture->registrar, FL_TEXTURE(texture));
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call, gpointer user_data) {
  auto* registrar = FL_TEXTURE_REGISTRAR(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "create") == 0) {
    auto* texture = WEBBY_FRAME_TEXTURE(g_object_new(webby_frame_texture_get_type(), nullptr));
    texture->registrar = FL_TEXTURE_REGISTRAR(g_object_ref(registrar));
    if (fl_texture_registrar_register_texture(registrar, FL_TEXTURE(texture))) {
      g_autoptr(FlValue) result = fl_value_new_list();
      fl_value_append_take(result, fl_value_new_int(fl_texture_get_id(FL_TEXTURE(texture))));
      fl_value_append_take(result, fl_value_new_int(reinterpret_cast<intptr_t>(texture)));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    } else {
      g_object_unref(texture);
      response = FL_METHOD_RESPONSE(fl_method_error_response_new("register_failed", "Could not register texture", nullptr));
    }
  } else if (strcmp(method, "dispose") == 0 && args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_INT) {
    auto* texture = reinterpret_cast<WebbyFrameTexture*>(fl_value_get_int(args));
    fl_texture_registrar_unregister_texture(registrar, FL_TEXTURE(texture));
    g_object_unref(texture);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

void webby_texture_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  FlTextureRegistrar* textures = fl_plugin_registrar_get_texture_registrar(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // The channel lives as long as the engine; let it go with the registrar's messenger.
  FlMethodChannel* channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "webby_texture", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, g_object_ref(textures), g_object_unref);
}
