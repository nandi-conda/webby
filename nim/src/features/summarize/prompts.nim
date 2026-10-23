## What Summarize sends, on the desktop and Android: the page-text and jump-to-text page scripts, the prompts, and
## the chat completions requests.

import std/[json, strutils]

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
    endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-chat", site: "platform.deepseek.com",
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
  of deepSeek: discard
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
