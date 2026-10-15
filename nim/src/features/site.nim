## What pages may do and how they look: file inputs, site permissions and the site settings popover, the location
## (GeoClue), web notifications, clearing a site's data, the desktop's light or dark scheme, and site icons.

import site/[filepicker, geolocation, http, icons, notifications, permissions, settings]
when not defined(android):
  # Through the desktop's settings portal and GTK's settings (on Android, features/android.nim follows the theme).
  import site/[colorscheme, fontsettings]

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
  icons.install()
