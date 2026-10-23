## The address bar's suggestions: while the URL bar is edited, a popup under it lists
## what `suggestionProviders` offer for the text (history and bookmarks add theirs; open tabs come from here).
## Up/Down pick one, Enter opens it (or the typed text, made an address or a search by `addressToUrl`), Esc closes.
## Typed text that isn't an address also asks the search engine (omnibox/search.nim) for its suggestions, which
## join the list when they come.

import std/strutils
import ../browser
from nimkit/core as kit import nil
from nimkit/services import after, cancel, request, Response, Timer
import omnibox/[address, search]
export address

const
  maxSuggestions = 8
  maxSearchSuggestions = 4
  suggestDelay = 120          ## ms of no typing before asking the engine

var
  popover: kit.Popover
  list: kit.Widget            ## the popover's rows
  shown: seq[Suggestion]
  selected = -1               ## -1 is the typed text itself
  searchFor: string           ## the text `searchSuggestions` are for
  searchSuggestions: seq[string]
  suggestTimer: Timer
  suggestSerial = 0           ## the newest request; older replies are dropped

proc go*(input: string) =
  ## Loads what was typed (or picked) in the current tab.
  let text = input.strip
  if text.len == 0: return
  let url = addressToUrl(text, currentEngine().engine.queryUrl)
  let t = currentTab()
  if t == nil: discard openTab(url)
  else:
    t.loadUrl(url)
    focusPage()

# ---------------------------------------------------------------------------------------------------------------
# The popover

proc hidePopup() =
  if popover != nil: kit.hidePopover(popover)
  shown.setLen 0
  selected = -1

proc popupShowing(): bool = popover != nil and popover.shown

proc open(s: Suggestion) =
  hidePopup()
  if s.kind == "tab":
    for t in tabs:
      if t.url == s.url and t != currentTab():
        activateTab(t)
        focusPage()
        return
  go(s.url)

proc kindIcon(kind: string): string =
  case kind
  of "bookmark": "star_border"
  of "tab": "tab"
  of "search": "search"
  else: "history"

proc row(s: Suggestion): kit.Widget =
  result = kit.item(kit.icon(kindIcon(s.kind)), onClick = proc () = open(s))
  if s.kind == "search":
    let query = kit.label(s.title)
    kit.`maxChars=`(query, 200)
    kit.add(result, kit.expand(query))
    result.spacing = 10
    discard kit.sized(result, 0, 30)
    return
  if s.title.len > 0:
    let title = kit.label(s.title)
    kit.`maxChars=`(title, 60)
    kit.add(result, title)
    kit.add(result, kit.addClass(kit.label("-"), "dim"))
  let url = kit.label(if s.kind == "tab": s.url & "  (switch to tab)" else: s.url)
  kit.`maxChars=`(url, 200)
  kit.addClass(url, "webby-omnibox-url")
  kit.add(result, kit.expand(url))
  result.spacing = 10
  discard kit.sized(result, 0, 30)

proc suggestionsFor(text: string): seq[Suggestion] =
  var seen: seq[string]
  for p in suggestionProviders:
    for s in p(text):
      # An open tab doesn't hide the page in history: one switches to the tab, the other loads it here.
      let key = if s.kind == "tab": "tab " & s.url else: s.url
      if key in seen: continue
      seen.add key
      result.add s
      if result.len >= maxSuggestions: return

proc withSearches(text: string, found: seq[Suggestion]): seq[Suggestion] =
  ## `found`, then the engine's suggestions for `text` (if they came), keeping room for a few of them.
  var searches: seq[Suggestion]
  if text.strip == searchFor:
    let engine = currentEngine().engine
    for q in searchSuggestions:
      if searches.len >= maxSearchSuggestions: break
      if q.strip.len == 0 or q.strip == text.strip: continue
      searches.add Suggestion(title: q, url: engine.searchUrl(q), kind: "search")
  result = found
  if result.len > maxSuggestions - searches.len: result.setLen maxSuggestions - searches.len
  result.add searches

proc show(found: seq[Suggestion]) =
  if found.len == 0:
    hidePopup()
    return
  shown = found
  selected = -1
  kit.clear(list)
  for s in found: kit.add(list, row(s))
  kit.showPopover(popover)

proc askEngine(text: string) =
  ## Asks the search engine for suggestions for `text` (once typing pauses); they show when they come.
  cancel(suggestTimer)
  let query = text.strip
  let (engine, on) = currentEngine()
  if not on or query.len == 0 or query.len > 200 or isAddress(query) or query == searchFor: return
  inc suggestSerial
  let serial = suggestSerial
  suggestTimer = after(suggestDelay, proc () =
    request("GET", engine.suggestionsUrl(query), proc (r: Response) =
      if serial != suggestSerial or r.status != 200: return
      searchFor = query
      searchSuggestions = engine.parseSuggestions(r.body)
      # Not while a row is picked with the arrows: the list would move under it.
      if urlFocused and selected < 0 and kit.text(urlField).strip == query:
        show(withSearches(query, suggestionsFor(query)))))

proc update(text: string) =
  let typed = urlFocused and text.strip.len > 0
  show(withSearches(text, if typed: suggestionsFor(text) else: @[]))
  if typed: askEngine(text)

proc select(i: int) =
  selected = i
  for j, r in list.children: kit.setClass(r, "selected", j == i)

proc onKey(e: kit.KeyEvent): bool =
  case e.code
  of 0x28, 0x26:                              # Down, Up
    if not popupShowing(): return false
    let step = if e.code == 0x28: 1 else: -1
    select((selected + 1 + step + shown.len + 1) mod (shown.len + 1) - 1)
    true
  of 0x0D:                                    # Enter
    let picked = if selected in 0 ..< shown.len: shown[selected] else: Suggestion()
    let text = kit.text(urlField)
    hidePopup()
    if picked.url.len > 0: open(picked) else: go(text)
    true
  else: false

proc onFocus(focused: bool) =
  if focused: return
  # A moment later, so a click on the popover still lands.
  discard after(150, proc () =
    if urlFocused: return
    hidePopup()
    let t = currentTab()
    if t != nil and t.url.len > 0: kit.`text=`(urlField, if t.url == "about:blank": "" else: t.url))

proc tabSuggestions(text: string): seq[Suggestion] =
  ## Open tabs (other than this one) whose title or address contain every typed word.
  let words = text.toLowerAscii.splitWhitespace
  for t in tabs:
    if t == currentTab() or t.url.len == 0: continue
    let hay = t.url.toLowerAscii & " " & t.title.toLowerAscii
    var all = true
    for w in words:
      if w notin hay: all = false
    if all and words.len > 0:
      result.add Suggestion(title: t.title, url: t.url, kind: "tab")
      if result.len >= 2: return

proc buildPopup() =
  if appUrl.len > 0: return
  loadCss(".webby-omnibox-url { color: @theme_selected_bg_color; }")
  list = kit.column()
  list.spacing = 0
  popover = kit.popover(urlField, list)
  urlField.onChange = update
  urlField.onEntryKey = onKey
  urlFocusHooks.add onFocus

proc install*() =
  # Before the core's Esc (close the sidebar), which it still does when there are no suggestions to close.
  # Esc that closes nothing goes on to the page.
  addKeyHandler(0, 0xff1b, proc (): bool =
    result = true
    if popupShowing(): hidePopup()
    elif sidePanelShowing(): closeSidePanel()
    elif urlFocused:
      let t = currentTab()
      if t != nil: kit.`text=`(urlField, if t.url == "about:blank": "" else: t.url)
      kit.selectAll(urlField)
    else: result = false)
  suggestionProviders.insert(tabSuggestions, 0)
  startupHooks.add prepareSearch
  windowHooks.add buildPopup
