## What pages may do and how they look: file inputs, site permissions and the site settings popover, the location
## (GeoClue), web notifications, clearing a site's data, the desktop's light or dark scheme, and site icons.

import site/[filepicker, http, icons, permissions, settings]
when not defined(android):
  # Through the desktop's D-Bus services (GeoClue, notifications, the settings portal) and GTK's settings.
  import site/[colorscheme, fontsettings, geolocation, notifications]

proc install*() =
  http.install()
  permissions.install()
  settings.install()
  filepicker.install()
  when not defined(android):
    geolocation.install()
    notifications.install()
    colorscheme.install()
    fontsettings.install()
  icons.install()
