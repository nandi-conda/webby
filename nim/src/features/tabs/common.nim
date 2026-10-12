## Small helpers shared by the tabs feature's modules.

import std/[os, strutils, uri]
import ../../browser

proc gtk_widget_get_parent*(w: Widget): Widget {.importc, cdecl.}
proc gdk_event_copy*(e: GEvent): GEvent {.importc, cdecl.}
proc gtk_menu_shell_insert*(m, item: Widget, pos: cint) {.importc, cdecl.}
proc gtk_orientable_set_orientation*(w: Widget, o: cint) {.importc, cdecl.}
proc gtk_clipboard_wait_is_text_available*(cb: pointer): gboolean {.importc, cdecl.}
proc g_spawn_async(dir: cstring, argv, envp: cstringArray, flags: cint, setup, data: pointer, pid: ptr cint,
  err: pointer): gboolean {.importc, cdecl.}
proc g_child_watch_add(pid: cint, fn, data: pointer): cuint {.importc, cdecl.}
proc g_spawn_close_pid(pid: cint) {.importc, cdecl.}

proc connectAction*(w: Widget, signal: string, action: proc () {.closure.}) =
  ## Runs `action` on a signal without arguments of interest ("clicked", "activate", "toggled"); the closure lives
  ## as long as the widget.
  let cb = new(proc ())
  cb[] = action
  GC_ref(cb)
  connect(w, signal, proc (w: Widget, d: pointer) {.cdecl.} = cast[ref proc ()](d)[](), cast[pointer](cb))
  connect(w, "destroy", proc (w: Widget, d: pointer) {.cdecl.} = GC_unref(cast[ref proc ()](d)), cast[pointer](cb))

proc gtk_window_get_position(w: Widget, x, y: ptr cint) {.importc, cdecl.}
proc gtk_window_move(w: Widget, x, y: cint) {.importc, cdecl.}

var toastWindow, toastLabel: Widget
var toastTimer: cuint

proc toast*(text: string) =
  ## A message floating over the bottom of the page for a few seconds.
  if toastWindow == nil:
    toastWindow = gtk_window_new(1)   # GTK_WINDOW_POPUP
    gtk_window_set_transient_for(toastWindow, window)
    toastLabel = gtk_label_new("")
    addClass(toastWindow, "webby-toast")
    gtk_label_set_ellipsize(toastLabel, PANGO_ELLIPSIZE_END)
    gtk_label_set_max_width_chars(toastLabel, 90)
    for (f, m) in [(gtk_widget_set_margin_start, 14), (gtk_widget_set_margin_end, 14), (gtk_widget_set_margin_top, 8),
                   (gtk_widget_set_margin_bottom, 8)]: f(toastLabel, m.cint)
    gtk_container_add(toastWindow, toastLabel)
  gtk_label_set_text(toastLabel, text.cstring)
  gtk_widget_show_all(toastWindow)
  var x, y, w, h, tw, th: cint
  gtk_window_get_position(window, addr x, addr y)
  gtk_window_get_size(window, addr w, addr h)
  gtk_window_get_size(toastWindow, addr tw, addr th)
  gtk_window_move(toastWindow, x + (w - tw) div 2, y + h - th - 32)
  if toastTimer != 0: discard g_source_remove(toastTimer)
  toastTimer = g_timeout_add(4000, proc (d: pointer): gboolean {.cdecl.} =
    toastTimer = 0
    gtk_widget_hide(toastWindow)
    0, nil)

proc isBlank*(t: Tab): bool = t == nil or t.url.len == 0 or t.url == "about:blank"

proc hostOf*(url: string): string =
  try: parseUri(url).hostname except CatchableError: ""

proc tabTitle*(title, url: string): string =
  ## The page title, else the URL without its scheme, else "New tab" (tab_strip.dart).
  if title.strip.len > 0: return title.strip
  if url.len == 0 or url == "about:blank": return "New tab"
  let i = url.find("://")
  if i > 0 and url[0 ..< i].allCharsInSet({'a'..'z'}): url[i + 3 .. ^1] else: url

proc openInBackgroundTab*(url: string) =
  ## A new tab next to the current one, not switched to (like a middle-clicked link). App windows load in place.
  let t = currentTab()
  if appUrl.len > 0 or t == nil:
    t.loadUrl(url)
    return
  discard openTab(url, focus = false, index = activeIndex + 1)

proc openIncognitoWindow*(url = "") =
  ## Starts `<this exe> --incognito [url]`, its own process with an engine that keeps nothing (incognito.dart).
  var args = @[getAppFilename(), "--incognito"]
  if url.len > 0: args.add url
  var env: seq[string]
  for k, v in envPairs():
    if k.startsWith("WEBBY_APP_"): continue
    if k == "WEBBY_LADYBIRD_ARGS" and incognito:
      # This process added the incognito engine flags itself; the new one adds them again.
      var kept: seq[string]
      for w in v.splitWhitespace:
        if w notin ["--temporary-profile", "--disable-sql-database", "--disable-http-disk-cache"]: kept.add w
      env.add k & "=" & kept.join(" ")
    else: env.add k & "=" & v
  let argv = allocCStringArray(args)
  let envp = allocCStringArray(env)
  var pid: cint
  # G_SPAWN_DO_NOT_REAP_CHILD, then a child watch reaps it when it exits.
  if g_spawn_async(nil, argv, envp, 2, nil, nil, addr pid, nil) == 0: toast("Could not open an incognito window")
  else: discard g_child_watch_add(pid, proc (pid, status: cint, d: pointer) {.cdecl.} = g_spawn_close_pid(pid), nil)
  deallocCStringArray(argv)
  deallocCStringArray(envp)
