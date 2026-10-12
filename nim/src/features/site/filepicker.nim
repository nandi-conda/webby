## Pages' <input type=file> pickers (app/lib/src/file_picker.dart), answered with the system file chooser (the
## desktop portal's when there is one).

import std/strutils
import ../../browser

{.push cdecl, importc.}
proc gtk_file_chooser_native_new(title: cstring, parent: Widget, action: cint, accept, cancel: cstring): pointer
proc gtk_native_dialog_run(d: pointer): cint
proc gtk_native_dialog_destroy(d: pointer)
proc gtk_file_chooser_set_filter(c: pointer, f: pointer)
{.pop.}

proc addFilters(chooser: pointer, accept: seq[string]) =
  ## The page's accept list as the chooser's default filter, with "All files" as the other choice.
  if accept.len == 0: return
  let f = gtk_file_filter_new()
  var names: seq[string]
  for a in accept:
    if a.startsWith("."):
      # GTK 3 patterns are case-sensitive: take .pdf and .PDF.
      gtk_file_filter_add_pattern(f, cstring("*" & a))
      gtk_file_filter_add_pattern(f, cstring("*" & a.toUpperAscii))
      names.add a
    elif '/' in a:
      gtk_file_filter_add_mime_type(f, a.cstring)
      names.add a
  if names.len == 0: return
  gtk_file_filter_set_name(f, cstring(names.join(", ")))
  gtk_file_chooser_add_filter(chooser, f)
  let all = gtk_file_filter_new()
  gtk_file_filter_set_name(all, "All files")
  gtk_file_filter_add_pattern(all, "*")
  gtk_file_chooser_add_filter(chooser, all)
  gtk_file_chooser_set_filter(chooser, f)

type Pick = ref object
  tab: Tab
  json: string
  request: JsonNode

proc runPicker(data: pointer): gboolean {.cdecl.} =
  let p = cast[Pick](data)
  GC_unref(p)
  if p.tab.closed: return 0
  var accept: seq[string]
  for a in p.request{"accept"}.getElems: accept.add a.getStr.toLowerAscii
  let multiple = p.request{"multiple"}.getBool
  let chooser = gtk_file_chooser_native_new(cstring(if multiple: "Open files" else: "Open file"), window,
    GTK_FILE_CHOOSER_ACTION_OPEN, "_Open", "_Cancel")
  gtk_file_chooser_set_select_multiple(chooser, multiple.gboolean)
  addFilters(chooser, accept)
  var paths: seq[string]
  if gtk_native_dialog_run(chooser) == GTK_RESPONSE_ACCEPT: paths = fileChooserFilenames(chooser)
  gtk_native_dialog_destroy(chooser)
  # Answer only the request the chooser was for: the page may have navigated or asked again meanwhile.
  if not p.tab.closed and str(webby_view_file_picker_request(p.tab.view)) == p.json:
    webby_view_file_picker_respond(p.tab.view, cstring($(%paths)))
    wake()
  0

proc onRequest(t: Tab, request: JsonNode) =
  let p = Pick(tab: t, json: str(webby_view_file_picker_request(t.view)), request: request)
  GC_ref(p)
  # Run outside the pump: the chooser runs its own main loop.
  discard g_idle_add(runPicker, cast[pointer](p))

proc install*() =
  filePickerHandler = onRequest
