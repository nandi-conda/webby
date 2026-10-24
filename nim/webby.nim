## webby: the browser. A Nim program on GTK 3 that drives libwebby.so (Ladybird, see
## native/webby_ffi.h) and paints its frames straight into a GtkDrawingArea with cairo.
##
## Build: nim c -d:release -o:nim/webby nim/webby.nim   Run: WEBBY_LADYBIRD_PREFIX=<runtime> nim/webby [url]
## The core is src/browser.nim; every feature is a module in src/features with an install() that adds hooks.

import src/browser
import src/features/[about, adblock, atpassport, bookmarks, downloads, find, history, home, omnibox, pagefit, passwords, tabs, site, pwa, summarize, sync]
when defined(android): import src/features/android
else: import src/features/[bugreport, pdf, plasma]

bookmarks.install()
downloads.install()
find.install()
history.install()
home.install()
omnibox.install()
passwords.install()
atpassport.install()
tabs.install()
site.install()
adblock.install()
pwa.install()
summarize.install()
pagefit.install()
sync.install()
when defined(android): android.install()
else:
  bugreport.install()
  pdf.install()
  plasma.install()
about.install()   # last: the ⋮ menu's bottom item
run()
