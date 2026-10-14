## Pages' <input type=file> pickers on Android (src/features/site/filepicker.nim on the desktop): Java shows the
## system document picker, copies the chosen documents into the app's cache and answers with their paths.

import ../core

proc onRequest(t: Tab, request: JsonNode) =
  let r = request.copy
  r["tab"] = %t.id
  r["request"] = %t.filePickerJson
  event("filePicker", r)

proc respond(args: JsonNode): JsonNode =
  ## {tab, request, paths}: answers the request the picker was for (the page may have asked again meanwhile).
  let i = tabIndex(args{"tab"}.getInt)
  if i < 0: return nil
  let t = tabs[i]
  if str(webby_view_file_picker_request(t.view)) != args{"request"}.getStr: return nil
  var paths = newJArray()
  for p in args{"paths"}.getElems: paths.add p
  webby_view_file_picker_respond(t.view, cstring($paths))
  nil

proc install*() =
  filePickerHandler = onRequest
  commands["filePicker.respond"] = respond
