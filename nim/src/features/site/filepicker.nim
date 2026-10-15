## Pages' <input type=file> pickers (app/lib/src/file_picker.dart), answered with the system file chooser (the
## desktop portal's when there is one).

import std/strutils
import ../../browser
from nimkit/core as kit import nil

type Pick = ref object
  tab: Tab
  json: string
  request: JsonNode

proc runPicker(data: pointer): gboolean {.cdecl.} =
  let p = cast[Pick](data)
  GC_unref(p)
  if p.tab.closed: return 0
  # The page's accept list: extensions as patterns (GTK 3's are case-sensitive: take .pdf and .PDF), MIME types.
  var patterns, mimeTypes, names: seq[string]
  for a in p.request{"accept"}.getElems:
    let a = a.getStr.toLowerAscii
    if a.startsWith("."):
      patterns.add "*" & a
      patterns.add "*" & a.toUpperAscii
      names.add a
    elif '/' in a:
      mimeTypes.add a
      names.add a
  let multiple = p.request{"multiple"}.getBool
  kit.chooseFiles(if multiple: "Open files" else: "Open file", multiple = multiple, patterns = patterns,
    mimeTypes = mimeTypes, filterName = names.join(", "), onDone = proc (paths: seq[string]) =
      # Answer only the request the chooser was for: the page may have navigated or asked again meanwhile.
      if not p.tab.closed and str(webby_view_file_picker_request(p.tab.view)) == p.json:
        webby_view_file_picker_respond(p.tab.view, cstring($(%paths)))
        wake())
  0

proc onRequest(t: Tab, request: JsonNode) =
  let p = Pick(tab: t, json: str(webby_view_file_picker_request(t.view)), request: request)
  GC_ref(p)
  # Run outside the pump: the chooser runs its own main loop.
  discard g_idle_add(runPicker, cast[pointer](p))

proc install*() =
  filePickerHandler = onRequest
