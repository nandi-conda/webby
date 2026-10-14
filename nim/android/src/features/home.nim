## The start page in about:blank tabs (src/features/home.nim on the desktop), with the first bookmarks.

import ../core
import ../../../src/features/home/page

proc install*() =
  pageScriptHooks.add proc (t: Tab): string =
    if incognito or t.url != homePage: "" else: homePageScript()
