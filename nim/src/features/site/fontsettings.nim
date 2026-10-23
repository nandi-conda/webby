## The desktop's UI font and text size, read through the settings portal (org.gnome.desktop.interface font-name and
## text-scaling-factor). GTK reads them itself only where it can see the
## desktop's settings (XSETTINGS on X11, gsettings schemas on Wayland); a pixi or conda env usually has neither, so
## GTK falls back to "Sans 10" at 96 dpi and everything comes out small. Real GTK settings are left alone.

import std/math
import ../../browser
import gio

const
  portal = "org.freedesktop.portal.Desktop"
  portalPath = "/org/freedesktop/portal/desktop"
  portalSettings = "org.freedesktop.portal.Settings"
  iface = "org.gnome.desktop.interface"
  defaultFont = "Sans 10"

var
  setDpi = false   ## whether gtk-xft-dpi is ours (GTK had no DPI of its own)
  setFont = false  ## whether gtk-font-name is ours

proc applyScale(v: GVariant) =
  if $g_variant_get_type_string(v) != "d": return
  let factor = g_variant_get_double(v)
  if factor < 0.5 or factor > 4: return
  var dpi: cint
  g_object_get(gtk_settings_get_default(), "gtk-xft-dpi", addr dpi, nil)
  if dpi > 0 and not setDpi: return   # GTK has the desktop's DPI already (which includes the text scale)
  setDpi = true
  g_object_set(gtk_settings_get_default(), "gtk-xft-dpi", cint(round(96.0 * 1024 * factor)), nil)

proc applyFont(v: GVariant) =
  if $g_variant_get_type_string(v) != "s": return
  let name = $g_variant_get_string(v, nil)
  if name.len == 0: return
  var current: cstring
  g_object_get(gtk_settings_get_default(), "gtk-font-name", addr current, nil)
  let isDefault = $current == defaultFont
  g_free(current)
  if not isDefault and not setFont: return
  setFont = true
  g_object_set(gtk_settings_get_default(), "gtk-font-name", name.cstring, nil)

proc apply(key: string, v: GVariant) =
  case key
  of "text-scaling-factor": applyScale(v)
  of "font-name": applyFont(v)
  else: discard

proc read(key: string) =
  call(busSession, portal, portalPath, portalSettings, "Read", g_variant_new("(ss)", iface, key.cstring),
    proc (r: GVariant, e: string) =
      if r == nil: return
      let v = child(r, 0)
      apply(key, v)
      g_variant_unref(v))

proc install*() =
  windowHooks.add proc () =
    read("font-name")
    read("text-scaling-factor")
    discard subscribe(busSession, portal, portalSettings, "SettingChanged", portalPath,
      proc (p: string, params: GVariant) =
        if stringAt(params, 0) == iface:
          let v = child(params, 2)
          apply(stringAt(params, 1), v)
          g_variant_unref(v))
