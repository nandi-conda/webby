## The start page: blank tabs and startup show a search/address box and the first
## bookmarks instead of a website. The tab stays on about:blank and the page script (scripts/home_page.js)
## draws the page into that document, so blank-tab handling everywhere else is unchanged.

import ../browser
import home/page

proc pageScript(t: Tab): string =
  if incognito or appUrl.len > 0 or t.url != "about:blank": return ""
  homePageScript()

proc install*() =
  pageScriptHooks.add pageScript
