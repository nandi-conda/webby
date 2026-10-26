## What pages may do and how they look: file inputs, site permissions and the site settings popover, the location
## (GeoClue), web notifications, clearing a site's data, the desktop's light or dark scheme, site icons, (on Android)
## workers that share the page's IndexedDB, and (on the desktop) screen recording and web push.

import site/[filepicker, geolocation, http, icons, notifcentre, notifications, notifprefs, permissions, settings]
when defined(android):
  # Android's native part predates patch 0037 (IndexedDB shared by every process); drop this once it has it.
  import site/workers
when not defined(android):
  # Through the desktop's settings portal and GTK's settings (on Android, features/android.nim follows the theme).
  import site/[colorscheme, fontsettings, push, screencapture]

proc install*() =
  http.install()
  permissions.install()
  settings.install()
  filepicker.install()
  geolocation.install()
  notifications.install()
  notifcentre.install()
  notifprefs.install()
  when not defined(android):
    colorscheme.install()
    fontsettings.install()
    screencapture.install()
    push.install()
  icons.install()
  when defined(android): workers.install()
