## Plasma browser integration, built in: what KDE's browser extension and its plasma-browser-integration-host
## give other browsers, over D-Bus straight from webby. Media controls (MPRIS, also used by GNOME and the media
## keys), KRunner search of tabs, bookmarks and history, and downloads in Plasma's job tracker. Desktop only.

import std/[os, strutils]
import ../browser
import plasma/[jobs, krunner, mpris]

proc findDesktopEntry(): string =
  ## The launcher webby was installed with (conda's menuinst names it after the menu item), which Plasma shows the
  ## jobs and the media player under: the one with webby's window class, else "webby".
  var dirs = @[getDataDir()]
  for d in getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(':'):
    if d.len > 0: dirs.add d
  for d in dirs:
    try:
      for f in walkFiles(d / "applications" / "*.desktop"):
        let text = readFile(f)
        if "StartupWMClass=dev.webby.webby" in text and "NoDisplay=true" notin text:
          return f.extractFilename.changeFileExt("")
    except CatchableError: discard
  "webby"

proc install*() =
  mpris.install()
  jobs.install()
  krunner.install()
  startupHooks.add proc () =
    if appUrl.len > 0: return
    let entry = findDesktopEntry()
    mpris.desktopEntry = entry
    jobs.desktopEntry = entry
