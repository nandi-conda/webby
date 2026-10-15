## Small helpers shared by the tabs feature's modules.

import std/[os, strutils, uri]
import ../../browser
from nimkit/core as kit import nil

proc gtk_widget_get_parent*(w: Widget): Widget {.importc, cdecl.}
proc gdk_event_copy*(e: GEvent): GEvent {.importc, cdecl.}
proc gtk_menu_shell_insert*(m, item: Widget, pos: cint) {.importc, cdecl.}
proc gtk_orientable_set_orientation*(w: Widget, o: cint) {.importc, cdecl.}
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

proc toast*(text: string) =
  ## A message floating over the bottom of the page for a few seconds.
  kit.toast(text)

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
      # This process swapped in its own throwaway profile; the new one makes its own from the original flags.
      env.add k & "=" & originalLadybirdArgs.join(" ")
    else: env.add k & "=" & v
  let argv = allocCStringArray(args)
  let envp = allocCStringArray(env)
  var pid: cint
  # G_SPAWN_DO_NOT_REAP_CHILD, then a child watch reaps it when it exits.
  if g_spawn_async(nil, argv, envp, 2, nil, nil, addr pid, nil) == 0: toast("Could not open an incognito window")
  else: discard g_child_watch_add(pid, proc (pid, status: cint, d: pointer) {.cdecl.} = g_spawn_close_pid(pid), nil)
  deallocCStringArray(argv)
  deallocCStringArray(envp)
