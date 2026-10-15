## The page's right-click menu (context_menu.dart). The Flutter app's page script (read from context_menu.dart at
## compile time) reports what was clicked with a {"type": "contextmenu", ...} message; a GtkMenu offers what fits.
## `pageContextMenuHook` is set to `showPageMenu` unless another feature set its own.

import std/[base64, os, strutils, uri]
when not defined(android): import std/dynlib
from std/unicode import toRunes, runeLen, `$`
import ../../browser
from nimkit/core as kit import nil
import common
when defined(android): import nimkit/services

proc dartString(dart, head: string): string =
  ## The body of a ''' string in Dart source that follows `head`, with Dart's \\ and \$ escapes undone.
  let start = dart.find(head) + head.len
  result = dart[start ..< dart.find("''';", start)]
  result = result.replace("\\\\", "\x01").replace("\\$", "$").replace("\x01", "\\")

const contextMenuDart = staticRead("../../../../app/lib/src/context_menu.dart")
const menuScript = dartString(contextMenuDart, "String contextMenuPageScript(String prefix) => '''")
const inspectWrapper = dartString(contextMenuDart, "String inspectScriptWith(String erudaSource) => '''")
const erudaSource = staticRead("../../../../app/assets/eruda/eruda.js")


proc pageScript(t: Tab): string =
  if t.messagePrefix.len == 0: return ""
  menuScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix))

proc actionScript(action: string, text = ""): string =
  "window.__webbyContextMenu && window.__webbyContextMenu.act(" & $(%action) & ", " &
    (if text.len > 0: $(%text) else: "null") & ");"

proc inspectScript(): string = inspectWrapper.replace("$erudaSource", erudaSource)

proc webUrl(url: string): string =
  ## Only links the browser would follow; javascript: and the like are dropped.
  let i = url.find(':')
  if i > 0 and url[0 ..< i].toLowerAscii in ["http", "https", "file", "data", "about"]: url else: ""

# ---------------------------------------------------------------------------------------------------------------
# Saving images

proc downloadsDirectory(): string =
  let x = getEnv("XDG_DOWNLOAD_DIR")
  if x.len > 0: x else: getHomeDir() / "Downloads"

proc imageFileName(url, mimeType: string): string =
  ## The URL's last path segment, with an extension from `mimeType` if it has none.
  if not url.startsWith("data:"):
    for seg in parseUri(url).path.split('/'):
      if seg.len > 0: result = decodeUrl(seg)
  var clean = ""
  for c in result: clean.add(if c in {'/', '\\'} or c < ' ': '_' else: c)
  result = clean
  if result.len == 0 or result.startsWith("."): result = "image" & result
  if '.' notin result:
    const ext = {"image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
      "image/svg+xml": "svg", "image/avif": "avif", "image/bmp": "bmp", "image/x-icon": "ico"}
    for (m, e) in ext:
      if m == mimeType: result.add "." & e

proc freeFile(dir, name: string): string =
  let dot = name.rfind('.')
  let stem = if dot > 0: name[0 ..< dot] else: name
  let ext = if dot > 0: name[dot .. ^1] else: ""
  result = dir / name
  var i = 1
  while fileExists(result):
    result = dir / (stem & " (" & $i & ")" & ext)
    inc i

proc writeImage(url, mimeType, bytes: string): string =
  let dir = downloadsDirectory()
  createDir(dir)
  let path = freeFile(dir, imageFileName(url, mimeType))
  writeFile(path, bytes)
  "Saved " & path

# http(s) images come through the runtime's libcurl (multi interface, polled from the GTK loop). Nim's own SSL would
# load the system's OpenSSL ahead of the one Ladybird needs.

when defined(android):
  # No libcurl in the APK: Java's HTTP through nimkit (Host.http).
  proc download(url: string) =
    request("GET", url, proc (r: Response) =
      let mime = r.header("content-type").split(';')[0].strip
      toast(
        if r.status == 0: "Could not save the image: " & r.error
        elif r.status != 200: "Could not save the image (HTTP " & $r.status & ")"
        else:
          try: writeImage(url, mime, r.body) except CatchableError as e: "Could not save the image: " & e.msg),
      headers = @[("User-Agent", "webby")])

else:
  type
    Download = ref object
      easy: pointer
      url, body: string
    CurlMsg {.bycopy.} = object
      msg: cint
      easy: pointer
      result: cint   # the first member of the data union

  var
    curl: LibHandle
    curlMulti: pointer
    downloads: seq[Download]
    curl_easy_init: proc (): pointer {.cdecl, gcsafe.}
    curl_easy_setopt_ptr: proc (h: pointer, opt: cint, p: pointer): cint {.cdecl, gcsafe.}
    curl_easy_setopt_long: proc (h: pointer, opt: cint, v: clong): cint {.cdecl, gcsafe.}
    curl_easy_getinfo_ptr: proc (h: pointer, info: cint, p: pointer): cint {.cdecl, gcsafe.}
    curl_easy_cleanup: proc (h: pointer) {.cdecl, gcsafe.}
    curl_multi_init: proc (): pointer {.cdecl, gcsafe.}
    curl_multi_add_handle: proc (m, h: pointer): cint {.cdecl, gcsafe.}
    curl_multi_remove_handle: proc (m, h: pointer): cint {.cdecl, gcsafe.}
    curl_multi_perform: proc (m: pointer, running: ptr cint): cint {.cdecl, gcsafe.}
    curl_multi_info_read: proc (m: pointer, left: ptr cint): ptr CurlMsg {.cdecl, gcsafe.}
    curl_easy_strerror: proc (code: cint): cstring {.cdecl, gcsafe.}

  proc loadCurl(): bool =
    if curl != nil: return true
    curl = loadLib(ladybirdPrefix() / "lib" / "libcurl.so.4")
    if curl == nil: curl = loadLib("libcurl.so.4")
    if curl == nil: return false
    template sym(p: untyped, name: string) = p = cast[typeof(p)](curl.checkedSymAddr(name))
    sym curl_easy_init, "curl_easy_init"
    sym curl_easy_setopt_ptr, "curl_easy_setopt"
    sym curl_easy_setopt_long, "curl_easy_setopt"
    sym curl_easy_getinfo_ptr, "curl_easy_getinfo"
    sym curl_easy_cleanup, "curl_easy_cleanup"
    sym curl_easy_strerror, "curl_easy_strerror"
    sym curl_multi_init, "curl_multi_init"
    sym curl_multi_add_handle, "curl_multi_add_handle"
    sym curl_multi_remove_handle, "curl_multi_remove_handle"
    sym curl_multi_perform, "curl_multi_perform"
    sym curl_multi_info_read, "curl_multi_info_read"
    curlMulti = curl_multi_init()
    true

  proc onCurlData(data: ptr char, size, n: csize_t, d: pointer): csize_t {.cdecl.} =
    let dl = cast[Download](d)
    let len = int(size * n)
    if len > 0:
      let at = dl.body.len
      dl.body.setLen(at + len)
      copyMem(addr dl.body[at], data, len)
    csize_t(len)

  proc pollDownloads(d: pointer): gboolean {.cdecl.} =
    var running, left: cint
    discard curl_multi_perform(curlMulti, addr running)
    while true:
      let m = curl_multi_info_read(curlMulti, addr left)
      if m == nil: break
      if m.msg != 1: continue   # CURLMSG_DONE
      var dl: Download
      for x in downloads:
        if x.easy == m.easy: dl = x
      if dl == nil: continue
      var code: clong
      var ctype: cstring
      discard curl_easy_getinfo_ptr(dl.easy, 0x200002, addr code)    # CURLINFO_RESPONSE_CODE
      discard curl_easy_getinfo_ptr(dl.easy, 0x100012, addr ctype)   # CURLINFO_CONTENT_TYPE
      let mime = if ctype == nil: "" else: ($ctype).split(';')[0].strip
      let message =
        if m.result != 0: "Could not save the image: " & $curl_easy_strerror(m.result)
        elif code != 200: "Could not save the image (HTTP " & $code & ")"
        else:
          try: writeImage(dl.url, mime, dl.body) except CatchableError as e: "Could not save the image: " & e.msg
      discard curl_multi_remove_handle(curlMulti, dl.easy)
      curl_easy_cleanup(dl.easy)
      downloads.delete(downloads.find(dl))
      GC_unref(dl)
      toast(message)
    if downloads.len == 0: 0 else: 1

  proc download(url: string) =
    if not loadCurl():
      toast("Could not save the image: libcurl not found")
      return
    let dl = Download(url: url, easy: curl_easy_init())
    GC_ref(dl)
    downloads.add dl
    discard curl_easy_setopt_ptr(dl.easy, 10002, url.cstring)            # CURLOPT_URL (copied by curl)
    discard curl_easy_setopt_ptr(dl.easy, 10018, "webby".cstring)        # CURLOPT_USERAGENT
    discard curl_easy_setopt_long(dl.easy, 52, 1)                        # CURLOPT_FOLLOWLOCATION
    discard curl_easy_setopt_long(dl.easy, 13, 60)                       # CURLOPT_TIMEOUT
    discard curl_easy_setopt_ptr(dl.easy, 20011, cast[pointer](onCurlData))  # CURLOPT_WRITEFUNCTION
    discard curl_easy_setopt_ptr(dl.easy, 10001, cast[pointer](dl))     # CURLOPT_WRITEDATA
    discard curl_multi_add_handle(curlMulti, dl.easy)
    if downloads.len == 1: discard g_timeout_add(20, pollDownloads, nil)

proc saveImage(url: string) =
  ## Saves the image at `url` (http(s), data: or file:) into ~/Downloads (or $XDG_DOWNLOAD_DIR).
  try:
    if url.startsWith("data:"):
      let comma = url.find(',')
      let head = url[5 ..< comma]
      let data = url[comma + 1 .. ^1]
      let bytes = if head.endsWith(";base64"): decode(data) else: decodeUrl(data, false)
      toast(writeImage(url, head.split(';')[0], bytes))
    elif url.startsWith("file:"):
      let path = decodeUrl(parseUri(url).path)
      toast(writeImage(url, "", readFile(path)))
    elif url.startsWith("http:") or url.startsWith("https:"):
      download(url)
    else:
      toast("Can't save images from " & url.split(':')[0] & ": addresses")
  except CatchableError as e:
    toast("Could not save the image: " & e.msg)

# ---------------------------------------------------------------------------------------------------------------
# The menu

var
  menuTab: Tab            # the tab right-clicked, until its report arrives or the fallback fires
  menuAt: (float, float)  # where, in the page canvas's pixels
  fallback: Timer

proc clearPending() =
  cancel(fallback)
  fallback = nil
  menuTab = nil

proc ellipsize(text: string, n: int): string =
  let one = text.splitWhitespace.join(" ")
  if one.runeLen <= n: one else: $one.toRunes[0 ..< n] & "…"


proc showPageMenu*(t: Tab, info: JsonNode, x, y: float) =
  ## The menu for what `info` reports was clicked (nil when the page didn't report it): link, image and text rows
  ## first, then navigation.
  let link = webUrl(info{"link"}.getStr)
  let linkText = info{"linkText"}.getStr
  let image = webUrl(info{"image"}.getStr)
  let selection = info{"selection"}.getStr
  let editable = info{"editable"}.getBool
  let password = info{"password"}.getBool
  var items: seq[kit.MenuItem]
  var groups = 0
  proc group() =
    if groups > 0: items.add kit.menuSeparator()
    inc groups
  proc item(label: string, action: proc (), enabled = true) =
    items.add kit.menuItem(label, proc () =
      action()
      focusPage(), enabled)
  let newTabs = appUrl.len == 0
  if link.len > 0:
    group()
    if newTabs: item("Open link in new tab", proc () = openInBackgroundTab(link))
    if newTabs and not incognito: item("Open link in incognito window", proc () = openIncognitoWindow(link))
    item("Open link", proc () = t.loadUrl(link))
    item("Copy link address", proc () = copyText(link))
    if linkText.len > 0: item("Copy link text", proc () = copyText(linkText))
  if image.len > 0:
    group()
    if newTabs: item("Open image in new tab", proc () = openInBackgroundTab(image))
    else: item("Open image", proc () = t.loadUrl(image))
    item("Save image to Downloads", proc () = saveImage(image))
    item("Copy image address", proc () = copyText(image))
  if editable:
    group()
    let has = selection.len > 0 and not password
    item("Cut", proc () = (copyText(selection); t.runJs(actionScript("cut"))), has)
    item("Copy", proc () = copyText(selection), has)
    item("Paste", proc () =
      pasteText(proc (text: string) =
        if text.len > 0 and not t.closed: t.runJs(actionScript("paste", text))))
    item("Select all", proc () = t.runJs(actionScript("selectAll")))
  elif selection.strip.len > 0:
    group()
    item("Copy", proc () = copyText(selection))
    item("Search the web for “" & ellipsize(selection.strip, 30) & "”",
      proc () = openInBackgroundTab(selection.strip))
  if link.len == 0 and image.len == 0 and not editable:
    group()
    item("Back", proc () = (webby_view_go_back(t.view); wake()), t.canBack)
    item("Forward", proc () = (webby_view_go_forward(t.view); wake()), t.canForward)
    item("Reload", proc () = (webby_view_reload(t.view); wake()))
    group()
    item("Select all", proc () = t.runJs(actionScript("selectAll")))
    item("Copy page address", proc () = copyText(t.url))
  group()
  item("Inspect", proc () = t.runJs(inspectScript()))
  kit.popupMenu(items, page, x, y)

proc show(info: JsonNode) =
  let t = menuTab
  clearPending()
  if t == nil or t.closed or t != currentTab(): return
  if pageContextMenuHook != nil: pageContextMenuHook(t, info, menuAt[0], menuAt[1])

proc onFallback() =
  # The page didn't report the click (Shift+right-click, a page the script can't run in): a menu without targets.
  fallback = nil
  show(newJObject())

proc onPagePointer(t: Tab, e: kit.PointerEvent): bool =
  # Watches for right-clicks; the page still gets them (its script reports what was under the pointer).
  if e.kind == kit.pkDown and e.button == 3:
    clearPending()
    menuAt = (e.x, e.y)
    menuTab = t
    fallback = after(400, onFallback)

proc onMessage(t: Tab, msg: string): bool =
  if not msg.startsWith("{\"type\":\"contextmenu\""): return false
  # Only right-clicks the user made here open a menu; a report without one is ignored.
  if menuTab != t: return true
  let info = try: parseJson(msg) except CatchableError: nil
  if info == nil: return true
  if info{"prevented"}.getBool:
    clearPending()        # the page shows a menu of its own
    return true
  show(info)
  true

proc install*() =
  pageScriptHooks.add pageScript
  pageMessageHooks.add onMessage
  if pageContextMenuHook == nil: pageContextMenuHook = showPageMenu
  pagePointerHooks.add onPagePointer
