## Address bar suggestions on Android (src/features/omnibox.nim on the desktop): while the URL field is edited, Java
## asks "suggest" for the text and lists what `suggestionProviders` offer (open tabs here; history and bookmarks add
## theirs) under it.

import std/strutils
import ../core

type Suggestion* = object
  title*, url*, kind*: string    ## kind: "history", "bookmark", "tab"

var suggestionProviders*: seq[proc (text: string): seq[Suggestion]]

const maxSuggestions = 8

proc tabSuggestions(text: string): seq[Suggestion] =
  ## Open tabs (other than this one) whose title or address contain every typed word.
  let words = text.toLowerAscii.splitWhitespace
  if words.len == 0: return
  for t in tabs:
    if t == current() or t.url.len == 0 or t.url == homePage: continue
    let hay = t.url.toLowerAscii & " " & t.title.toLowerAscii
    var all = true
    for w in words:
      if w notin hay: all = false
    if all:
      result.add Suggestion(title: t.title, url: t.url, kind: "tab")
      if result.len >= 2: return

proc suggestionsFor*(text: string): seq[Suggestion] =
  if text.strip.len == 0: return
  var seen: seq[string]
  for p in suggestionProviders:
    for s in p(text):
      let key = if s.kind == "tab": "tab " & s.url else: s.url
      if key in seen: continue
      seen.add key
      result.add s
      if result.len >= maxSuggestions: return

proc suggest(args: JsonNode): JsonNode =
  result = newJArray()
  for s in suggestionsFor(args{"text"}.getStr):
    result.add %*{"title": s.title, "url": s.url, "kind": s.kind}

proc switchToTab(args: JsonNode): JsonNode =
  ## A "tab" suggestion: switches to the tab showing that address (or loads it here when it's gone).
  let url = args{"url"}.getStr
  for i, t in tabs:
    if t.url == url and t != current():
      activate(i)
      return %true
  %false

proc install*() =
  suggestionProviders.add tabSuggestions
  commands["suggest"] = suggest
  commands["switchToTab"] = switchToTab
