## The start page's script and data (app/lib/src/home_page.dart), shared by the desktop (features/home.nim) and
## Android (nim/android/src/features/home.nim) front ends.

import std/[json, strutils]
import ../../base
import ../bookmarks/store as bookmarkStore

const homePageSource* = block:
  let dart = staticRead("../../../../app/lib/src/home_page.dart")
  let head = "const homePageSource = r'''"
  let start = dart.find(head) + head.len
  dart[start ..< dart.find("''';", start)]

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
