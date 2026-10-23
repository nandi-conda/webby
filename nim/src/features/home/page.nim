## The start page's script and data, used by the Nim front end (features/home.nim) on
## the desktop and Android.

import std/[json, strutils]
import ../../base
import ../bookmarks/store as bookmarkStore

const homePageSource* = staticRead("../../scripts/home_page.js")

proc homePageData*(limit = 8): JsonNode =
  var marks = newJArray()
  proc walk(node: Bookmark) =
    for child in node.children:
      if marks.len >= limit: return
      if child.isFolder: walk(child)
      elif child.url.startsWith("http"): marks.add %*{"title": child.title, "url": child.url}
  bookmarkStore.ensureLoaded()
  walk(bookmarkStore.bar)
  walk(bookmarkStore.other)
  %*{"bookmarks": marks}

proc homePageScript*(): string =
  ## The script that draws the start page into an about:blank document.
  homePageSource.replace("__WEBBY_HOME_DATA__", $homePageData())
