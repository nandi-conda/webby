## What Summarize sends, on the desktop and Android: the page-text and jump-to-text page scripts, the prompts, and
## the chat completions requests.

import std/[json, strutils, times]

const
  deepSeekKeySecret* = "deepseek-api-key"   ## the key's name among the vault's secrets (synced unless unticked)
  mimoKeySecret* = "mimo-api-key"           ## the Xiaomi MiMo key's name
  metaKeySecret* = "meta-api-key"           ## the Meta Model API key's name
  providerSecret* = "summarize-provider"    ## the chosen provider's id, a secret that syncs along with its key
  maxSummaryInputChars* = 40000             ## longer pages are cut before they're sent

type
  Provider* = enum
    ## A chat completions service Summarize can ask.
    deepSeek, mimo, meta

  ProviderInfo* = object
    id*, name*, keySecret*, endpoint*, model*, site*: string
    status*: string      ## status page named when a request hangs, or ""
    keyHeader*: string   ## the header the key goes in bare; "" means Authorization: Bearer

const providers*: array[Provider, ProviderInfo] = [
  deepSeek: ProviderInfo(id: "deepseek", name: "DeepSeek", keySecret: deepSeekKeySecret,
    endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-flash", site: "platform.deepseek.com",
    status: "status.deepseek.com"),
  # platform.xiaomimimo.com: pay-as-you-go keys (sk-...) on api.xiaomimimo.com, sent in an `api-key` header. The V2.6
  # models think first by default; requests turn that off so the answer starts at once.
  mimo: ProviderInfo(id: "mimo", name: "Xiaomi MiMo", keySecret: mimoKeySecret,
    endpoint: "https://api.xiaomimimo.com/v1/chat/completions", model: "mimo-v2.6-flash",
    site: "platform.xiaomimimo.com", keyHeader: "api-key"),
  # dev.meta.ai's Model API, Bearer keys. Muse Spark always reasons ("none" is refused): requests ask for the
  # shortest pass.
  meta: ProviderInfo(id: "meta", name: "Meta", keySecret: metaKeySecret,
    endpoint: "https://api.meta.ai/v1/chat/completions", model: "muse-spark-1.3", site: "dev.meta.ai")]

proc info*(p: Provider): ProviderInfo = providers[p]
proc name*(p: Provider): string = providers[p].name

proc providerById*(id: string): Provider =
  for p in Provider:
    if providers[p].id == id: return p
  deepSeek

proc chosenProvider*(secret: proc (name: string): string): Provider =
  ## The chosen provider (the providerSecret), unless only another has a key.
  if secret == nil: return deepSeek
  result = providerById(secret(providerSecret))
  if secret(providers[result].keySecret).len > 0: return
  for p in Provider:
    if secret(providers[p].keySecret).len > 0: return p

proc busyMessage*(p: Provider): string =
  ## For a request accepted but held without a word for 90 s.
  p.name & " accepted the request but hasn't sent anything back in 90 seconds. It may be having an outage" &
    (if p.info.status.len > 0: ": see " & p.info.status else: "") & "."

# The page scripts (scripts/page_text.js, scripts/jump_to_text.js). pageTextScript posts
# {"type": "pagetext", "id", "selection", "title", "url", "lang", "text"} as a page message (headings as "## ...");
# jumpToTextScript scrolls to the words a summary's [§](#words) link cites and flashes them.
# askSelectionScript (scripts/ask_selection.js, run on every page) shows an "Ask AI about this" button by selected
# text and posts {"type": "askselection", "text", "title", "url"} when it's clicked.
const pageTextTemplate = staticRead("../../scripts/page_text.js")
const jumpTemplate = staticRead("../../scripts/jump_to_text.js")
const askSelectionTemplate = staticRead("../../scripts/ask_selection.js")

proc pageTextScript*(prefix, id: string, wholePage = false): string =
  ## `wholePage`: the page's text even when some of it is selected.
  pageTextTemplate.multiReplace(("${jsonEncode(prefix)}", $(%prefix)), ("${jsonEncode(id)}", $(%id)),
    ("$maxSummaryInputChars", $maxSummaryInputChars), ("$minSelection", if wholePage: "Infinity" else: "200"))

proc askSelectionScript*(prefix: string): string = askSelectionTemplate.replace("${jsonEncode(prefix)}", $(%prefix))

proc jumpToTextScript*(words: string): string = jumpTemplate.replace("${jsonEncode(words)}", $(%words))

# How the model links points to the part of the page they come from.
const sourceLinkRule = "End each bullet with a source link to the part of the page it comes from, written " &
  "[§](#words), where words are 3 to 8 consecutive words copied exactly from the page text; a section heading " &
  "(marked ## in the text) is best. Copy them character for character in the page's own language, even when it " &
  "isn't English, without parentheses or brackets. No other links."

const summaryPrompt = "You summarize web pages for a browser's summary panel. This needs to be in English: write the " &
  "summary in English whatever the language of the page. Start with one or two sentences saying what the " &
  "page is about, then give the key points as a short markdown bullet list. Use markdown: **bold** for key " &
  "names and figures, `code` for code, and a short ### heading only when the page covers clearly separate " &
  "topics. No tables or images. " & sourceLinkRule

const questionPrompt = "You answer questions about a web page the user is reading, in a browser's side panel. Use " &
  "the page text and your earlier summary. This needs to be in English: answer in English, concisely, in markdown " &
  "(bullet lists, **bold**, `code`; no tables or images). If the page doesn't say, say so before adding what you " &
  "know. Where a point comes from the page, you may end it with a source link written [§](#words), where words " &
  "are 3 to 8 consecutive words copied exactly from the page text, in its own language."

const selectionPrompt = "You answer questions about a passage the user selected on a web page they are reading, " &
  "in a browser's side panel. The rest of the page is there for context. This needs to be in English: answer in " &
  "English, concisely, in markdown (bullet lists, **bold**, `code`; no tables or images). Explain terms, claims " &
  "and references in the passage when asked; if the page doesn't say, say so before adding what you know. No links."


type PageText* = object
  ## What the page-text script sends back.
  title*, url*, text*: string
  selection*: bool

proc waitingText*(hasPage, queued: bool, provider = deepSeek): string =
  ## What the summary panel says before the first piece of the summary comes.
  if not hasPage: "Reading the page…"
  elif queued: provider.name & " hasn't started answering yet…"
  else: "Asking " & provider.name & "…"

proc withProvider(body: JsonNode, provider: Provider): JsonNode =
  body["model"] = %provider.info.model
  case provider
  of mimo: body["thinking"] = %*{"type": "disabled"}
  of meta: body["reasoning_effort"] = %"minimal"
  of deepSeek: body["thinking"] = %*{"type": "disabled"}   # answer at once; tool calls then need no reasoning_content
  body

# ---------------------------------------------------------------------------------------------------------------
# Requests

proc summaryRequest*(page: PageText, provider = deepSeek): JsonNode =
  withProvider(%*{"model": "deepseek-chat", "stream": true, "temperature": 0.3, "messages": [
    {"role": "system", "content": summaryPrompt},
    {"role": "user", "content": (if page.selection: "Summarize this text selected on" else: "Summarize this page:") &
      " " & (if page.title.len == 0: "" else: "\"" & page.title & "\" ") & "(" & page.url & ")\n\n" & page.text}]}, provider)

proc questionRequest*(hasPage: bool, page: PageText, title, url, summary: string,
                      earlier: seq[tuple[question, answer: string]], question: string,
                      provider = deepSeek): JsonNode =
  ## A follow-up question with the page text (or, without it, its title and address), the summary and the earlier
  ## questions and answers as context.
  let context =
    if not hasPage: "The page \"" & title & "\" (" & url & "). Its text isn't available any more; go " &
      "by your summary."
    else: (if page.selection: "Text selected on" else: "The page") & " \"" &
      (if page.title.len == 0: title else: page.title) & "\" (" & page.url & "):\n\n" & page.text
  var messages = %*[{"role": "system", "content": questionPrompt}, {"role": "user", "content": context},
    {"role": "assistant", "content": summary}]
  for qa in earlier:
    messages.add %*{"role": "user", "content": qa.question}
    messages.add %*{"role": "assistant", "content": qa.answer}
  messages.add %*{"role": "user", "content": question}
  withProvider(%*{"model": "deepseek-chat", "stream": true, "temperature": 0.3, "messages": messages}, provider)

proc selectionQuestionRequest*(selected: string, hasPage: bool, page: PageText, title, url: string,
                               earlier: seq[tuple[question, answer: string]], question: string,
                               provider = deepSeek): JsonNode =
  ## A question about `selected`, with the page's text (when it was read) and the earlier questions and answers.
  let name = if page.title.len > 0: page.title else: title
  var context = "The page \"" & name & "\" (" & (if page.url.len > 0: page.url else: url) & ")"
  if hasPage and page.text.strip.len > 0: context.add ":\n\n" & page.text & "\n\n---\n\n"
  else: context.add ". "
  context.add "The user selected this passage:\n\n" & selected
  var messages = %*[{"role": "system", "content": selectionPrompt}, {"role": "user", "content": context}]
  for qa in earlier:
    messages.add %*{"role": "user", "content": qa.question}
    messages.add %*{"role": "assistant", "content": qa.answer}
  messages.add %*{"role": "user", "content": question}
  withProvider(%*{"model": "deepseek-chat", "stream": true, "temperature": 0.3, "messages": messages}, provider)

# ---------------------------------------------------------------------------------------------------------------
# Web search: the model may call a `web_search` function; Webby runs it on DeepSeek's Search API (deepseek.searchWeb)
# and sends the results back as the tool's answer.

const webSearchToolName* = "web_search"

const webSearchRule = " You can search the web with the web_search tool. Use it when the question needs what the " &
  "page doesn't have: recent events, other sources, checking a claim, background on a name or term. When the page " &
  "doesn't answer the question, search instead of answering from memory, and never say you can't search the web. " &
  "Don't search for what the page already answers. Search queries are short keyword queries (at most 128 characters), in " &
  "the language most likely to find good sources. When a point comes from a web result, end it with a link to " &
  "that result written [site name](url), using the result's own url; such links are allowed even where other " &
  "links are not."

proc withWebSearch*(request: JsonNode): JsonNode =
  ## `request` (a chat completions request) with the web_search tool offered and the system prompt telling the
  ## model how to use it.
  result = request
  let messages = result{"messages"}
  if messages != nil and messages.kind == JArray and messages.len > 0 and messages[0]{"role"}.getStr == "system":
    messages[0]["content"] = %(messages[0]{"content"}.getStr & webSearchRule &
      " Today is " & now().format("yyyy-MM-dd") & ".")
  result["tools"] = %*[{"type": "function", "function": {
    "name": webSearchToolName,
    "description": "Search the web. Returns the best results with title, url, site, date and a summary of each.",
    "parameters": {"type": "object", "properties": {
      "query": {"type": "string", "description": "The search query: a few keywords, at most 128 characters. " &
        "Supports site:, -site:, \"exact phrase\", lang:en, after:2025-01-01 and before: operators."}},
      "required": ["query"]}}}]

proc searchQuery*(arguments: string): string =
  ## The query from a web_search call's JSON arguments ("" when there is none).
  let j = try: parseJson(arguments) except CatchableError: nil
  if j != nil and j.kind == JObject: j{"query"}.getStr.strip else: ""

const searchWords = ["websearch", "web search", "search", "look up", "lookup", "look it up", "google",
  "internet", "on the web", "latest news"]

proc asksForSearch*(question: string): bool =
  ## Whether `question` asks for a web search ("search the web for…", "look it up", "websearch").
  let q = " " & question.toLowerAscii & " "
  for w in searchWords:
    if w in q: return true

proc searchTermsFor*(question, quote, selected, title: string): string =
  ## A search query for `question` when Webby searches itself: the question without the words asking for a search;
  ## when little is left, what it is about (the quoted text, the selection or the page's title).
  var q = " " & question.toLowerAscii & " "
  for w in searchWords: q = q.replace(w, " ")
  for w in [" the ", " web ", " for ", " about ", " this ", " please ", " can you ", " what ", " is ", " it "]:
    q = q.replace(w, " ")
  q = q.splitWhitespace.join(" ").strip(chars = {' ', '?', '.', '!', ','})
  let about = (if quote.strip.len > 0: quote elif selected.strip.len > 0: selected else: title).splitWhitespace.join(" ")
  result = if q.len >= 4: q else: about
  if result.len == 0: result = question.strip

proc withSearchResults*(request: JsonNode, query, results: string) =
  ## Puts web search results for `query` in front of the question (the last message) of `request`.
  let messages = request{"messages"}
  if messages == nil or messages.kind != JArray or messages.len == 0: return
  let last = messages[messages.len - 1]
  last["content"] = %("Web search results for \"" & query & "\" (" & now().format("yyyy-MM-dd") & "):\n\n" &
    results & "\n---\n\nUse these results where they help, and end each point that comes from one with a link " &
    "to it written [site name](url). The question:\n\n" & last{"content"}.getStr)

const searchDecisionPrompt = "You decide whether a question a user asks about a web page they are reading needs a " &
  "web search. Search when the answer needs what the page itself is unlikely to say: recent or current events, " &
  "facts to check, other sources or opinions, background on a person, project, product or term the page only " &
  "names, or when the user asks for a search. Don't search for questions about the page's own content (explain, " &
  "summarize, define something the page explains). Reply with JSON only: {\"search\": true or false, \"query\": " &
  "\"a short keyword search query, at most 128 characters, or empty\"}."

proc searchDecisionRequest*(question, about, title, url, summary: string): JsonNode =
  ## The short DeepSeek request that decides whether `question` needs a web search (see parseSearchDecision).
  ## `about` is the quoted or selected text the question is about, `summary` the page's summary (both cut short).
  proc cut(s: string, n: int): string =
    result = s.splitWhitespace.join(" ")
    if result.len > n:
      var i = n
      while i > 0 and (result[i].ord and 0xC0) == 0x80: dec i
      result = result[0 ..< i] & "…"
  var context = "The page: \"" & title & "\" (" & url & ")\n"
  if summary.strip.len > 0: context.add "Its summary: " & cut(summary, 1500) & "\n"
  if about.strip.len > 0: context.add "The question is about this text: " & cut(about, 1000) & "\n"
  context.add "Today is " & now().format("yyyy-MM-dd") & ".\n\nThe question: " & question
  withProvider(%*{"model": "deepseek-flash", "stream": true, "temperature": 0, "max_tokens": 80, "messages": [
    {"role": "system", "content": searchDecisionPrompt}, {"role": "user", "content": context}]}, deepSeek)

proc parseSearchDecision*(reply: string): tuple[search: bool, query: string] =
  ## The decision in a searchDecisionRequest reply: (false, "") when it can't be read.
  let a = reply.find('{')
  let b = reply.rfind('}')
  if a < 0 or b <= a: return
  let j = try: parseJson(reply[a .. b]) except CatchableError: nil
  if j == nil or j.kind != JObject: return
  result.query = j{"query"}.getStr.strip
  result.search = j{"search"}.getBool and result.query.len > 0
