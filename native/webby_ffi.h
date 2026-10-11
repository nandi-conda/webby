/*
 * Webby: a small C ABI over Ladybird's LibWebView so a Flutter app can drive
 * LibWeb (rendering) and LibJS (JavaScript) through dart:ffi.
 *
 * Threading: every function must be called from the same thread (the Dart
 * root isolate's thread). Nothing happens unless webby_pump() is called
 * regularly; it runs Ladybird's event loop without blocking.
 *
 * Pixels: frames are copied into a buffer owned by the view. Format is BGRA,
 * 8 bits per channel, premultiplied alpha, stride = width * 4.
 */

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WEBBY_API __attribute__((visibility("default")))

typedef struct WebbyView WebbyView;

/* Starts the browser process side of Ladybird. `prefix` is the Ladybird
 * install/build prefix containing bin/, libexec/ (WebContent, RequestServer,
 * ImageDecoder) and share/Lagom. Returns 0 on success. */
WEBBY_API int webby_init(char const* prefix);

/* Runs pending Ladybird events without blocking. Returns events processed. */
WEBBY_API int webby_pump(void);

WEBBY_API WebbyView* webby_view_create(int width, int height, double device_pixel_ratio);
WEBBY_API void webby_view_destroy(WebbyView*);

WEBBY_API void webby_view_load(WebbyView*, char const* url_or_search);
WEBBY_API void webby_view_go_back(WebbyView*);
WEBBY_API void webby_view_go_forward(WebbyView*);
WEBBY_API void webby_view_reload(WebbyView*);
WEBBY_API void webby_view_stop(WebbyView*);
WEBBY_API void webby_view_resize(WebbyView*, int width, int height, double device_pixel_ratio);
WEBBY_API void webby_view_set_focus(WebbyView*, int focused);
WEBBY_API void webby_view_run_javascript(WebbyView*, char const* source);

/* What `prefers-color-scheme` reports to pages, and the colour of the blank
 * canvas before a page paints: 0 auto (Ladybird's theme), 1 light, 2 dark.
 * Takes effect at once on the loaded page. */
enum {
    WEBBY_COLOR_SCHEME_AUTO = 0,
    WEBBY_COLOR_SCHEME_LIGHT = 1,
    WEBBY_COLOR_SCHEME_DARK = 2,
};
WEBBY_API void webby_view_set_color_scheme(WebbyView*, int scheme);

/* Whether the view is on screen (1, the default) or in a background tab (0).
 * A hidden page gets document.visibilityState "hidden" and stops its
 * rendering updates (requestAnimationFrame, painting), so background tabs stop
 * producing frames. The last frame stays readable. */
WEBBY_API void webby_view_set_visible(WebbyView*, int visible);

/* Frame access. frame_serial() increments every time a new frame is copied.
 * The pointer stays valid until the next webby_pump() call. */
WEBBY_API uint64_t webby_view_frame_serial(WebbyView*);
WEBBY_API uint8_t const* webby_view_frame_pixels(WebbyView*);
WEBBY_API int webby_view_frame_width(WebbyView*);
WEBBY_API int webby_view_frame_height(WebbyView*);

/* Page state. state_serial() increments on any change of the values below.
 * Strings are UTF-8 and owned by the view (valid until the next pump). */
WEBBY_API uint64_t webby_view_state_serial(WebbyView*);
WEBBY_API char const* webby_view_url(WebbyView*);
WEBBY_API char const* webby_view_title(WebbyView*);
WEBBY_API char const* webby_view_hovered_link(WebbyView*);
WEBBY_API int webby_view_is_loading(WebbyView*);
WEBBY_API int webby_view_can_go_back(WebbyView*);
WEBBY_API int webby_view_can_go_forward(WebbyView*);
WEBBY_API int webby_view_cursor(WebbyView*);

/* Passkeys (Web Authentication). When a page calls navigator.credentials.create()
 * or .get() with `publicKey`, the view holds the request until the UI answers.
 * webby_view_webauthn_prompt() is "" when nothing is waiting, else a JSON object
 * (it changes together with state_serial()):
 *   { "type": "create", "rpId", "rpName", "origin", "userName", "userDisplayName",
 *     "alreadyRegistered": bool }
 *   { "type": "get", "rpId", "origin",
 *     "accounts": [ { "userName", "userDisplayName", "createdAt" } ] }
 * Answer with webby_view_webauthn_respond(): accepted = 0 cancels; for "get",
 * account_index picks one of "accounts". Passkeys are stored in
 * $WEBBY_PASSKEYS_FILE or ${XDG_DATA_HOME:-~/.local/share}/webby/passkeys.json. */
WEBBY_API char const* webby_view_webauthn_prompt(WebbyView*);
WEBBY_API void webby_view_webauthn_respond(WebbyView*, int accepted, int account_index);

/* Messages from the browser's own page scripts. A page script calls
 * prompt(prefix + text); the view answers it at once (as if cancelled) and
 * queues `text` instead of showing a dialog. webby_view_next_message() returns
 * and removes the oldest queued text, "" when there is none (valid until the
 * next call). An empty prefix (the default) turns this off. */
WEBBY_API void webby_view_set_message_prefix(WebbyView*, char const* prefix);
WEBBY_API char const* webby_view_next_message(WebbyView*);

/* Clipboard. Ladybird keeps its own clipboard: Ctrl+C / Ctrl+X in a page and
 * navigator.clipboard.write*() put text there, Ctrl+V and
 * navigator.clipboard.read*() take it from there. webby_clipboard_serial()
 * changes whenever a page copies; the UI then puts webby_clipboard_text()
 * (UTF-8, valid until the next call) on the system clipboard. Before a paste the
 * UI hands the system clipboard's text to webby_clipboard_set_text(), which
 * doesn't change the serial. */
WEBBY_API uint64_t webby_clipboard_serial(void);
WEBBY_API char const* webby_clipboard_text(void);
WEBBY_API void webby_clipboard_set_text(char const* text);

/* Passkey storage for the password manager's vault. By default passkeys live in
 * the file named above. webby_passkeys_use_vault() switches to an in-memory
 * store seeded with `json` (an array as webby_passkeys_export() returns) plus
 * any passkeys of the current store that aren't in it; returns 0, or -1 if
 * `json` isn't an array. From then on the UI saves webby_passkeys_export()
 * whenever webby_passkeys_serial() changes (it is 0 while passkeys are in the
 * file). webby_passkeys_export() returns every passkey as a JSON array of
 * { "credentialId", "rpId", "userId", "userName", "userDisplayName",
 *   "privateKey", "createdAt" }, valid until the next call.
 * webby_passkeys_delete_file() removes the file once the vault has saved its
 * passkeys (0 on success or if there is none; only works after
 * webby_passkeys_use_vault()). */
WEBBY_API int webby_passkeys_use_vault(char const* json);
WEBBY_API uint64_t webby_passkeys_serial(void);
WEBBY_API char const* webby_passkeys_export(void);
WEBBY_API int webby_passkeys_remove(char const* credential_id);
WEBBY_API int webby_passkeys_delete_file(void);

/* Input. Positions are in device pixels relative to the view's top-left.
 * button / buttons use Ladybird's bit values: 1 primary, 2 secondary,
 * 4 middle, 8 back, 16 forward. modifiers: 1 alt, 2 ctrl, 4 shift, 8 super. */
enum {
    WEBBY_MOUSE_DOWN = 0,
    WEBBY_MOUSE_UP = 1,
    WEBBY_MOUSE_MOVE = 2,
    WEBBY_MOUSE_LEAVE = 3,
};
WEBBY_API void webby_view_mouse_event(WebbyView*, int type, int x, int y, int button, int buttons, int modifiers, int click_count);
WEBBY_API void webby_view_wheel_event(WebbyView*, int x, int y, double delta_x, double delta_y, int precise, int modifiers);

/* key_code is a Ladybird Web::UIEvents::KeyCode value; code_point is the
 * Unicode text the key produces (0 for none). */
WEBBY_API void webby_view_key_event(WebbyView*, int is_down, int key_code, int modifiers, uint32_t code_point, int repeat);

/* Offline mode (patches/0003-offline-disk-cache.patch): while on, RequestServer
 * answers every fetch from Ladybird's HTTP disk cache only, expired entries
 * included, and fails a miss at once. Lets pages and installed web apps that
 * were opened before load without a network. Off by default. */
WEBBY_API void webby_set_offline(int offline);

#ifdef __cplusplus
}
#endif
