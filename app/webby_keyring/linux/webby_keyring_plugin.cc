// Keeps the password vault's master key in the desktop keyring (GNOME Keyring, KWallet, KeePassXC... anything that
// speaks the Secret Service D-Bus API) through libsecret.
//
// libsecret is loaded with dlopen() so the browser still starts on systems without it; Dart then falls back to a key
// file. Keyring calls block on D-Bus (and may show an unlock prompt), so they run on a worker thread and answer the
// method call back on the platform thread.

#include "include/webby_keyring/webby_keyring_plugin.h"

#include <dlfcn.h>

#include <algorithm>
#include <cstring>
#include <string>

namespace {

// The parts of libsecret's public ABI we use (secret-schema.h, secret-password.h).
enum { SECRET_SCHEMA_NONE = 0 };
enum { SECRET_SCHEMA_ATTRIBUTE_STRING = 0 };

struct SecretSchemaAttribute {
  const gchar* name;
  int type;
};

struct SecretSchema {
  const gchar* name;
  int flags;
  SecretSchemaAttribute attributes[32];
  gint reserved;
  gpointer reserved1;
  gpointer reserved2;
  gpointer reserved3;
  gpointer reserved4;
  gpointer reserved5;
  gpointer reserved6;
  gpointer reserved7;
};

using LookupSync = gchar* (*)(const SecretSchema*, GCancellable*, GError**, ...);
using StoreSync = gboolean (*)(const SecretSchema*, const gchar*, const gchar*, const gchar*, GCancellable*, GError**,
                               ...);
using PasswordFree = void (*)(gchar*);

struct Libsecret {
  LookupSync lookup = nullptr;
  StoreSync store = nullptr;
  PasswordFree free = nullptr;
  bool loaded = false;
};

const Libsecret& libsecret() {
  static Libsecret lib = [] {
    Libsecret result;
    void* handle = dlopen("libsecret-1.so.0", RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) return result;
    result.lookup = reinterpret_cast<LookupSync>(dlsym(handle, "secret_password_lookup_sync"));
    result.store = reinterpret_cast<StoreSync>(dlsym(handle, "secret_password_store_sync"));
    result.free = reinterpret_cast<PasswordFree>(dlsym(handle, "secret_password_free"));
    result.loaded = result.lookup && result.store && result.free;
    return result;
  }();
  return lib;
}

const SecretSchema kSchema = {
    "dev.webby.Vault",
    SECRET_SCHEMA_NONE,
    {
        {"application", SECRET_SCHEMA_ATTRIBUTE_STRING},
        {"profile", SECRET_SCHEMA_ATTRIBUTE_STRING},
        {nullptr, 0},
    },
    0, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
};

struct Request {
  std::string method;
  std::string profile;
  std::string secret;  // for "store"
};

struct Reply {
  bool ok = false;
  bool found = false;
  std::string secret;
  std::string error_code;
  std::string error_message;
};

void request_free(gpointer data) { delete static_cast<Request*>(data); }
void reply_free(gpointer data) { delete static_cast<Reply*>(data); }

void run_request(GTask* task, gpointer, gpointer task_data, GCancellable*) {
  auto* request = static_cast<Request*>(task_data);
  auto* reply = new Reply();
  const Libsecret& lib = libsecret();
  if (!lib.loaded) {
    reply->error_code = "unavailable";
    reply->error_message = "libsecret-1.so.0 not found";
    g_task_return_pointer(task, reply, reply_free);
    return;
  }

  GError* error = nullptr;
  if (request->method == "lookup") {
    gchar* secret = lib.lookup(&kSchema, nullptr, &error, "application", "webby", "profile", request->profile.c_str(),
                               nullptr);
    if (error == nullptr) {
      reply->ok = true;
      reply->found = secret != nullptr;
      if (secret != nullptr) reply->secret = secret;
    }
    if (secret != nullptr) lib.free(secret);
  } else {
    std::string label = "Webby password vault (" + request->profile + ")";
    gboolean stored = lib.store(&kSchema, "default", label.c_str(), request->secret.c_str(), nullptr, &error,
                                "application", "webby", "profile", request->profile.c_str(), nullptr);
    reply->ok = stored && error == nullptr;
  }
  if (error != nullptr) {
    reply->error_code = "unavailable";
    reply->error_message = error->message;
    g_error_free(error);
  } else if (!reply->ok) {
    reply->error_code = "failed";
    reply->error_message = "The keyring refused the request";
  }
  g_task_return_pointer(task, reply, reply_free);
}

void request_done(GObject*, GAsyncResult* result, gpointer user_data) {
  g_autoptr(FlMethodCall) method_call = FL_METHOD_CALL(user_data);
  auto* reply = static_cast<Reply*>(g_task_propagate_pointer(G_TASK(result), nullptr));
  g_autoptr(FlMethodResponse) response = nullptr;
  if (reply == nullptr) {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new("failed", "Keyring request failed", nullptr));
  } else if (!reply->ok) {
    response = FL_METHOD_RESPONSE(
        fl_method_error_response_new(reply->error_code.c_str(), reply->error_message.c_str(), nullptr));
  } else if (reply->found) {
    g_autoptr(FlValue) value = fl_value_new_string(reply->secret.c_str());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }
  if (reply != nullptr) {
    // Don't leave the key lying around in freed memory.
    std::fill(reply->secret.begin(), reply->secret.end(), '\0');
    delete reply;
  }
  fl_method_call_respond(method_call, response, nullptr);
}

const gchar* string_arg(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) return nullptr;
  return fl_value_get_string(value);
}

void method_call_cb(FlMethodChannel*, FlMethodCall* method_call, gpointer) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  const gchar* profile = string_arg(args, "profile");
  const gchar* secret = string_arg(args, "secret");

  bool is_lookup = strcmp(method, "lookup") == 0;
  bool is_store = strcmp(method, "store") == 0;
  if ((!is_lookup && !is_store) || profile == nullptr || (is_store && secret == nullptr)) {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  auto* request = new Request{method, profile, secret != nullptr ? secret : ""};
  GTask* task = g_task_new(nullptr, nullptr, request_done, g_object_ref(method_call));
  g_task_set_task_data(task, request, request_free);
  g_task_run_in_thread(task, run_request);
  g_object_unref(task);
}

}  // namespace

void webby_keyring_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // The channel lives as long as the engine.
  FlMethodChannel* channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "webby_keyring", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr, nullptr);
}
