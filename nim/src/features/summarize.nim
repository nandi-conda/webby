## Summarize: reads the page's text through a page script, streams a summary from
## DeepSeek, Xiaomi MiMo or Meta into the side panel, answers follow-up questions about the page, and saves both (summarize/cache.nim).
## Each provider's API key is a secret in the password vault, synced to the other devices unless unticked, and so
## is the choice of provider; without the vault (getSecret is nil) they are kept in memory until Webby quits.

import std/[json, random, strutils, times]
import ../browser
from nimkit/core as kit import nil
when not defined(android): from nimkit/backend/gtk as nkgtk import nil
import summarize/[cache, deepseek, markdown, prompts]

type
  Question = ref object
    question, answer, error: string
    running: bool

  Job = ref object
    ## One tab's summary: the page it is for, the text so far, and whether it is still coming.
    tab: Tab
    open, running, selection: bool
    title, url, text, error: string
    savedAt: int64             ## ms; when the summary shown was made, if it came from the cache
    questions: seq[Question]
    generation: int
    key: string
    page: PageText
    hasPage: bool
    madeAt: int64
    chat: Chat
    provider: Provider         ## who the summary was asked of

  Panel = object
    root, busyLabel, copyButton, redoButton, content, scroller, entry, sendButton: kit.Widget

var
  jobs: Table[string, Job]     ## by the tab's messagePrefix
  memorySecrets: Table[string, string]   ## the keys and choice when there's no vault to keep them in
  pendingReads: Table[string, proc (ok: bool, page: PageText)]
  panelJob: Job                ## the job the side panel shows, nil when it shows something else
  panel: Panel
  switchingPanel = false
  renderQueued = false

proc nowMs(): int64 = (epochTime() * 1000).int64

proc later(ms: int, action: proc ()) = discard after(ms, action)

# ---------------------------------------------------------------------------------------------------------------
# The API key

proc secret(name: string): string =
  if getSecret != nil: getSecret(name) else: memorySecrets.getOrDefault(name)

proc storeSecret(name, value: string, sync: bool) =
  if setSecret != nil: setSecret(name, value, sync)
  else: memorySecrets[name] = value

proc provider(): Provider = chosenProvider(secret)
proc apiKey(): string = secret(provider().info.keySecret)


proc render()

proc showSummarizeSettings*(onSaved: proc () = nil) =
  ## The dialog where the provider is picked and its API key entered, replaced or removed. onSaved runs after Save.
  if incognito and setSecret != nil:
    kit.alert("Set the Summarize API key in a normal window.")
    return
  var shownProvider = provider()
  let box = kit.column()
  box.spacing = 6
  discard kit.sized(box, 420)
  var names: seq[string]
  for p in Provider: names.add p.name
  let providerBox = kit.dropdown(names, shownProvider.ord)
  let label = kit.label("")
  let entry = kit.entry("Paste the key")
  kit.`password=`(entry, true)
  let show = kit.check("Show key", false, proc (on: bool) = kit.`password=`(entry, not on))
  let sync = kit.check("Sync this key to my other devices",
    secretSyncs == nil or secretSyncs(shownProvider.info.keySecret))
  let info = kit.addClass(kit.addClass(kit.label(""), "dim"), "small")
  kit.add(box, kit.label("Summarize with"))
  kit.add(box, kit.row(providerBox))
  kit.add(box, label)
  kit.add(box, entry)
  kit.add(box, show)
  if setSecret != nil: kit.add(box, sync)
  kit.add(box, info)
  proc update() =
    ## Fits the dialog to the provider picked.
    let p = Provider(max(0, kit.selected(providerBox)))
    let hasKey = secret(p.info.keySecret).len > 0
    kit.`text=`(label, if hasKey: "New " & p.name & " API key (one is saved)" else: p.name & " API key")
    if p != shownProvider:
      kit.`checked=`(sync, secretSyncs == nil or secretSyncs(p.info.keySecret))
    shownProvider = p
    let where =
      if setSecret != nil: "It is kept encrypted in the password vault; when it syncs, it travels end-to-end " &
        "encrypted like your passwords."
      else: "The password vault isn't available, so the key is kept in memory until Webby quits."
    kit.`text=`(info, "Create a key at " & p.info.site & ". " & where & " Summarize sends the page's text to " &
      p.name & ".")
  update()
  providerBox.onSelect = proc (i: int) = update()
  var d: kit.Dialog
  d = kit.dialog("Summarize settings", box, @["Remove key", "Cancel", "Save"], destructive = 0, onResult =
    proc (r: int) =
      if r notin [0, 2]: return
      let text = kit.text(entry).strip
      let syncs = kit.checked(sync)
      let p = shownProvider
      let name = p.info.keySecret
      let hasKey = secret(name).len > 0
      if r == 2 and text.len == 0:
        # With a key saved, Save with the field empty just switches to the provider and changes whether it syncs.
        if not hasKey:
          kit.showDialog(d)
          kit.focus(entry)
          return
        storeSecret(name, secret(name), syncs)
      elif r == 2: storeSecret(name, text, syncs)
      else: storeSecret(name, "", syncs)
      # The choice travels with the key: a device that gets the key also switches to it.
      if secret(providerSecret) != p.info.id or (secretSyncs != nil and secretSyncs(providerSecret) != syncs):
        storeSecret(providerSecret, p.info.id, syncs)
      render()
      if r == 2 and onSaved != nil: onSaved())
  entry.onSubmit = proc (t: string) = kit.dialogResult(d, 2)
  kit.focus(entry)

# ---------------------------------------------------------------------------------------------------------------
# Reading the page

proc readPageText(t: Tab, done: proc (ok: bool, page: PageText)) =
  ## Runs the page-text script in `t`; `done` gets its message, or ok = false after 8 s.
  if t == nil or t.closed or t.messagePrefix.len == 0:
    done(false, PageText())
    return
  var id = ""
  for _ in 0 ..< 8: id.add toHex(rand(255), 2).toLowerAscii
  pendingReads[id] = done
  t.runJs(pageTextScript(t.messagePrefix, id))
  wake()
  later(8000, proc () =
    if id in pendingReads:
      let cb = pendingReads[id]
      pendingReads.del id
      cb(false, PageText()))

proc onPageMessage(t: Tab, msg: string): bool =
  if not msg.startsWith("{") or "\"pagetext\"" notin msg: return false
  let j = try: parseJson(msg) except CatchableError: nil
  if j == nil or j.kind != JObject or j{"type"}.getStr != "pagetext": return false
  let id = j{"id"}.getStr
  if id notin pendingReads: return true
  let cb = pendingReads[id]
  pendingReads.del id
  cb(true, PageText(title: j{"title"}.getStr, url: (if j{"url"} != nil: j{"url"}.getStr else: t.url),
    text: j{"text"}.getStr, selection: j{"selection"}.getBool))
  true

# ---------------------------------------------------------------------------------------------------------------
# Jobs

proc changed(job: Job) =
  ## Re-renders the panel soon (at most every 50 ms while text streams in) if it shows `job`.
  if job != panelJob or renderQueued: return
  renderQueued = true
  later(50, proc () =
    renderQueued = false
    render())

proc jobOf(t: Tab): Job =
  result = jobs.getOrDefault(t.messagePrefix)
  if result == nil:
    result = Job(tab: t)
    jobs[t.messagePrefix] = result

proc answering(job: Job): bool = job.questions.len > 0 and job.questions[^1].running

proc showSaved(job: Job, key: string, saved: CachedSummary) =
  inc job.generation
  job.key = key
  job.questions.setLen 0
  for qa in saved.questions: job.questions.add Question(question: qa.question, answer: qa.answer)
  job.open = true
  job.running = false
  job.error = ""
  job.title = saved.title
  job.url = saved.url
  job.text = saved.text
  job.selection = saved.selection
  job.savedAt = saved.at
  job.madeAt = saved.at
  changed(job)

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

proc start(job: Job, key: string, provider: Provider, fresh = false) =
  ## Reads the page and asks `provider` for a summary. A summary saved for the same page (or selection) is shown
  ## instead unless `fresh`.
  job.stopChat()
  inc job.generation
  let generation = job.generation
  let t = job.tab
  job.open = true
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
  job.provider = provider
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
    changed(job)
    job.chat = streamChat(provider, key, summaryRequest(page, provider),
      proc (piece: string) =
        if generation != job.generation: return
        job.text.add piece
        changed(job),
      proc (error: string) =
        if generation != job.generation: return
        job.chat = nil
        if error.len > 0: (fail(error); return)
        if job.text.strip.len == 0: (fail(provider.name & " sent back an empty summary."); return)
        job.save()
        job.running = false
        changed(job),
      proc () =
        if generation == job.generation: changed(job)))

proc ask(job: Job, key, text: string, provider: Provider) =
  ## Asks a follow-up question with the page text, the summary and the earlier questions as context.
  let question = text.strip
  if question.len == 0 or job.running or job.answering or job.text.strip.len == 0: return
  let generation = job.generation
  var earlier: seq[Question]
  for qa in job.questions:
    if qa.error.len == 0 and qa.answer.strip.len > 0: earlier.add qa
  let entry = Question(question: question, running: true)
  job.questions.add entry
  changed(job)
  proc send() =
    if generation != job.generation: return
    var context: seq[tuple[question, answer: string]]
    for qa in earlier: context.add (qa.question, qa.answer)
    job.chat = streamChat(provider, key,
      questionRequest(job.hasPage, job.page, job.title, job.url, job.text, context, question, provider),
      proc (piece: string) =
        if generation != job.generation: return
        entry.answer.add piece
        changed(job),
      proc (error: string) =
        if generation != job.generation: return
        job.chat = nil
        entry.running = false
        entry.error = if error.len > 0: error
                      elif entry.answer.strip.len == 0: provider.name & " sent back an empty answer."
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

proc jumpTo(job: Job, words: string): bool =
  ## Scrolls the page to the part a source link points at; false when the tab shows another page by now.
  if summaryKey(job.tab.url) != summaryKey(job.url): return false
  job.tab.runJs(jumpToTextScript(words))
  wake()
  true

proc close(job: Job) =
  job.stopChat()
  inc job.generation
  if job.answering:
    job.questions[^1].running = false
    if job.questions[^1].error.len == 0: job.questions[^1].error = "Stopped."
  job.open = false
  job.running = false

# ---------------------------------------------------------------------------------------------------------------
# The panel

const panelCss = markdownCss & """
.webby-summary-question { background-color: alpha(currentColor, 0.07); border-radius: 6px; padding: 7px 10px; }
.webby-summary-bar { margin: 2px 4px 2px 0; }
.webby-summary-content { padding: 14px; }
.webby-summary-ask { padding: 8px; }
"""

# Text sizes (body, then headings 1.35/1.2/1.08x and code 0.92x), in pt so they follow the
# desktop's DPI and text scale, times the panel's own zoom (Ctrl+plus/minus/0 or Ctrl+wheel over the panel).
const baseTextPt = 11.0
var
  textZoom = 1.0
  textCss: pointer   ## the GtkCssProvider holding the sizes

proc zoomFile(): string = profileFile("summary_text_zoom.json")

proc applyTextZoom() =
  let b = baseTextPt * textZoom
  proc pt(f: float): string = formatFloat(b * f, ffDecimal, 1) & "pt"
  let css = ".webby-md label, .webby-md entry { font-size: " & pt(1) & "; }\n" &
    ".webby-md .webby-md-h1 { font-size: " & pt(1.35) & "; }\n" &
    ".webby-md .webby-md-h2 { font-size: " & pt(1.2) & "; }\n" &
    ".webby-md .webby-md-h3 { font-size: " & pt(1.08) & "; }\n" &
    ".webby-md .webby-md-code label { font-size: " & pt(0.92) & "; }\n"
  when defined(android): discard css   # Android's labels take the system's text size
  else:
    if textCss == nil:
      textCss = gtk_css_provider_new()
      gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), textCss,
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1)
    discard gtk_css_provider_load_from_data(textCss, css.cstring, css.len, nil)

proc setTextZoom(z: float) =
  textZoom = clamp(z, 0.6, 2.5)
  applyTextZoom()
  if not incognito:
    try: writeJsonFile(zoomFile(), %*{"zoom": textZoom})
    except CatchableError: discard

when defined(android):
  proc panelHasFocus(): bool = false   # no keyboard shortcuts to zoom with

else:
  proc gtk_window_get_focus(w: Widget): Widget {.importc, cdecl.}
  proc gtk_widget_is_ancestor(w, ancestor: Widget): gboolean {.importc, cdecl.}
  proc gtk_widget_get_pointer(w: Widget, x, y: ptr cint) {.importc, cdecl.}

  proc panelHasFocus(): bool =
    ## Whether the keyboard focus or the mouse pointer is in the summary panel.
    if panel.root == nil or not sidePanelShowing(): return false
    let root = nkgtk.gtkWidget(panel.root)
    let f = gtk_window_get_focus(window)
    if f != nil and (f == root or gtk_widget_is_ancestor(f, root) != 0): return true
    var x, y: cint
    gtk_widget_get_pointer(root, addr x, addr y)
    x >= 0 and y >= 0 and x < gtk_widget_get_allocated_width(root) and y < gtk_widget_get_allocated_height(root)

  proc onPanelWheel(w: Widget, e: GEvent, d: pointer): gboolean {.cdecl.} =
    if (eventState(e) and GDK_CONTROL_MASK) == 0: return 0
    var dx, dy: cdouble
    var dir: cint
    if gdk_event_get_scroll_deltas(e, addr dx, addr dy) == 0:
      if gdk_event_get_scroll_direction(e, addr dir) == 0: return 1
      dy = (if dir == GDK_SCROLL_UP: -1.0 elif dir == GDK_SCROLL_DOWN: 1.0 else: 0.0)
    if dy != 0: setTextZoom(textZoom * (if dy < 0: 1.1 else: 1 / 1.1))
    1

proc withoutSourceLinks(text: string): string =
  ## `text` without its ` [§](#words)` links (for Copy).
  var i = 0
  while i < text.len:
    var start = i
    if text[i] == ' ' and text.continuesWith("[§](#", i + 1): start = i + 1
    if text.continuesWith("[§](#", start):
      var j = start + "[§](#".len
      while j < text.len and text[j] notin {')', '\n'}: inc j
      if j < text.len and text[j] == ')':
        i = j + 1
        continue
    result.add text[i]
    inc i
  result = result.strip

proc whenText(ms: int64): string =
  let t = fromUnix(ms div 1000).local
  let now = now()
  if t.year == now.year and t.yearday == now.yearday: "today " & t.format("HH:mm") else: t.format("yyyy-MM-dd HH:mm")

proc add(w: kit.Widget, margin = 0) =
  if margin > 0: kit.add(panel.content, kit.sized(kit.column(), 0, margin))
  kit.add(panel.content, w)

proc note(text: string, small = false): kit.Widget =
  ## Dim text; `small` as <small> markup, since the panel's text-size CSS outranks the "small" style.
  result = kit.addClass(if small: kit.richLabel("<small>" & kit.escapeRich(text) & "</small>") else: kit.label(text),
    "dim")

proc render() =
  let job = panelJob
  if job == nil or panel.content == nil: return
  let key = apiKey()
  let busy = job.running or job.answering
  setSidePanelTitle(if job.selection: "Summary of selection" else: "Summary")
  kit.`visible=`(panel.busyLabel, busy)
  kit.`text=`(panel.busyLabel, if job.answering: "Answering…" else: "Summarizing…")
  kit.`enabled=`(panel.copyButton, job.text.len > 0)
  kit.`enabled=`(panel.redoButton, not busy and key.len > 0)
  let canAsk = key.len > 0 and job.text.strip.len > 0 and not job.running and job.error.len == 0
  kit.`enabled=`(panel.entry, canAsk)
  kit.`enabled=`(panel.sendButton, canAsk and not job.answering)

  kit.clear(panel.content)
  if job.title.len > 0: add kit.addClass(kit.label(job.title), "bold")
  if job.url.len > 0:
    let url = note(job.url, small = true)
    kit.`maxChars=`(url, 200)
    add url
  if job.savedAt != 0 and not job.running:
    add note("Saved summary from " & whenText(job.savedAt) & ". Summarize again for a new one.", small = true)
  if job.error.len > 0: add(kit.addClass(kit.label(job.error), "error"), 12)
  elif job.text.len == 0 and job.running:
    add(note(waitingText(job.hasPage, job.chat != nil and job.chat.queued, job.provider)), 12)
  else: add(markdownView(job.text.strip), 12)
  for qa in job.questions:
    add(kit.addClass(kit.addClass(kit.label(qa.question), "bold"), "webby-summary-question"), 16)
    if qa.answer.strip.len > 0: add(markdownView(qa.answer.strip), 8)
    elif qa.running: add(note("Thinking…"), 8)
    if qa.error.len > 0: add(kit.addClass(kit.label(qa.error), "error"), 8)

proc askFromEntry() =
  let job = panelJob
  let key = apiKey()
  let question = kit.text(panel.entry).strip
  if job == nil or key.len == 0 or question.len == 0 or job.running or job.answering: return
  kit.`text=`(panel.entry, "")
  job.ask(key, question, provider())
  render()
  # The answer streams in below: keep it in view until the user scrolls back.
  kit.`followEnd=`(panel.scroller, true)

proc showPanel(job: Job) =
  ## Shows `job` in the side panel (replacing whatever was there).
  switchingPanel = true
  panelJob = nil
  if sidePanelShowing(): closeSidePanel()
  switchingPanel = false
  panel.redoButton = kit.iconButton("refresh", "Summarize again", proc () =
    let job = panelJob
    let key = apiKey()
    if job != nil and key.len > 0 and not job.running and not job.answering:
      kit.`followEnd=`(panel.scroller, false)
      job.start(key, provider(), fresh = true)
      render())
  panel.copyButton = kit.iconButton("copy", "Copy summary", proc () =
    if panelJob != nil and panelJob.text.len > 0:
      copyText(withoutSourceLinks(panelJob.text)))
  panel.busyLabel = note("", small = true)
  let bar = kit.addClass(kit.row(kit.spacer(), panel.busyLabel, panel.copyButton, panel.redoButton),
    "webby-summary-bar")
  bar.spacing = 4
  panel.content = kit.addClass(kit.column(), "webby-summary-content")
  panel.content.spacing = 0
  panel.scroller = kit.scroll(panel.content)
  panel.entry = kit.entry("Ask about this page")
  panel.entry.onSubmit = proc (t: string) = askFromEntry()
  panel.sendButton = kit.iconButton("send", "Ask", askFromEntry)
  let askRow = kit.addClass(kit.row(kit.expand(panel.entry), panel.sendButton), "webby-summary-ask")
  askRow.spacing = 4
  # markdownCss font sizes
  panel.root = kit.addClass(kit.column(bar, kit.separator(), kit.expand(panel.scroller), kit.separator(), askRow),
    "webby-md")
  panel.root.spacing = 0
  showSidePanel("Summary", panel.root, 380, proc () =
    let shown = panelJob
    panelJob = nil
    panel = Panel()
    if not switchingPanel and shown != nil: shown.close())
  when not defined(android): connect(nkgtk.gtkWidget(panel.scroller), "scroll-event", onPanelWheel)
  panelJob = job
  render()

proc hidePanel() =
  ## Takes the summary out of the side panel without stopping it (another tab is showing).
  switchingPanel = true
  closeSidePanel()
  switchingPanel = false

# ---------------------------------------------------------------------------------------------------------------
# Entry points

proc summarizePage*() =
  ## Summarizes the current page, asking for the API key first when there's none. A saved summary of the page is
  ## shown without asking again (the panel's redo button makes a new one).
  let t = currentTab()
  if t == nil or t.url.len == 0: return
  let job = jobOf(t)
  # The saved page summary wins over a selection here; redo reads the page again and summarizes the selection.
  let k = summaryKey(t.url)
  let (found, saved) = lookupSummary(k)
  if found:
    job.stopChat()
    job.hasPage = false
    job.showSaved(k, saved)
    showPanel(job)
    return
  let key = apiKey()
  if key.len == 0:
    showSummarizeSettings(proc () =
      let key = apiKey()
      if key.len > 0 and not t.closed:
        job.start(key, provider())
        showPanel(job))
    return
  job.start(key, provider())
  showPanel(job)

proc toggleSummary() =
  let t = currentTab()
  if t != nil and panelJob != nil and panelJob.tab == t: closeSidePanel()
  else: summarizePage()

proc install*() =
  pageMessageHooks.add onPageMessage
  windowHooks.add proc () =
    let saved = readJsonFile(zoomFile())
    if saved != nil and saved.kind == JObject: textZoom = clamp(saved{"zoom"}.getFloat(1.0), 0.6, 2.5)
    applyTextZoom()
    # Ctrl+plus/minus/0 size the summary text while the panel has focus or the pointer; elsewhere the keys go on as before.
    proc zoomKey(mods: int, key: uint32, factor: float) =
      addKeyHandler(mods, key, proc (): bool =
        if not panelHasFocus(): return false
        setTextZoom(if factor == 0: 1.0 else: textZoom * factor)
        true)
    for (mods, key, z) in [(modCtrl, 0x3d'u32, 1.1), (modCtrl or modShift, 0x2b'u32, 1.1), (modCtrl, 0xffab'u32, 1.1),
        (modCtrl, 0x2d'u32, 1 / 1.1), (modCtrl, 0xffad'u32, 1 / 1.1), (modCtrl, 0x30'u32, 0.0)]:
      zoomKey(mods, key, z)
    loadCss(panelCss)
    linkHandler = proc (url: string) =
      if not url.startsWith(anchorPrefix): discard openTab(url)
      elif panelJob != nil and not panelJob.jumpTo(url[anchorPrefix.len .. ^1]):
        kit.alert("Go back to the summarized page to jump to that part.")
    discard addToolbarButton("summarize_outlined", "Summarize this page", toggleSummary, "summarize", "Summary")
    addMenuSeparator()
    addMenuItem("Summarize this page", summarizePage)
    if not incognito or setSecret == nil: addMenuItem("Summarize settings…", proc () = showSummarizeSettings())
  activeTabHooks.add proc (t: Tab) =
    let job = jobs.getOrDefault(t.messagePrefix)
    let wanted = job != nil and job.open
    if panelJob != nil and panelJob.tab != t:
      if wanted: showPanel(job) else: hidePanel()
    elif panelJob == nil and wanted and not sidePanelShowing():
      showPanel(job)
  tabClosedHooks.add proc (t: Tab) =
    let job = jobs.getOrDefault(t.messagePrefix)
    if job == nil: return
    if panelJob == job: closeSidePanel()
    job.close()
    jobs.del t.messagePrefix
