/*
 * Webby: a small C ABI over Ladybird's LibWebView so webby's Nim front end can
 * drive LibWeb (rendering) and LibJS (JavaScript).
 *
 * Threading: every function must be called from the same thread (the UI
 * root isolate's thread). Nothing happens unless webby_pump() is called
 * regularly; it runs Ladybird's event loop without blocking.
 *
 * Pixels: frames are copied into a buffer owned by the view. Format is BGRA,
 * 8 bits per channel, premultiplied alpha, stride = width * 4.
 */

#pragma once

#include <stdint.h>
#include <stddef.h>

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

/* A file descriptor that turns readable when webby_pump() has work: a message from a page's process (a localStorage
 * read or a cookie write, which the page waits for), a posted event or a timer coming due. Watch it in the front
 * end's main loop, read (and drop) its 8 bytes and call webby_pump(). Watched from a thread libwebby starts on the
 * first call, and re-armed by each webby_pump(), so it fires at most once per pump. -1 if it can't be set up. */
WEBBY_API int webby_wake_fd(void);

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
 * Takes effect at once, and it is process-wide: every view and every page
 * opened later gets it. */
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

/* Asks the page's JavaScript heap to collect garbage soon (the WebContent
 * process does it once the current task is done). For pages put away and for
 * when the system runs short of memory. */
WEBBY_API void webby_view_collect_garbage(WebbyView*);

/* Find in page. webby_view_find() searches the page for `query` (empty
 * clears the search), highlights every match and scrolls the first one into
 * view; next/previous move the active match (wrapping around), and end clears
 * the highlights and leaves the active match selected. Results arrive
 * asynchronously: find_current() is the 1-based active match (0 when there is
 * none) and find_total() the number of matches; both change
 * together with state_serial(). */
WEBBY_API void webby_view_find(WebbyView*, char const* query, int case_sensitive);
WEBBY_API void webby_view_find_next(WebbyView*);
WEBBY_API void webby_view_find_previous(WebbyView*);
WEBBY_API void webby_view_find_end(WebbyView*);
WEBBY_API int webby_view_find_current(WebbyView*);
WEBBY_API int webby_view_find_total(WebbyView*);

/* Views the page opened (links with target=_blank, window.open()). Each one
 * is a full view with its own page; the UI should show it as a new tab.
 * webby_view_take_new_view() returns the oldest waiting one (the caller owns
 * it and frees it with webby_view_destroy) or NULL; state_serial() changes when
 * one arrives. It is sized like its opener until the UI resizes it.
 * webby_view_close_requested() is 1 once the page called window.close(). */
WEBBY_API WebbyView* webby_view_take_new_view(WebbyView*);
WEBBY_API int webby_view_close_requested(WebbyView*);

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

/* File inputs. When a page opens a file picker (<input type=file>, showPicker()),
 * the view holds it until the UI answers. webby_view_file_picker_request() is ""
 * when nothing is waiting, else JSON (it changes together with state_serial()):
 *   { "id": n, "multiple": bool, "accept": [ "text/plain", ".pdf", ... ] }
 * "accept" holds MIME types (a whole type is the type, a slash and a star, as in
 * the accept attribute) and extensions; it is empty when any file will do. Answer with
 * webby_view_file_picker_respond(): a JSON array of file paths to hand the page,
 * "[]" or NULL to cancel. The files are opened during the call, so they can be
 * deleted right after it. */
WEBBY_API char const* webby_view_file_picker_request(WebbyView*);
WEBBY_API void webby_view_file_picker_respond(WebbyView*, char const* paths_json);

/* Messages from the browser's own page scripts. A page script calls
 * prompt(prefix + text); the view answers it at once (as if cancelled) and
 * queues `text` instead of showing a dialog. webby_view_next_message() returns
 * and removes the oldest queued text, "" when there is none (valid until the
 * next call). An empty prefix (the default) turns this off. */
WEBBY_API void webby_view_set_message_prefix(WebbyView*, char const* prefix);
WEBBY_API char const* webby_view_next_message(WebbyView*);

/* Site permissions. When a site asks for a permission-gated feature ("geolocation":
 * navigator.geolocation, or "microphone": getUserMedia()), the view holds the request until
 * the UI answers. webby_view_permission_request() is "" when nothing is
 * waiting, else JSON (it changes together with state_serial()):
 *   { "id": n, "permission": "geolocation", "origin": "https://example.com" }
 * "origin" is the top-level page's. Answer with webby_view_permission_respond();
 * the answer also covers every other request waiting from that origin for that
 * permission. The UI keeps any remembered answers: every request comes here. */
WEBBY_API char const* webby_view_permission_request(WebbyView*);
WEBBY_API void webby_view_permission_respond(WebbyView*, uint64_t id, int granted);

/* Location. Ladybird has no location source here; the UI supplies one.
 * webby_geolocation_wanted() says what pages are waiting for (flags below; 0
 * when nothing, so the UI can stop its location service). Hand positions to
 * webby_geolocation_set_position(): latitude and longitude in degrees, accuracy
 * in metres, the rest NaN when unknown (altitude and its accuracy in metres,
 * heading in degrees from north, speed in m/s). It answers every one-off
 * request and updates every watch. webby_geolocation_set_error() fails the
 * one-off requests and tells watches. */
enum {
    WEBBY_GEOLOCATION_REQUESTED = 1,
    WEBBY_GEOLOCATION_WATCHING = 2,
};
enum {
    WEBBY_GEOLOCATION_ERROR_PERMISSION_DENIED = 1,
    WEBBY_GEOLOCATION_ERROR_POSITION_UNAVAILABLE = 2,
    WEBBY_GEOLOCATION_ERROR_TIMEOUT = 3,
};
WEBBY_API int webby_geolocation_wanted(void);
WEBBY_API void webby_geolocation_set_position(double latitude, double longitude, double accuracy,
    double altitude, double altitude_accuracy, double heading, double speed);
WEBBY_API void webby_geolocation_set_error(int code, char const* message);

/* JavaScript dialogs. A page's alert(), confirm() or prompt() waits until the
 * UI answers. webby_view_dialog() is "" when none is open, else JSON (it changes
 * together with state_serial()):
 *   { "id": n, "type": "alert" | "confirm" | "prompt", "message": "...",
 *     "default": "..." (prompt only) }
 * Answer with webby_view_dialog_respond(): accepted = 0 for Cancel (or closing
 * it); for a prompt, `text` is what the user typed (ignored otherwise). */
WEBBY_API char const* webby_view_dialog(WebbyView*);
WEBBY_API void webby_view_dialog_respond(WebbyView*, uint64_t id, int accepted, char const* text);

/* Site data. webby_clear_site_data() deletes the cookies of the site of `url`
 * (its host, parent domains and subdomains, and cookies frames set under it)
 * and its origin's localStorage, IndexedDB and Cache Storage, and clears the
 * sessionStorage of views showing that origin. Reload such pages after it.
 * webby_clear_browsing_data() clears what `what` names (flags below) that was
 * used since `since_ms` (Unix time in milliseconds; 0 for all time); it
 * finishes in the background. */
enum {
    WEBBY_BROWSING_DATA_CACHE = 1,
    WEBBY_BROWSING_DATA_SITE_DATA = 2,
    WEBBY_BROWSING_DATA_HISTORY = 4,
};
WEBBY_API void webby_clear_site_data(char const* url);
WEBBY_API void webby_clear_browsing_data(int64_t since_ms, int what);

/* Clipboard. Ladybird keeps its own clipboard: Ctrl+C / Ctrl+X in a page and
 * navigator.clipboard.write*() put text there, Ctrl+V and
 * navigator.clipboard.read*() take it from there. webby_clipboard_serial()
 * changes whenever a page copies; the UI then puts webby_clipboard_text()
 * (UTF-8, valid until the next call) on the system clipboard. Before a paste the
 * UI hands the system clipboard's text to webby_clipboard_set_text(), which
 * doesn't change the serial. When the system clipboard holds an image and no
 * text (a screenshot, "Copy image"), the UI hands it in encoded as `mime`
 * (image/png, the only image type pages get from a paste or
 * navigator.clipboard) with webby_clipboard_set_image() instead; the paste
 * event then carries it in clipboardData.files / items. */
WEBBY_API uint64_t webby_clipboard_serial(void);
WEBBY_API char const* webby_clipboard_text(void);
WEBBY_API void webby_clipboard_set_text(char const* text);
WEBBY_API void webby_clipboard_set_image(char const* mime, uint8_t const* data, size_t size);

/* Downloads. Ladybird saves what pages download (Content-Disposition:
 * attachment, <a download>, types it can't show, blob: URLs) into
 * $XDG_DOWNLOAD_DIR or ~/Downloads without asking, created when missing.
 * webby_downloads_set_directory() points that elsewhere (e.g. an Android app's
 * own folder); it is process-wide.
 * webby_downloads_serial() changes whenever a download is added, makes
 * progress, finishes or is removed; webby_downloads_json() then lists them,
 * oldest first, valid until the next call:
 *   [{ "id": n, "url", "path" (where the finished file is), "status":
 *      "in_progress" | "paused" | "completed" | "canceled" | "failed",
 *      "received": bytes, "total": bytes or -1, "rate": bytes/s or -1,
 *      "remaining": seconds or -1, "error": text or "", "canResume": bool,
 *      "private": bool, "created": unix ms }]
 * webby_downloads_start() downloads `url` itself (Save link as, Save image);
 * returns its id, or 0 when it couldn't start. webby_downloads_clear() forgets
 * every download that isn't in progress or paused (the files stay). */
WEBBY_API void webby_downloads_set_directory(char const* path);
WEBBY_API uint64_t webby_downloads_serial(void);
WEBBY_API char const* webby_downloads_json(void);
WEBBY_API uint64_t webby_downloads_start(char const* url, int is_private);
WEBBY_API void webby_downloads_cancel(uint64_t id);
WEBBY_API void webby_downloads_pause(uint64_t id);
WEBBY_API void webby_downloads_resume(uint64_t id);
WEBBY_API void webby_downloads_clear(void);

/* On-screen keyboards. webby_view_ime_state() describes the focused text field
 * as JSON (it changes together with state_serial(); valid until the next call):
 *   { "enabled": bool, "before": text before the caret, "after": text after it,
 *     "cursor": n, "anchor": n }
 * "enabled" is false when nothing editable has focus. webby_view_ime_commit()
 * inserts `text` at the caret, first replacing replacement_length UTF-16 units
 * that start replacement_start units from the caret (negative: before it).
 * webby_view_ime_set_marked() shows `text` as the composition in progress (""
 * ends it). */
WEBBY_API char const* webby_view_ime_state(WebbyView*);
WEBBY_API void webby_view_ime_commit(WebbyView*, char const* text, int replacement_start, int replacement_length);
WEBBY_API void webby_view_ime_set_marked(WebbyView*, char const* text);

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

/* Ad and tracker blocking: Ladybird's content blocker (EasyList and EasyPrivacy,
 * kept up to date by Ladybird in the profile's ContentBlocking/Lists). Front ends
 * switch it on before webby_init() through the profile's Settings.json; this
 * turns it on or off while running, in every open page. */
WEBBY_API void webby_set_content_blocking(int enabled);

#ifdef __cplusplus
}
#endif
