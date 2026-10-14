## webby-nim for Android: the browser core as a shared library (libwebbynim.so) under a thin Java shell
## (nim/android/java). Java owns the Android widgets (toolbar, URL field, tab list, dialogs, screens) and forwards
## input; Nim owns everything else: Ladybird (libwebby.so, the same native runtime as the Flutter APK), tabs, the
## pump, frames, touch gestures, the on-screen keyboard (core.nim) and the features (features/*.nim), which keep
## their data in the same stores and files as the desktop front end (src/features/*/).
##
## Everything runs on Android's main thread: Java calls in through glue.c's native methods (Native.command runs a
## feature's command with JSON), and the pump is a timerfd on the main looper. Nim tells Java about changes with
## MainActivity's static on* methods (glue_call), passing JSON.

{.compile: "glue.c".}
{.passL: "-landroid -llog".}

import core
import features/[net, omnibox, history, bookmarks, home, files, passwords, sync, tabextras, site, summarize, pwa]

# Suggestions list open tabs first, then history, then bookmarks, as on the desktop.
net.install()
omnibox.install()
history.install()
bookmarks.install()
home.install()
files.install()
passwords.install()
sync.install()
tabextras.install()
site.install()
summarize.install()
pwa.install()
