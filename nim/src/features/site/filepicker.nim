## Pages' <input type=file> pickers (app/lib/src/file_picker.dart), answered with the system file chooser (the
## desktop portal's when there is one).

import std/strutils
import ../../browser
from nimkit/core as kit import nil

proc runPicker(t: Tab, json: string, request: JsonNode) =
  if t.closed: return
  # The page's accept list: extensions as patterns (GTK 3's are case-sensitive: take .pdf and .PDF), MIME types.
  var patterns, mimeTypes, names: seq[string]
  for a in request{"accept"}.getElems:
    let a = a.getStr.toLowerAscii
    if a.startsWith("."):
      patterns.add "*" & a
      patterns.add "*" & a.toUpperAscii
      names.add a
    elif '/' in a:
      mimeTypes.add a
      names.add a
  let multiple = request{"multiple"}.getBool
  kit.chooseFiles(if multiple: "Open files" else: "Open file", multiple = multiple, patterns = patterns,
    mimeTypes = mimeTypes, filterName = names.join(", "), onDone = proc (paths: seq[string]) =
      # Answer only the request the chooser was for: the page may have navigated or asked again meanwhile.
      if not t.closed and str(webby_view_file_picker_request(t.view)) == json:
        webby_view_file_picker_respond(t.view, cstring($(%paths)))
        wake())

proc onRequest(t: Tab, request: JsonNode) =
  let json = str(webby_view_file_picker_request(t.view))
  # Run outside the pump: the chooser may run its own main loop.
  discard after(0, proc () = runPicker(t, json, request))

proc install*() =
  filePickerHandler = onRequest
