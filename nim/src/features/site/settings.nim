## The site settings popover behind the button left of the URL bar: the
## connection, what the page's site may use, and deleting its cookies and data.

import std/strutils
import ../../browser
from nimkit/core as kit import nil
import permissions

var
  popover: kit.Popover
  content: kit.Widget       ## the popover's column, rebuilt by fill
  changedSettings = false   ## something changed since the popover opened: offer a reload

proc label(text: string, dim = false, markup = false): kit.Widget =
  result = if markup: kit.richLabel(text) else: kit.label(text)
  if dim: kit.addClass(result, "dim")

proc row(icon: string, children: varargs[kit.Widget]): kit.Widget =
  result = kit.row(kit.icon(icon, 18))
  result.spacing = 10
  for c in children: kit.add(result, c)

proc fill()

proc later(action: proc ()) =
  ## Runs `action` once the widget whose signal is running has let go.
  discard after(0, action)

proc deleteSiteData() =
  let t = currentTab()
  if t == nil: return
  let url = t.url
  kit.confirm("Delete site data?", "This deletes the cookies and data " & siteName(originOf(url)) &
    " stored in this browser. You'll be signed out of it.", "Delete", destructive = true, onResult = proc (ok: bool) =
      if not ok or t.closed: return
      webby_clear_site_data(url.cstring)
      webby_view_reload(t.view)
      wake())

proc reloadPage() =
  let t = currentTab()
  if t != nil:
    webby_view_reload(t.view)
    wake()

proc settingChanged() =
  changedSettings = true
  later(fill)

proc permissionRow(t: Tab, origin: string, k: Kind): kit.Widget =
  let name = k.name
  let choice = kit.dropdown(@["Ask (default)", "Allow", "Block"], get(origin, name).ord, proc (i: int) =
    let setting = Setting(i)
    set(origin, name, setting)
    if setting != allow: forgetOnce(t, origin)
    settingChanged())
  row(k.icon, kit.expand(label(k.label)), choice)

proc fill() =
  ## (Re)builds the popover for the current tab's page.
  kit.clear(content)
  let t = currentTab()
  let url = if t == nil: "" else: t.url
  let origin = originOf(url)
  let title = if origin.len == 0: "Site settings" else: siteName(origin)
  kit.add(content, kit.addClass(kit.label(title), "bold"))
  if origin.len == 0:
    kit.add(content, label("This page has no site settings.", dim = true))
  else:
    let secure = origin.startsWith("https:")
    kit.add(content, row(if secure: "lock_outline" else: "lock_open",
      kit.expand(label(if secure: "Connection is secure" else: "Connection is not secure"))))
    kit.add(content, kit.separator())
    kit.add(content, label("Permissions", dim = true))
    for k in kinds: kit.add(content, permissionRow(t, origin, k))
    kit.add(content, kit.separator())
    kit.add(content, row("cookie_outlined", kit.expand(label("Cookies and site data")), kit.button("Delete", proc () =
      kit.hidePopover(popover)
      later(deleteSiteData))))
    if not secure: kit.add(content, label("Pages that aren't secure can't use these.", dim = true))
    if changedSettings: kit.add(content, label("Reload the page to apply the new settings.", dim = true))
  let actions = kit.row(kit.spacer())
  actions.spacing = 6
  if origin.len > 0 and hasSettings(origin):
    kit.add(actions, kit.button("Reset permissions", proc () =
      let t = currentTab()
      let origin = originOf(if t == nil: "" else: t.url)
      if origin.len == 0: return
      reset(origin)
      forgetOnce(t, origin)
      settingChanged()))
  if changedSettings:
    kit.add(actions, kit.button("Reload", proc () =
      kit.hidePopover(popover)
      reloadPage()))
  kit.add(actions, kit.addClass(kit.button("Done", proc () = kit.hidePopover(popover)), "suggested"))
  kit.add(content, actions)

proc showSiteSettings*() =
  changedSettings = false
  fill()
  kit.showPopover(popover)

proc install*() =
  windowHooks.add proc () =
    let b = kit.iconButton("tune", "Site settings", showSiteSettings)
    kit.insert(toolbarRow, b, toolbarRow.children.find(urlSlotRow))
    content = kit.column()
    discard kit.sized(content, 360)
    popover = kit.popover(b, content, modal = true)
