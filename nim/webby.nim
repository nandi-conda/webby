## webby-nim: the webby browser without Flutter. A Nim program on GTK 3 that drives libwebby.so (Ladybird, see
## native/webby_ffi.h) and paints its frames straight into a GtkDrawingArea with cairo.
##
## Build: nim c -d:release -o:nim/webby nim/webby.nim   Run: WEBBY_LADYBIRD_PREFIX=<runtime> nim/webby [url]
## The core is src/browser.nim; every feature is a module in src/features with an install() that adds hooks.

import src/browser
import src/features/[adblock, bookmarks, downloads, find, history, home, omnibox, passwords, tabs, site, pwa, summarize, sync]

bookmarks.install()
downloads.install()
find.install()
history.install()
home.install()
omnibox.install()
passwords.install()
tabs.install()
site.install()
adblock.install()
pwa.install()
summarize.install()
sync.install()
run()
