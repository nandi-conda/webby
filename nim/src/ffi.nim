## libwebby.so bindings (native/webby_ffi.h). Loaded at run time from $WEBBY_LADYBIRD_PREFIX/lib, like the Flutter
## app, so the binary doesn't link against a particular runtime. Every call must come from the GTK thread.

import std/[dynlib, os]

type View* = pointer

const
  colorSchemeAuto* = 0
  colorSchemeLight* = 1
  colorSchemeDark* = 2
  geolocationRequested* = 1
  geolocationWatching* = 2
  browsingDataCache* = 1
  browsingDataSiteData* = 2
  browsingDataHistory* = 4
  mouseDown* = 0
  mouseUp* = 1
  mouseMove* = 2
  mouseLeave* = 3

var
  webby_init*: proc (prefix: cstring): cint {.cdecl, gcsafe.}
  webby_pump*: proc (): cint {.cdecl, gcsafe.}
  webby_view_create*: proc (w, h: cint, ratio: cdouble): View {.cdecl, gcsafe.}
  webby_view_destroy*: proc (v: View) {.cdecl, gcsafe.}
  webby_view_load*: proc (v: View, url: cstring) {.cdecl, gcsafe.}
  webby_view_go_back*: proc (v: View) {.cdecl, gcsafe.}
  webby_view_go_forward*: proc (v: View) {.cdecl, gcsafe.}
  webby_view_reload*: proc (v: View) {.cdecl, gcsafe.}
  webby_view_stop*: proc (v: View) {.cdecl, gcsafe.}
  webby_view_resize*: proc (v: View, w, h: cint, ratio: cdouble) {.cdecl, gcsafe.}
  webby_view_set_focus*: proc (v: View, on: cint) {.cdecl, gcsafe.}
  webby_view_run_javascript*: proc (v: View, source: cstring) {.cdecl, gcsafe.}
  webby_view_set_color_scheme*: proc (v: View, scheme: cint) {.cdecl, gcsafe.}
  webby_view_set_visible*: proc (v: View, on: cint) {.cdecl, gcsafe.}
  webby_view_collect_garbage*: proc (v: View) {.cdecl, gcsafe.}
  webby_view_take_new_view*: proc (v: View): View {.cdecl, gcsafe.}
  webby_view_close_requested*: proc (v: View): cint {.cdecl, gcsafe.}
  webby_view_frame_serial*: proc (v: View): uint64 {.cdecl, gcsafe.}
  webby_view_frame_pixels*: proc (v: View): pointer {.cdecl, gcsafe.}
  webby_view_frame_width*: proc (v: View): cint {.cdecl, gcsafe.}
  webby_view_frame_height*: proc (v: View): cint {.cdecl, gcsafe.}
  webby_view_state_serial*: proc (v: View): uint64 {.cdecl, gcsafe.}
  webby_view_url*: proc (v: View): cstring {.cdecl, gcsafe.}
  webby_view_title*: proc (v: View): cstring {.cdecl, gcsafe.}
  webby_view_hovered_link*: proc (v: View): cstring {.cdecl, gcsafe.}
  webby_view_is_loading*: proc (v: View): cint {.cdecl, gcsafe.}
  webby_view_can_go_back*: proc (v: View): cint {.cdecl, gcsafe.}
  webby_view_can_go_forward*: proc (v: View): cint {.cdecl, gcsafe.}
  webby_view_cursor*: proc (v: View): cint {.cdecl, gcsafe.}
  webby_view_webauthn_prompt*: proc (v: View): cstring {.cdecl, gcsafe.}
  webby_view_webauthn_respond*: proc (v: View, accepted, account: cint) {.cdecl, gcsafe.}
  webby_view_file_picker_request*: proc (v: View): cstring {.cdecl, gcsafe.}
  webby_view_file_picker_respond*: proc (v: View, pathsJson: cstring) {.cdecl, gcsafe.}
  webby_view_set_message_prefix*: proc (v: View, prefix: cstring) {.cdecl, gcsafe.}
  webby_view_next_message*: proc (v: View): cstring {.cdecl, gcsafe.}
  webby_view_permission_request*: proc (v: View): cstring {.cdecl, gcsafe.}
  webby_view_permission_respond*: proc (v: View, id: uint64, granted: cint) {.cdecl, gcsafe.}
  webby_geolocation_wanted*: proc (): cint {.cdecl, gcsafe.}
  webby_geolocation_set_position*: proc (lat, lon, accuracy, altitude, altitudeAccuracy, heading, speed: cdouble) {.cdecl, gcsafe.}
  webby_geolocation_set_error*: proc (code: cint, message: cstring) {.cdecl, gcsafe.}
  webby_view_dialog*: proc (v: View): cstring {.cdecl, gcsafe.}
  webby_view_dialog_respond*: proc (v: View, id: uint64, accepted: cint, text: cstring) {.cdecl, gcsafe.}
  webby_clear_site_data*: proc (url: cstring) {.cdecl, gcsafe.}
  webby_clear_browsing_data*: proc (sinceMs: int64, what: cint) {.cdecl, gcsafe.}
  webby_clipboard_serial*: proc (): uint64 {.cdecl, gcsafe.}
  webby_clipboard_text*: proc (): cstring {.cdecl, gcsafe.}
  webby_clipboard_set_text*: proc (text: cstring) {.cdecl, gcsafe.}
  webby_view_ime_state*: proc (v: View): cstring {.cdecl, gcsafe.}
  webby_view_ime_commit*: proc (v: View, text: cstring, replacementStart, replacementLength: cint) {.cdecl, gcsafe.}
  webby_view_ime_set_marked*: proc (v: View, text: cstring) {.cdecl, gcsafe.}
  webby_passkeys_use_vault*: proc (json: cstring): cint {.cdecl, gcsafe.}
  webby_passkeys_serial*: proc (): uint64 {.cdecl, gcsafe.}
  webby_passkeys_export*: proc (): cstring {.cdecl, gcsafe.}
  webby_passkeys_remove*: proc (credentialId: cstring): cint {.cdecl, gcsafe.}
  webby_passkeys_delete_file*: proc (): cint {.cdecl, gcsafe.}
  webby_view_mouse_event*: proc (v: View, kind, x, y, button, buttons, modifiers, clicks: cint) {.cdecl, gcsafe.}
  webby_view_wheel_event*: proc (v: View, x, y: cint, dx, dy: cdouble, precise, modifiers: cint) {.cdecl, gcsafe.}
  webby_view_key_event*: proc (v: View, down, keyCode, modifiers: cint, codePoint: uint32, repeat: cint) {.cdecl, gcsafe.}
  webby_set_offline*: proc (offline: cint) {.cdecl, gcsafe.}
  # Optional (nil with a runtime older than 2026.10.14.2): native find in page.
  webby_set_content_blocking*: proc (on: cint) {.cdecl, gcsafe.}  ## optional: runtimes since 2026.10.15
  webby_view_find*: proc (v: View, query: cstring, caseSensitive: cint) {.cdecl, gcsafe.}
  webby_view_find_next*: proc (v: View) {.cdecl, gcsafe.}
  webby_view_find_previous*: proc (v: View) {.cdecl, gcsafe.}
  webby_view_find_end*: proc (v: View) {.cdecl, gcsafe.}
  webby_view_find_current*: proc (v: View): cint {.cdecl, gcsafe.}
  webby_view_find_total*: proc (v: View): cint {.cdecl, gcsafe.}
  # Optional (nil with a runtime older than 2026.10.15.1): the engine's download list (features/downloads).
  webby_downloads_set_directory*: proc (path: cstring) {.cdecl, gcsafe.}
  webby_downloads_serial*: proc (): uint64 {.cdecl, gcsafe.}
  webby_downloads_json*: proc (): cstring {.cdecl, gcsafe.}
  webby_downloads_start*: proc (url: cstring, private: cint): uint64 {.cdecl, gcsafe.}
  webby_downloads_cancel*: proc (id: uint64) {.cdecl, gcsafe.}
  webby_downloads_pause*: proc (id: uint64) {.cdecl, gcsafe.}
  webby_downloads_resume*: proc (id: uint64) {.cdecl, gcsafe.}
  webby_downloads_clear*: proc () {.cdecl, gcsafe.}

proc ladybirdPrefix*(): string =
  ## $WEBBY_LADYBIRD_PREFIX, else a runtime bundled next to the executable (<exe dir>/lib/ladybird).
  result = getEnv("WEBBY_LADYBIRD_PREFIX")
  if result.len == 0: result = getAppDir() / "lib" / "ladybird"

proc loadWebbyLib*(path: string) =
  ## Loads libwebby.so from `path` (a bare file name searches the library path, as on Android).
  let lib = loadLib(path)
  if lib == nil:
    proc dlerror(): cstring {.importc, header: "<dlfcn.h>".}
    let why = $dlerror()
    quit "Can't load libwebby.so from " & path & (if why.len > 0: " (" & why & ")" else: "") &
      ". Set WEBBY_LADYBIRD_PREFIX to the Ladybird runtime."
  template sym(p: untyped) = p = cast[typeof(p)](lib.checkedSymAddr(astToStr(p)))
  sym webby_init
  sym webby_pump
  sym webby_view_create
  sym webby_view_destroy
  sym webby_view_load
  sym webby_view_go_back
  sym webby_view_go_forward
  sym webby_view_reload
  sym webby_view_stop
  sym webby_view_resize
  sym webby_view_set_focus
  sym webby_view_run_javascript
  sym webby_view_set_color_scheme
  sym webby_view_set_visible
  sym webby_view_collect_garbage
  sym webby_view_take_new_view
  sym webby_view_close_requested
  sym webby_view_frame_serial
  sym webby_view_frame_pixels
  sym webby_view_frame_width
  sym webby_view_frame_height
  sym webby_view_state_serial
  sym webby_view_url
  sym webby_view_title
  sym webby_view_hovered_link
  sym webby_view_is_loading
  sym webby_view_can_go_back
  sym webby_view_can_go_forward
  sym webby_view_cursor
  sym webby_view_webauthn_prompt
  sym webby_view_webauthn_respond
  sym webby_view_file_picker_request
  sym webby_view_file_picker_respond
  sym webby_view_set_message_prefix
  sym webby_view_next_message
  sym webby_view_permission_request
  sym webby_view_permission_respond
  sym webby_geolocation_wanted
  sym webby_geolocation_set_position
  sym webby_geolocation_set_error
  sym webby_view_dialog
  sym webby_view_dialog_respond
  sym webby_clear_site_data
  sym webby_clear_browsing_data
  sym webby_clipboard_serial
  sym webby_clipboard_text
  sym webby_clipboard_set_text
  sym webby_view_ime_state
  sym webby_view_ime_commit
  sym webby_view_ime_set_marked
  sym webby_passkeys_use_vault
  sym webby_passkeys_serial
  sym webby_passkeys_export
  sym webby_passkeys_remove
  sym webby_passkeys_delete_file
  sym webby_view_mouse_event
  sym webby_view_wheel_event
  sym webby_view_key_event
  sym webby_set_offline
  template optional(p: untyped) = p = cast[typeof(p)](lib.symAddr(astToStr(p)))
  optional webby_view_find
  optional webby_view_find_next
  optional webby_view_find_previous
  optional webby_view_find_end
  optional webby_view_find_current
  optional webby_view_find_total
  optional webby_set_content_blocking
  optional webby_downloads_set_directory
  optional webby_downloads_serial
  optional webby_downloads_json
  optional webby_downloads_start
  optional webby_downloads_cancel
  optional webby_downloads_pause
  optional webby_downloads_resume
  optional webby_downloads_clear

proc hasNativeFind*(): bool =
  ## Whether the runtime finds in page itself (webby_view_find); else features/find runs a page script.
  webby_view_find != nil and webby_view_find_total != nil

proc loadWebby*(prefix: string) = loadWebbyLib(prefix / "lib" / "libwebby.so")

proc str*(p: cstring): string = (if p == nil: "" else: $p)
