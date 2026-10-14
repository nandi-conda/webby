## Tabs for webby-nim: saved sessions, pinned and vertical tabs, the tab and page right-click menus, reopening closed
## tabs, incognito windows and discarding long-hidden tabs. The pieces are in src/features/tabs/.

import tabs/[strip, sessions, contextmenu, newtabs]

proc install*() =
  strip.install()
  sessions.install()
  contextmenu.install()
  newtabs.install()
