## The search engine the address bar uses, shared by the desktop and Android front ends.
##
## The choice is Ladybird's own: Settings.json's "searchEngine" ({"engine": name or null, "suggestions": bool,
## "custom": [{"name", "url", "suggestionsUrl"}]}), which about:settings > Search changes. A fresh Ladybird profile
## has none ("Disable search"), so the first start makes Google the engine, with suggestions, unless one was picked;
## <data>/webby/profiles/<profile>/search_engine.json records that this was done, so a later "Disable search" or
## another engine stays. With no engine, typed text still searches Google, without suggestions.

import std/[json, os, strutils, times, uri]
import ../../base
import ../adblock/store

type
  SuggestFormat* = enum opensearch, duckduckgo, yahoo

  SearchEngine* = object
    name*, queryUrl*, suggestUrl*: string   ## the URLs have %s for the query; suggestUrl "" = none
    format*: SuggestFormat

const
  defaultEngine* = "Google"
  # LibWebView/SearchEngine.cpp's built-in engines.
  builtinEngines* = [
    SearchEngine(name: "Bing", queryUrl: "https://www.bing.com/search?q=%s",
      suggestUrl: "https://www.bing.com/osjson.aspx?query=%s"),
    SearchEngine(name: "Brave", queryUrl: "https://search.brave.com/search?q=%s",
      suggestUrl: "https://search.brave.com/api/suggest?q=%s"),
    SearchEngine(name: "DuckDuckGo", queryUrl: "https://duckduckgo.com/?q=%s",
      suggestUrl: "https://duckduckgo.com/ac/?q=%s", format: duckduckgo),
    SearchEngine(name: "Ecosia", queryUrl: "https://ecosia.org/search?q=%s",
      suggestUrl: "https://ac.ecosia.org/autocomplete?q=%s&type=list"),
    SearchEngine(name: "Google", queryUrl: "https://www.google.com/search?q=%s",
      suggestUrl: "https://www.google.com/complete/search?client=chrome&q=%s"),
    SearchEngine(name: "Kagi", queryUrl: "https://kagi.com/search?q=%s",
      suggestUrl: "https://kagisuggest.com/api/autosuggest?q=%s"),
    SearchEngine(name: "Mojeek", queryUrl: "https://www.mojeek.com/search?q=%s"),
    SearchEngine(name: "Startpage", queryUrl: "https://startpage.com/search?q=%s"),
    SearchEngine(name: "Yahoo", queryUrl: "https://search.yahoo.com/search?p=%s",
      suggestUrl: "https://search.yahoo.com/sugg/gossip/gossip-us-ura/?output=sd1&command=%s", format: yahoo),
    SearchEngine(name: "Yandex", queryUrl: "https://yandex.com/search/?text=%s",
      suggestUrl: "https://suggest.yandex.com/suggest-ff.cgi?part=%s&uil=en&v=3"),
  ]

proc findEngine(name: string, settings: JsonNode): (bool, SearchEngine) =
  for e in builtinEngines:
    if e.name == name: return (true, e)
  if settings != nil and settings{"custom"} != nil:
    for c in settings{"custom"}.getElems:
      if c.kind == JObject and c{"name"}.getStr == name and c{"url"}.getStr.len > 0:
        return (true, SearchEngine(name: name, queryUrl: c{"url"}.getStr, suggestUrl: c{"suggestionsUrl"}.getStr))

proc pickedEngine(settings: JsonNode): string =
  ## The engine name Settings.json's "searchEngine" names ("engine", or the older "name"), or "".
  if settings == nil or settings.kind != JObject: return ""
  let e = if settings.hasKey("engine"): settings{"engine"} else: settings{"name"}
  if e != nil and e.kind == JString: e.getStr else: ""

proc settingsFile(args: seq[string]): string =
  let dirs = ladybirdProfileDirs(args)
  if dirs.ok: dirs.config / "Settings.json" else: ""

proc readSettings(file: string): JsonNode =
  try: parseJson(readFile(file)) except CatchableError: newJObject()

proc writeSearchSettings(file: string, search: JsonNode) =
  ## Puts `search` as "searchEngine" into Settings.json `file`, keeping everything else.
  let before = try: readFile(file) except CatchableError: ""
  var j = try: parseJson(before) except CatchableError: newJObject()
  if j.kind != JObject: j = newJObject()
  j["searchEngine"] = search
  let after = j.pretty(4)
  if after == before: return
  try:
    createDir(file.parentDir)
    writeFileAtomic(file, after)
  except CatchableError: discard

proc markerFile(): string = profileFile("search_engine.json")

proc defaultSearchEngine*(file: string) =
  ## Makes Google the engine of the profile whose Settings.json is `file`, once, unless it has one.
  if incognito or file.len == 0 or fileExists(markerFile()): return
  let j = readSettings(file)
  var search = if j.kind == JObject and j{"searchEngine"} != nil and j{"searchEngine"}.kind == JObject:
    j{"searchEngine"} else: newJObject()
  if pickedEngine(search).len == 0:
    if search.hasKey("name"): search.delete("name")
    search["engine"] = %defaultEngine
    search["suggestions"] = %true
    writeSearchSettings(file, search)
  try: writeJsonFile(markerFile(), %*{"defaulted": true}) except CatchableError: discard

proc prepareSearch*() =
  ## Runs right before webby_init: the normal profile gets Google once; an incognito window's throwaway profile
  ## gets the normal profile's choice.
  if incognito:
    let normal = settingsFile(originalLadybirdArgs)
    let own = settingsFile(ladybirdArgs())
    if normal.len == 0 or own.len == 0 or own == normal: return
    let s = readSettings(normal){"searchEngine"}
    writeSearchSettings(own, if s != nil and s.kind == JObject: s
                             else: %*{"engine": defaultEngine, "suggestions": true})
  else:
    defaultSearchEngine(settingsFile(ladybirdArgs()))

var
  cachedFile: string
  cachedTime: Time
  cached: tuple[engine: SearchEngine, suggestions: bool]
  cacheValid: bool

proc currentEngine*(): tuple[engine: SearchEngine, suggestions: bool] =
  ## The engine typed text searches, and whether to ask it for suggestions; re-read when about:settings changes it.
  let file = settingsFile(ladybirdArgs())
  let t = try: getLastModificationTime(file) except CatchableError: Time()
  if cacheValid and file == cachedFile and t == cachedTime: return cached
  let search = if file.len > 0: readSettings(file){"searchEngine"} else: nil
  let (found, e) = findEngine(pickedEngine(search), search)
  cached = if found: (e, search{"suggestions"}.getBool and e.suggestUrl.len > 0)
           else: (findEngine(defaultEngine, nil)[1], false)
  (cachedFile, cachedTime, cacheValid) = (file, t, true)
  cached

proc fill(url, query: string): string = url.replace("%s", encodeUrl(query, usePlus = false))

proc searchUrl*(e: SearchEngine, query: string): string = fill(e.queryUrl, query)
proc suggestionsUrl*(e: SearchEngine, query: string): string = fill(e.suggestUrl, query)

proc parseSuggestions*(e: SearchEngine, body: string): seq[string] =
  ## The suggestions in a reply from `e`'s suggestions URL (LibWebView/Autocomplete.cpp's three formats).
  let j = try: parseJson(body) except CatchableError: return
  case e.format
  of opensearch:
    if j.kind == JArray and j.len >= 2 and j[1].kind == JArray:
      for s in j[1].getElems:
        if s.kind == JString: result.add s.getStr
  of duckduckgo:
    for s in j.getElems:
      if s.kind == JObject and s{"phrase"} != nil: result.add s{"phrase"}.getStr
  of yahoo:
    if j.kind == JObject and j{"r"} != nil:
      for s in j{"r"}.getElems:
        if s.kind == JObject and s{"k"} != nil: result.add s{"k"}.getStr
