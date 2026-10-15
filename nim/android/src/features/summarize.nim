## Summarize on Android (src/features/summarize.nim on the desktop): reads the page's text with the Dart app's page
## script, streams a summary from DeepSeek (summarize/deepseek.nim over base.httpStream), answers follow-up questions
## and saves both in summaries.json (summarize/cache.nim). Java's SummaryScreen shows the "summary" events this
## sends: the whole state, with the markdown already turned into HTML. The API key is a vault secret, synced unless unticked.

import std/[random, strutils, times]
import ../core
import ../../../src/features/summarize/[cache, deepseek, markdown, prompts]

type
  Question = ref object
    question, answer, error: string
    running: bool

  Job = ref object
    tab: Tab
    running, selection: bool
    title, url, text, error: string
    savedAt, madeAt: int64
    questions: seq[Question]
    generation: int
    key: string
    page: PageText
    hasPage: bool
    chat: Chat

var
  jobs: Table[int, Job]   ## by tab id
  shown: Job              ## the job the screen shows; nil when it is closed
  pendingReads: Table[string, proc (ok: bool, page: PageText)]
  sendQueued = false

proc nowMs(): int64 = (epochTime() * 1000).int64

proc apiKey(): string =
  if getSecret != nil: getSecret(deepSeekKeySecret) else: ""

proc answering(job: Job): bool = job.questions.len > 0 and job.questions[^1].running

proc stateJson(job: Job): JsonNode =
  let busy = job.running or job.answering
  var qs = newJArray()
  for qa in job.questions:
    qs.add %*{"question": qa.question, "html": markdownHtml(qa.answer.strip), "running": qa.running,
      "error": qa.error}
  let saved = if job.savedAt != 0 and not job.running:
                "Saved summary from " & fromUnix(job.savedAt div 1000).local.format("d MMM yyyy, HH:mm") &
                  ". Summarize again for a new one."
              else: ""
  %*{"open": true, "title": job.title, "url": job.url, "selection": job.selection, "running": job.running,
    "busy": busy, "error": job.error, "html": markdownHtml(job.text.strip), "text": job.text, "saved": saved,
    "questions": qs, "hasKey": apiKey().len > 0,
    "canAsk": apiKey().len > 0 and job.text.strip.len > 0 and not job.running and job.error.len == 0 and
      not job.answering}

proc sendNow() =
  sendQueued = false
  if shown == nil: event("summary", %*{"open": false})
  else: event("summary", stateJson(shown))

proc changed(job: Job) =
  ## Tells Java soon (at most every 80 ms while text streams in) if the screen shows `job`.
  if job != shown or sendQueued: return
  sendQueued = true
  after(80, sendNow)

# ---------------------------------------------------------------------------------------------------------------
# Reading the page

proc readPageText(t: Tab, done: proc (ok: bool, page: PageText)) =
  if t == nil or t.closed or t.messagePrefix.len == 0:
    done(false, PageText())
    return
  var id = ""
  for _ in 0 ..< 8: id.add toHex(rand(255), 2).toLowerAscii
  pendingReads[id] = done
  t.runJs(pageTextScript(t.messagePrefix, id))
  wake()
  after(8000, proc () =
    if id in pendingReads:
      let cb = pendingReads[id]
      pendingReads.del id
      cb(false, PageText()))

proc onPageMessage(t: Tab, j: JsonNode): bool =
  if j{"type"}.getStr != "pagetext": return false
  let id = j{"id"}.getStr
  if id notin pendingReads: return true
  let cb = pendingReads[id]
  pendingReads.del id
  cb(true, PageText(title: j{"title"}.getStr, url: (if j{"url"} != nil: j{"url"}.getStr else: t.url),
    text: j{"text"}.getStr, selection: j{"selection"}.getBool))
  true

# ---------------------------------------------------------------------------------------------------------------
# Jobs (as on the desktop)

proc jobOf(t: Tab): Job =
  result = jobs.getOrDefault(t.id)
  if result == nil:
    result = Job(tab: t)
    jobs[t.id] = result

proc save(job: Job) =
  if job.key.len == 0 or job.text.strip.len == 0: return
  if job.madeAt == 0: job.madeAt = nowMs()
  var s = CachedSummary(title: job.title, url: job.url, text: job.text, at: job.madeAt, selection: job.selection)
  for qa in job.questions:
    if not qa.running and qa.error.len == 0 and qa.answer.strip.len > 0: s.questions.add (qa.question, qa.answer)
  storeSummary(job.key, s)

proc stopChat(job: Job) =
  job.chat.cancel()
  job.chat = nil

proc showSaved(job: Job, key: string, saved: CachedSummary) =
  job.key = key
  job.questions.setLen 0
  for qa in saved.questions: job.questions.add Question(question: qa.question, answer: qa.answer)
  job.running = false
  job.error = ""
  job.title = saved.title
  job.url = saved.url
  job.text = saved.text
  job.selection = saved.selection
  job.savedAt = saved.at
  job.madeAt = saved.at
  changed(job)

proc start(job: Job, key: string, fresh: bool) =
  job.stopChat()
  inc job.generation
  let generation = job.generation
  let t = job.tab
  job.running = true
  job.error = ""
  job.text = ""
  job.title = t.title
  job.url = t.url
  job.savedAt = 0
  job.questions.setLen 0
  job.key = ""
  job.hasPage = false
  job.madeAt = 0
  changed(job)
  proc fail(message: string) =
    if generation != job.generation: return
    job.error = message
    job.running = false
    changed(job)
  readPageText(t, proc (ok: bool, page: PageText) =
    if generation != job.generation: return
    if not ok: (fail("Couldn't read the text of this page."); return)
    let k = summaryKey(page.url, if page.selection: page.text else: "")
    let (found, saved) = if fresh: (false, CachedSummary()) else: lookupSummary(k)
    job.page = page
    job.hasPage = true
    if found:
      job.showSaved(k, saved)
      return
    job.key = k
    job.title = if page.title.len == 0: t.title else: page.title
    job.url = page.url
    job.selection = page.selection
    if page.text.strip.len < 40: (fail("This page has no text to summarize."); return)
    if key.len == 0: (fail("Add a DeepSeek API key under Summarize settings."); return)
    changed(job)
    job.chat = streamChat(key, summaryRequest(page),
      proc (piece: string) =
        if generation != job.generation: return
        job.text.add piece
        changed(job),
      proc (error: string) =
        if generation != job.generation: return
        job.chat = nil
        if error.len > 0: (fail(error); return)
        if job.text.strip.len == 0: (fail("DeepSeek sent back an empty summary."); return)
        job.save()
        job.running = false
        changed(job)))

proc ask(job: Job, key, text: string) =
  let question = text.strip
  if question.len == 0 or key.len == 0 or job.running or job.answering or job.text.strip.len == 0: return
  let generation = job.generation
  var earlier: seq[tuple[question, answer: string]]
  for qa in job.questions:
    if qa.error.len == 0 and qa.answer.strip.len > 0: earlier.add (qa.question, qa.answer)
  let entry = Question(question: question, running: true)
  job.questions.add entry
  changed(job)
  proc send() =
    if generation != job.generation: return
    job.chat = streamChat(key, questionRequest(job.hasPage, job.page, job.title, job.url, job.text, earlier,
      question),
      proc (piece: string) =
        if generation != job.generation: return
        entry.answer.add piece
        changed(job),
      proc (error: string) =
        if generation != job.generation: return
        job.chat = nil
        entry.running = false
        entry.error = if error.len > 0: error
                      elif entry.answer.strip.len == 0: "DeepSeek sent back an empty answer."
                      else: ""
        if entry.error.len == 0: job.save()
        changed(job))
  # A saved summary has no page text with it: read the page again if the tab still shows it.
  if not job.hasPage and not job.selection and summaryKey(job.tab.url) == summaryKey(job.url):
    readPageText(job.tab, proc (ok: bool, page: PageText) =
      if ok:
        job.page = page
        job.hasPage = true
      send())
  else: send()

proc stop(job: Job) =
  job.stopChat()
  inc job.generation
  if job.answering:
    job.questions[^1].running = false
    if job.questions[^1].error.len == 0: job.questions[^1].error = "Stopped."
  job.running = false

# ---------------------------------------------------------------------------------------------------------------
# Commands from SummaryScreen.java

proc startCmd(args: JsonNode): JsonNode =
  ## {fresh}: opens the screen on the current tab's summary, starting one unless it has one (or `fresh`).
  let t = current()
  if t == nil: return nil
  let job = jobOf(t)
  shown = job
  let fresh = args{"fresh"}.getBool
  if fresh or (job.text.len == 0 and not job.running) or summaryKey(job.url) != summaryKey(t.url) or
      job.error.len > 0:
    job.start(apiKey(), fresh)
  sendNow()
  nil

proc askCmd(args: JsonNode): JsonNode =
  if shown != nil: shown.ask(apiKey(), args{"text"}.getStr)
  nil

proc closeCmd(args: JsonNode): JsonNode =
  ## The screen closed: a summary still coming keeps coming (as when the desktop panel is hidden).
  shown = nil
  nil

proc stopCmd(args: JsonNode): JsonNode =
  if shown != nil:
    shown.stop()
    changed(shown)
  nil

proc jumpCmd(args: JsonNode): JsonNode =
  ## {words}: scrolls the page to them; false when the tab shows another page by now.
  let job = shown
  if job == nil or job.tab.closed or summaryKey(job.tab.url) != summaryKey(job.url): return %false
  job.tab.runJs(jumpToTextScript(args{"words"}.getStr))
  wake()
  %true

proc keyCmd(args: JsonNode): JsonNode =
  ## {} -> {hasKey, vault, sync}; {key, sync?} stores it ("" removes it); {sync} alone changes whether it syncs.
  let sync = if args{"sync"}.kind == JBool: args["sync"].getBool
             else: secretSyncs == nil or secretSyncs(deepSeekKeySecret)
  if args.hasKey("key") or args{"sync"}.kind == JBool:
    if setSecret == nil: return %*{"error": "The password vault isn't available."}
    let key = if args.hasKey("key"): args{"key"}.getStr.strip else: apiKey()
    setSecret(deepSeekKeySecret, key, sync)
    if apiKey() != key: return %*{"error": "The password vault isn't open, so the key wasn't saved."}
    if shown != nil: changed(shown)
  %*{"hasKey": apiKey().len > 0, "vault": setSecret != nil,
     "sync": secretSyncs == nil or secretSyncs(deepSeekKeySecret)}

proc install*() =
  pageMessageHooks.add onPageMessage
  tabClosedHooks.add proc (t: Tab) =
    let job = jobs.getOrDefault(t.id)
    if job != nil:
      job.stop()
      jobs.del t.id
      if shown == job:
        shown = nil
        sendNow()
  commands["summarize.start"] = startCmd
  commands["summarize.ask"] = askCmd
  commands["summarize.close"] = closeCmd
  commands["summarize.stop"] = stopCmd
  commands["summarize.jump"] = jumpCmd
  commands["summarize.key"] = keyCmd
