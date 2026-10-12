## GTK bits the password manager's UI shares: extra declarations and closures on signals that are freed with
## their widget.

import ../../browser

{.push cdecl, importc.}
proc gtk_stack_add_titled*(stack, child: Widget, name, title: cstring)
proc gtk_stack_switcher_new*(): Widget
proc gtk_stack_switcher_set_stack*(switcher, stack: Widget)
proc gtk_dialog_response*(d: Widget, response: cint)
proc gtk_label_set_line_wrap_mode*(l: Widget, mode: cint)
proc gtk_box_set_spacing*(box: Widget, spacing: cint)
{.pop.}

proc callAction(w: Widget, d: pointer) {.cdecl.} = cast[ref proc ()](d)[]()
proc freeAction(d: pointer, closure: pointer) {.cdecl.} = GC_unref(cast[ref proc ()](d))

proc on*(w: Widget, signal: string, action: proc () {.closure.}) =
  ## Runs `action` on a (widget, data) signal such as clicked, activate or search-changed.
  let cb = new(proc ())
  cb[] = action
  GC_ref(cb)
  discard g_signal_connect_data(w, signal.cstring, cast[pointer](callAction), cast[pointer](cb),
    cast[pointer](freeAction), 0)

proc button*(label: string, action: proc () {.closure.}, suggested = false, flat = false): Widget =
  result = gtk_button_new_with_label(label.cstring)
  if suggested: addClass(result, "suggested-action")
  if flat: gtk_button_set_relief(result, GTK_RELIEF_NONE)
  result.on("clicked", action)

proc smallIconButton*(icon, tooltip: string, action: proc () {.closure.}): Widget =
  result = gtk_button_new_from_icon_name(icon.cstring, GTK_ICON_SIZE_MENU)
  gtk_button_set_relief(result, GTK_RELIEF_NONE)
  gtk_widget_set_tooltip_text(result, tooltip.cstring)
  result.on("clicked", action)

proc markupLabel*(markup: string, wrap = false): Widget =
  result = gtk_label_new("")
  gtk_label_set_markup(result, markup.cstring)
  gtk_label_set_xalign(result, 0)
  if wrap:
    gtk_label_set_line_wrap(result, 1)
    gtk_label_set_line_wrap_mode(result, 2)   # PANGO_WRAP_WORD_CHAR
  else:
    gtk_label_set_ellipsize(result, PANGO_ELLIPSIZE_END)

proc copyText*(text: string) = gtk_clipboard_set_text(systemClipboard(), text.cstring, -1)
