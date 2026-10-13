## What pages may do and how they look: file inputs, site permissions and the site settings popover, the location
## (GeoClue), web notifications, clearing a site's data, the desktop's light or dark scheme, and site icons.

import site/[colorscheme, filepicker, fontsettings, geolocation, http, icons, notifications, permissions, settings]

proc install*() =
  http.install()
  permissions.install()
  settings.install()
  filepicker.install()
  geolocation.install()
  notifications.install()
  colorscheme.install()
  fontsettings.install()
  icons.install()
