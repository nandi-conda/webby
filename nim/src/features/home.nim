## The start page (app/lib/src/home_page.dart): blank tabs and startup show a search/address box and the first
## bookmarks instead of a website. The tab stays on about:blank and the Dart file's page script
## draws the page into that document, so blank-tab handling everywhere else is unchanged.

import std/[json, strutils]
import ../browser
import bookmarks/store as bookmarkStore

const homePageSource = block:
  let dart = staticRead("../../../app/lib/src/home_page.dart")
  let head = "const homePageSource = r'''"
  let start = dart.find(head) + head.len
  dart[start ..< dart.find("''';", start)]

proc homePageData(limit = 8): JsonNode =
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

proc pageScript(t: Tab): string =
  if incognito or appUrl.len > 0 or t.url != "about:blank": return ""
  homePageSource.replace("__WEBBY_HOME_DATA__", $homePageData())

proc install*() =
  pageScriptHooks.add pageScript
