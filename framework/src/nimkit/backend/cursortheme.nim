## The desktop's mouse pointer theme for GTK windows. GTK from a conda env doesn't see the desktop's cursor settings
## (it has no dconf, and on Wayland no XSETTINGS), so on Wayland it fell back to its "default" theme, and its own
## libXcursor / libwayland-cursor look in the env's share/icons (Adwaita 41) ahead of /usr/share/icons. This finds the
## theme and size the desktop uses and hands them to GTK, so pages and chrome show the same pointers as other apps.

import std/[os, strutils]

type GVariant = pointer

{.push importc, cdecl.}
proc g_bus_get_sync(busType: cint, cancellable: pointer, err: pointer): pointer
proc g_dbus_connection_call_sync(conn: pointer, busName, path, iface, meth: cstring, params: GVariant,
                                 replyType: pointer, flags: cint, timeoutMs: cint, cancellable: pointer,
                                 err: pointer): GVariant
proc g_variant_new(format: cstring): GVariant {.varargs.}
proc g_variant_get_child_value(v: GVariant, i: csize_t): GVariant
proc g_variant_get_variant(v: GVariant): GVariant
proc g_variant_get_type_string(v: GVariant): cstring
proc g_variant_get_string(v: GVariant, len: pointer): cstring
proc g_variant_get_int32(v: GVariant): int32
proc g_variant_unref(v: GVariant)
proc g_object_unref(o: pointer)
proc g_object_set(o: pointer, first: cstring) {.varargs.}
proc gtk_settings_get_default(): pointer
{.pop.}

proc portalSetting(key: string): GVariant =
  ## org.gnome.desktop.interface `key` from the desktop's settings portal (GNOME's, and others that mirror it), or nil.
  ## No auto-start and a short timeout: without a running portal this costs nothing at startup.
  let bus = g_bus_get_sync(2, nil, nil)   # G_BUS_TYPE_SESSION
  if bus == nil: return nil
  defer: g_object_unref(bus)
  let reply = g_dbus_connection_call_sync(bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
    "org.freedesktop.portal.Settings", "Read", g_variant_new("(ss)", "org.gnome.desktop.interface", key.cstring),
    nil, 1, 300, nil, nil)                 # G_DBUS_CALL_FLAGS_NO_AUTO_START
  if reply == nil: return nil
  var v = g_variant_get_child_value(reply, 0)
  g_variant_unref(reply)
  while v != nil and $g_variant_get_type_string(v) == "v":   # Read wraps the value in one or two variants
    let inner = g_variant_get_variant(v)
    g_variant_unref(v)
    v = inner
  v

proc iniValue(path, section, key: string): string =
  var inSection = false
  for raw in (try: readFile(path) except IOError, OSError: "").splitLines:
    let line = raw.strip
    if line.startsWith("["): inSection = line == "[" & section & "]"
    elif inSection and line.startsWith(key & "="): return line[key.len + 1 .. ^1].strip

proc desktopCursor(): tuple[name: string, size: int] =
  ## XCURSOR_THEME / XCURSOR_SIZE (set by Plasma, sway, Hyprland and others), else the settings portal's
  ## org.gnome.desktop.interface (GNOME), else Plasma's kcminputrc.
  result.name = getEnv("XCURSOR_THEME")
  result.size = try: parseInt(getEnv("XCURSOR_SIZE")) except ValueError: 0
  if result.name.len == 0:
    let v = portalSetting("cursor-theme")
    if v != nil:
      if $g_variant_get_type_string(v) == "s": result.name = $g_variant_get_string(v, nil)
      g_variant_unref(v)
  if result.size <= 0:
    let v = portalSetting("cursor-size")
    if v != nil:
      if $g_variant_get_type_string(v) == "i": result.size = g_variant_get_int32(v)
      g_variant_unref(v)
  if "KDE" in getEnv("XDG_CURRENT_DESKTOP").toUpperAscii:
    let rc = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "kcminputrc"
    if result.name.len == 0: result.name = iniValue(rc, "Mouse", "cursorTheme")
    if result.name.len == 0: result.name = "breeze_cursors"
    if result.size <= 0: result.size = try: parseInt(iniValue(rc, "Mouse", "cursorSize")) except ValueError: 0

proc useSystemCursorPath*() =
  ## Before gtk_init: the desktop's cursor directories ahead of the env's own share/icons, so a theme the desktop and
  ## the env both have (Adwaita) comes from the desktop. An XCURSOR_PATH the user set is left alone.
  if existsEnv("XCURSOR_PATH"): return
  let home = getHomeDir()
  let prefix = getEnv("CONDA_PREFIX")
  var dirs = @[getEnv("XDG_DATA_HOME", home / ".local/share") / "icons", home / ".icons"]
  for d in getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(':'):
    # The env's activation can put its own share first in XDG_DATA_DIRS.
    if d.len > 0 and (prefix.len == 0 or not d.startsWith(prefix)): dirs.add d / "icons"
  dirs.add ["/usr/share/icons", "/usr/share/pixmaps"]
  if prefix.len > 0: dirs.add prefix / "share/icons"   # last: themes only the env has
  var seen: seq[string]
  for d in dirs:
    if d notin seen: seen.add d
  putEnv("XCURSOR_PATH", seen.join(":"))

proc useSystemCursorTheme*() =
  ## After gtk_init: the desktop's cursor theme and size for every GTK window.
  let (name, size) = desktopCursor()
  let settings = gtk_settings_get_default()
  if settings == nil: return
  if name.len > 0: g_object_set(settings, "gtk-cursor-theme-name", name.cstring, nil)
  if size > 0: g_object_set(settings, "gtk-cursor-theme-size", size.cint, nil)
