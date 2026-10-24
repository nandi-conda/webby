## What pages may do and how they look: file inputs, site permissions and the site settings popover, the location
## (GeoClue), web notifications, clearing a site's data, the desktop's light or dark scheme, site icons, and (on the
## desktop) screen recording and web push.

import site/[filepicker, geolocation, http, icons, notifications, permissions, settings]
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
  when not defined(android):
    colorscheme.install()
    fontsettings.install()
    screencapture.install()
    push.install()
  icons.install()
