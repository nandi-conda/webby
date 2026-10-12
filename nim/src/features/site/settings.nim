## The site settings popover behind the button left of the URL bar (app/lib/src/site_settings.dart): the
## connection, what the page's site may use, and deleting its cookies and data (app/lib/src/site_data.dart).

import std/strutils
import ../../browser
import permissions

{.push cdecl, importc.}
proc gtk_combo_box_text_new(): Widget
proc gtk_combo_box_text_append(c: Widget, id, text: cstring)
proc gtk_combo_box_set_active(c: Widget, i: cint)
proc gtk_combo_box_get_active(c: Widget): cint
{.pop.}

var
  button, popover: Widget
  changedSettings = false   ## something changed since the popover opened: offer a reload

proc label(text: string, dim = false, markup = false): Widget =
  result = gtk_label_new("")
  if markup: gtk_label_set_markup(result, text.cstring) else: gtk_label_set_text(result, text.cstring)
  gtk_label_set_xalign(result, 0)
  gtk_label_set_line_wrap(result, 1)
  gtk_label_set_max_width_chars(result, 40)
  if dim: addClass(result, "dim-label")

proc row(icon: string, text: Widget): Widget =
  result = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)
  gtk_box_pack_start(result, gtk_image_new_from_icon_name(icon.cstring, GTK_ICON_SIZE_BUTTON), 0, 0, 0)
  gtk_box_pack_start(result, text, 1, 1, 0)

proc fill()

proc confirmDelete(site: string): bool =
  let d = gtk_message_dialog_new(window, GTK_DIALOG_MODAL, GTK_MESSAGE_WARNING, GTK_BUTTONS_NONE, "%s",
    "Delete site data?")
  gtk_message_dialog_format_secondary_text(d, "%s", cstring("This deletes the cookies and data " & site &
    " stored in this browser. You'll be signed out of it."))
  discard gtk_dialog_add_button(d, "_Cancel", GTK_RESPONSE_CANCEL)
  addClass(gtk_dialog_add_button(d, "_Delete", GTK_RESPONSE_OK), "destructive-action")
  gtk_dialog_set_default_response(d, GTK_RESPONSE_OK)
  result = gtk_dialog_run(d) == GTK_RESPONSE_OK
  gtk_widget_destroy(d)

proc deleteSiteData() =
  let t = currentTab()
  if t == nil: return
  let url = t.url
  if not confirmDelete(siteName(originOf(url))) or t.closed: return
  webby_clear_site_data(url.cstring)
  webby_view_reload(t.view)
  wake()

proc reloadPage() =
  let t = currentTab()
  if t != nil:
    webby_view_reload(t.view)
    wake()

proc fill() =
  ## (Re)builds the popover for the current tab's page.
  clearChildren(popover)
  let t = currentTab()
  let url = if t == nil: "" else: t.url
  let origin = originOf(url)
  let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)
  gtk_container_set_border_width(box, 14)
  gtk_widget_set_size_request(box, 360, -1)
  gtk_container_add(popover, box)
  let title = if origin.len == 0: "Site settings" else: siteName(origin)
  gtk_box_pack_start(box, label("<b>" & escapeMarkup(title) & "</b>", markup = true), 0, 0, 0)
  if origin.len == 0:
    gtk_box_pack_start(box, label("This page has no site settings.", dim = true), 0, 0, 0)
  else:
    let secure = origin.startsWith("https:")
    gtk_box_pack_start(box, row(if secure: "channel-secure-symbolic" else: "channel-insecure-symbolic",
      label(if secure: "Connection is secure" else: "Connection is not secure")), 0, 0, 0)
    gtk_box_pack_start(box, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, 0, 4)
    gtk_box_pack_start(box, label("Permissions", dim = true), 0, 0, 0)
    for k in kinds:
      let combo = gtk_combo_box_text_new()
      for (id, text) in [("ask", "Ask (default)"), ("allow", "Allow"), ("block", "Block")]:
        gtk_combo_box_text_append(combo, id.cstring, text.cstring)
      gtk_combo_box_set_active(combo, get(origin, k.name).ord.cint)
      g_object_set_data(combo, "webby-permission", cast[pointer](kindNamed(k.name)))
      connect(combo, "changed", proc (c: Widget, d: pointer) {.cdecl.} =
        let t = currentTab()
        let origin = originOf(if t == nil: "" else: t.url)
        if origin.len == 0: return
        let setting = Setting(gtk_combo_box_get_active(c))
        set(origin, kinds[cast[int](g_object_get_data(c, "webby-permission"))].name, setting)
        if setting != allow: forgetOnce(t, origin)
        changedSettings = true
        discard g_idle_add(proc (d: pointer): gboolean {.cdecl.} = (fill(); 0), nil))
      let r = row(k.icon, label(k.label))
      gtk_box_pack_end(r, combo, 0, 0, 0)
      gtk_box_pack_start(box, r, 0, 0, 0)
    gtk_box_pack_start(box, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, 0, 4)
    let data = row("user-trash-symbolic", label("Cookies and site data"))
    let del = gtk_button_new_with_label("Delete")
    connect(del, "clicked", proc (b: Widget, d: pointer) {.cdecl.} =
      gtk_popover_popdown(popover)
      # Ask once the popover has let go of the pointer.
      discard g_idle_add(proc (d: pointer): gboolean {.cdecl.} = (deleteSiteData(); 0), nil))
    gtk_box_pack_end(data, del, 0, 0, 0)
    gtk_box_pack_start(box, data, 0, 0, 0)
    if not secure:
      gtk_box_pack_start(box, label("Pages that aren't secure can't use these.", dim = true), 0, 0, 0)
    if changedSettings:
      gtk_box_pack_start(box, label("Reload the page to apply the new settings.", dim = true), 0, 0, 0)
  let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
  gtk_widget_set_halign(actions, GTK_ALIGN_END)
  if origin.len > 0 and hasSettings(origin):
    let r = gtk_button_new_with_label("Reset permissions")
    connect(r, "clicked", proc (b: Widget, d: pointer) {.cdecl.} =
      let t = currentTab()
      let origin = originOf(if t == nil: "" else: t.url)
      if origin.len == 0: return
      reset(origin)
      forgetOnce(t, origin)
      changedSettings = true
      discard g_idle_add(proc (d: pointer): gboolean {.cdecl.} = (fill(); 0), nil))
    gtk_box_pack_start(actions, r, 0, 0, 0)
  if changedSettings:
    let r = gtk_button_new_with_label("Reload")
    connect(r, "clicked", proc (b: Widget, d: pointer) {.cdecl.} =
      gtk_popover_popdown(popover)
      reloadPage())
    gtk_box_pack_start(actions, r, 0, 0, 0)
  let done = gtk_button_new_with_label("Done")
  addClass(done, "suggested-action")
  connect(done, "clicked", proc (b: Widget, d: pointer) {.cdecl.} = gtk_popover_popdown(popover))
  gtk_box_pack_start(actions, done, 0, 0, 0)
  gtk_box_pack_start(box, actions, 0, 0, 4)
  gtk_widget_show_all(box)

proc showSiteSettings*() =
  changedSettings = false
  fill()
  gtk_popover_popup(popover)

proc refreshButton() =
  let t = currentTab()
  let url = if t == nil: "" else: t.url
  let origin = originOf(url)
  let icon = if origin.startsWith("https:"): "channel-secure-symbolic"
             elif origin.len > 0: "channel-insecure-symbolic"
             else: "dialog-information-symbolic"
  gtk_image_set_from_icon_name(gtk_button_get_image(button), icon.cstring, GTK_ICON_SIZE_SMALL_TOOLBAR)

proc install*() =
  windowHooks.add proc () =
    button = iconButton("dialog-information-symbolic", "Site settings", showSiteSettings)
    gtk_box_pack_start(toolbar, button, 0, 0, 0)
    gtk_box_reorder_child(toolbar, button, children(toolbar).find(urlEntry).cint)
    popover = gtk_popover_new(button)
    gtk_popover_set_position(popover, GTK_POS_BOTTOM)
  activeTabHooks.add proc (t: Tab) = refreshButton()
  tabStateHooks.add proc (t: Tab) = (if t == currentTab(): refreshButton())
