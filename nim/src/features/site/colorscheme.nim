## Pages follow the desktop's light or dark setting: prefers-color-scheme and the
## blank canvas match it, live. The desktop portal's org.freedesktop.appearance color-scheme decides, else the GTK
## theme; incognito windows are always dark, like their UI.

import std/strutils
import ../../browser
import gio, permissions

const
  portal = "org.freedesktop.portal.Desktop"
  portalPath = "/org/freedesktop/portal/desktop"
  portalSettings = "org.freedesktop.portal.Settings"

var
  portalScheme = -1   ## the portal's color-scheme: 0 no preference, 1 dark, 2 light; -1 unknown
  current = colorSchemeLight
  forcedDark = false  ## whether this module set gtk-application-prefer-dark-theme

proc gtkPrefersDark(): bool =
  var dark: gboolean
  var theme: cstring
  g_object_get(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", addr dark,
    "gtk-theme-name", addr theme, nil)
  result = dark != 0 or ($theme).toLowerAscii.endsWith("dark")
  g_free(theme)

proc wanted(): int =
  if incognito or portalScheme == 1: colorSchemeDark
  elif portalScheme == 2: colorSchemeLight
  elif gtkPrefersDark(): colorSchemeDark
  else: colorSchemeLight

proc apply(t: Tab) =
  if not t.closed and t.view != nil: webby_view_set_color_scheme(t.view, current.cint)

proc update() =
  # The browser's UI follows the portal too, so pages and chrome agree.
  if not incognito and (portalScheme == 1) != forcedDark:
    forcedDark = portalScheme == 1
    g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", forcedDark.cint, nil)
  let w = wanted()
  if w == current: return
  current = w
  for t in tabs: apply(t)
  wake()

proc onSchemeVariant(v: GVariant) =
  portalScheme = int(g_variant_get_uint32(v))
  update()

proc readPortal() =
  call(busSession, portal, portalPath, portalSettings, "Read",
    g_variant_new("(ss)", "org.freedesktop.appearance", "color-scheme"), proc (r: GVariant, e: string) =
      if r == nil: return
      let v = child(r, 0)
      if $g_variant_get_type_string(v) == "u": onSchemeVariant(v)
      g_variant_unref(v))
  discard subscribe(busSession, portal, portalSettings, "SettingChanged", portalPath,
    proc (p: string, params: GVariant) =
      if stringAt(params, 0) == "org.freedesktop.appearance" and stringAt(params, 1) == "color-scheme":
        let v = child(params, 2)
        if $g_variant_get_type_string(v) == "u": onSchemeVariant(v)
        g_variant_unref(v))

proc onGtkSetting(o, spec, data: pointer) {.cdecl.} = update()

proc onTabState(t: Tab) =
  # A cross-site navigation can swap the page's WebContent process, which starts from Ladybird's default.
  let origin = originOf(t.url)
  if t.props.getOrDefault("site.schemeOrigin") != origin:
    t.props["site.schemeOrigin"] = origin
    apply(t)

proc install*() =
  windowHooks.add proc () =
    current = wanted()
    let s = gtk_settings_get_default()
    connect(s, "notify::gtk-theme-name", onGtkSetting)
    connect(s, "notify::gtk-application-prefer-dark-theme", onGtkSetting)
    if not incognito: readPortal()
  tabCreatedHooks.add apply
  viewCreatedHooks.add apply
  tabStateHooks.add onTabState
