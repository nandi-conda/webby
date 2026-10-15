## Summarize (app/lib/src/summarize.dart): reads the page's text through a page script, streams a summary from
## DeepSeek, Xiaomi MiMo or Meta into the side panel, answers follow-up questions about the page, and saves both (summarize/cache.nim).
## Each provider's API key is a secret in the password vault, synced to the other devices unless unticked, and so
## is the choice of provider; without the vault (getSecret is nil) they are kept in memory until Webby quits.

import std/[json, random, strutils, times]
import ../browser
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
    root, spinner, copyButton, redoButton, content, entry, sendButton, adjustment: Widget
    stickToBottom: bool

var
  jobs: Table[string, Job]     ## by the tab's messagePrefix
  memorySecrets: Table[string, string]   ## the keys and choice when there's no vault to keep them in
  pendingReads: Table[string, proc (ok: bool, page: PageText)]
  panelJob: Job                ## the job the side panel shows, nil when it shows something else
  panel: Panel
  switchingPanel = false
  renderQueued = false

const GTK_RESPONSE_REJECT = -2.cint
proc gtk_check_button_new_with_mnemonic(label: cstring): Widget {.importc, cdecl.}
proc gtk_combo_box_text_new(): Widget {.importc, cdecl.}
proc gtk_combo_box_text_append_text(c: Widget, text: cstring) {.importc, cdecl.}
proc gtk_combo_box_set_active(c: Widget, i: cint) {.importc, cdecl.}
proc gtk_combo_box_get_active(c: Widget): cint {.importc, cdecl.}
proc gtk_dialog_get_widget_for_response(d: Widget, response: cint): Widget {.importc, cdecl.}
proc gtk_box_set_spacing(b: Widget, s: cint) {.importc, cdecl.}
proc gtk_scrolled_window_get_vadjustment(s: Widget): Widget {.importc, cdecl.}
proc gtk_adjustment_get_value(a: Widget): cdouble {.importc, cdecl.}
proc gtk_adjustment_set_value(a: Widget, v: cdouble) {.importc, cdecl.}
proc gtk_adjustment_get_upper(a: Widget): cdouble {.importc, cdecl.}
proc gtk_adjustment_get_page_size(a: Widget): cdouble {.importc, cdecl.}

proc nowMs(): int64 = (epochTime() * 1000).int64

proc later(ms: int, action: proc ()) =
  let cb = new(proc ())
  cb[] = action
  GC_ref(cb)
  discard g_timeout_add(ms.cuint, proc (d: pointer): gboolean {.cdecl.} =
    let cb = cast[ref proc ()](d)
    GC_unref(cb)
    cb[]()
    0, cast[pointer](cb))

# ---------------------------------------------------------------------------------------------------------------
# The API key

proc secret(name: string): string =
  if getSecret != nil: getSecret(name) else: memorySecrets.getOrDefault(name)

proc storeSecret(name, value: string, sync: bool) =
  if setSecret != nil: setSecret(name, value, sync)
  else: memorySecrets[name] = value

proc provider(): Provider = chosenProvider(secret)
proc apiKey(): string = secret(provider().info.keySecret)


proc onShowKey(button: Widget, entry: pointer) {.cdecl.} =
  gtk_entry_set_visibility(entry, gtk_toggle_button_get_active(button))

proc render()

type SettingsDialog = object
  dialog, providerBox, label, sync, info: Widget
  provider: Provider

proc settingsUpdate(d: ptr SettingsDialog) =
  ## Fits the dialog to the provider picked.
  let p = Provider(max(0, gtk_combo_box_get_active(d.providerBox)))
  let hasKey = secret(p.info.keySecret).len > 0
  gtk_label_set_text(d.label, cstring(if hasKey: "New " & p.name & " API key (one is saved)" else: p.name & " API key"))
  gtk_widget_set_sensitive(gtk_dialog_get_widget_for_response(d.dialog, GTK_RESPONSE_REJECT), hasKey.gboolean)
  if p != d.provider:
    gtk_toggle_button_set_active(d.sync, cint(secretSyncs == nil or secretSyncs(p.info.keySecret)))
  d.provider = p
  let where =
    if setSecret != nil: "It is kept encrypted in the password vault; when it syncs, it travels end-to-end " &
      "encrypted like your passwords."
    else: "The password vault isn't available, so the key is kept in memory until Webby quits."
  gtk_label_set_markup(d.info, cstring("<small>" & escapeMarkup("Create a key at " & p.info.site & ". " & where &
    " Summarize sends the page's text to " & p.name & ".") & "</small>"))

proc onProviderChanged(box: Widget, d: pointer) {.cdecl.} = settingsUpdate(cast[ptr SettingsDialog](d))

proc showSummarizeSettings*() =
  ## The dialog where the provider is picked and its API key entered, replaced or removed.
  if incognito and setSecret != nil:
    alert("Set the Summarize API key in a normal window.")
    return
  var s = SettingsDialog(provider: provider())
  let d = gtk_dialog_new_with_buttons("Summarize settings", window, GTK_DIALOG_MODAL, nil)
  s.dialog = d
  discard gtk_dialog_add_button(d, "_Remove key", GTK_RESPONSE_REJECT)
  discard gtk_dialog_add_button(d, "_Cancel", GTK_RESPONSE_CANCEL)
  discard gtk_dialog_add_button(d, "_Save", GTK_RESPONSE_OK)
  gtk_dialog_set_default_response(d, GTK_RESPONSE_OK)
  let box = gtk_dialog_get_content_area(d)
  gtk_container_set_border_width(box, 12)
  gtk_box_set_spacing(box, 6)
  let withLabel = gtk_label_new("Summarize with")
  gtk_label_set_xalign(withLabel, 0)
  gtk_box_pack_start(box, withLabel, 0, 0, 0)
  s.providerBox = gtk_combo_box_text_new()
  for p in Provider: gtk_combo_box_text_append_text(s.providerBox, p.name.cstring)
  gtk_combo_box_set_active(s.providerBox, s.provider.ord.cint)
  gtk_box_pack_start(box, s.providerBox, 0, 0, 0)
  s.label = gtk_label_new("")
  gtk_label_set_xalign(s.label, 0)
  gtk_widget_set_margin_top(s.label, 6)
  gtk_box_pack_start(box, s.label, 0, 0, 0)
  let entry = gtk_entry_new()
  gtk_entry_set_visibility(entry, 0)
  gtk_entry_set_placeholder_text(entry, "Paste the key")
  gtk_entry_set_activates_default(entry, 1)
  gtk_entry_set_width_chars(entry, 44)
  gtk_box_pack_start(box, entry, 0, 0, 0)
  let show = gtk_check_button_new_with_mnemonic("Sho_w key")
  connect(show, "toggled", onShowKey, entry)
  gtk_box_pack_start(box, show, 0, 0, 0)
  s.sync = gtk_check_button_new_with_mnemonic("S_ync this key to my other devices")
  gtk_toggle_button_set_active(s.sync, cint(secretSyncs == nil or secretSyncs(s.provider.info.keySecret)))
  if setSecret != nil: gtk_box_pack_start(box, s.sync, 0, 0, 0)
  s.info = markupLabel("", selectable = false)
  addClass(s.info, "webby-md-dim")
  gtk_box_pack_start(box, s.info, 0, 0, 0)
  settingsUpdate(addr s)
  connect(s.providerBox, "changed", onProviderChanged, addr s)
  gtk_widget_show_all(d)
  while true:
    let r = gtk_dialog_run(d)
    let text = ($gtk_entry_get_text(entry)).strip
    let syncs = gtk_toggle_button_get_active(s.sync) != 0
    let p = s.provider
    let name = p.info.keySecret
    let hasKey = secret(name).len > 0
    if r == GTK_RESPONSE_OK and text.len == 0:
      # With a key saved, Save with the field empty just switches to the provider and changes whether it syncs.
      if not hasKey: continue
      storeSecret(name, secret(name), syncs)
    elif r == GTK_RESPONSE_OK: storeSecret(name, text, syncs)
    elif r == GTK_RESPONSE_REJECT: storeSecret(name, "", syncs)
    if r in [GTK_RESPONSE_OK, GTK_RESPONSE_REJECT]:
      # The choice travels with the key: a device that gets the key also switches to it.
      if secret(providerSecret) != p.info.id or (secretSyncs != nil and secretSyncs(providerSecret) != syncs):
        storeSecret(providerSecret, p.info.id, syncs)
    break
  gtk_widget_destroy(d)
  render()

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
"""

# Text sizes: markdown_view.dart's (body, then headings 1.35/1.2/1.08x and code 0.92x), in pt so they follow the
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

proc gtk_window_get_focus(w: Widget): Widget {.importc, cdecl.}
proc gtk_widget_is_ancestor(w, ancestor: Widget): gboolean {.importc, cdecl.}

proc gtk_widget_get_pointer(w: Widget, x, y: ptr cint) {.importc, cdecl.}

proc panelHasFocus(): bool =
  ## Whether the keyboard focus or the mouse pointer is in the summary panel.
  if panel.root == nil or not sidePanelShowing(): return false
  let f = gtk_window_get_focus(window)
  if f != nil and (f == panel.root or gtk_widget_is_ancestor(f, panel.root) != 0): return true
  var x, y: cint
  gtk_widget_get_pointer(panel.root, addr x, addr y)
  x >= 0 and y >= 0 and x < gtk_widget_get_allocated_width(panel.root) and
    y < gtk_widget_get_allocated_height(panel.root)

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

proc dim(text: string): string = "<small>" & escapeMarkup(text) & "</small>"
proc danger(text: string): string = "<span foreground=\"#d0393e\">" & escapeMarkup(text) & "</span>"

proc whenText(ms: int64): string =
  let t = fromUnix(ms div 1000).local
  let now = now()
  if t.year == now.year and t.yearday == now.yearday: "today " & t.format("HH:mm") else: t.format("yyyy-MM-dd HH:mm")

proc add(w: Widget, margin = 0) =
  gtk_widget_set_margin_top(w, margin.cint)
  gtk_box_pack_start(panel.content, w, 0, 0, 0)

proc render() =
  let job = panelJob
  if job == nil or panel.content == nil: return
  let key = apiKey()
  let busy = job.running or job.answering
  gtk_label_set_text(sidePanelTitle, cstring(if job.selection: "Summary of selection" else: "Summary"))
  gtk_widget_set_visible(panel.spinner, busy.gboolean)
  if busy: gtk_spinner_start(panel.spinner) else: gtk_spinner_stop(panel.spinner)
  gtk_widget_set_sensitive(panel.copyButton, (job.text.len > 0).gboolean)
  gtk_widget_set_sensitive(panel.redoButton, (not busy and key.len > 0).gboolean)
  let canAsk = key.len > 0 and job.text.strip.len > 0 and not job.running and job.error.len == 0
  gtk_widget_set_sensitive(panel.entry, canAsk.gboolean)
  gtk_widget_set_sensitive(panel.sendButton, (canAsk and not job.answering).gboolean)

  clearChildren(panel.content)
  if job.title.len > 0: add markupLabel("<b>" & escapeMarkup(job.title) & "</b>")
  if job.url.len > 0:
    let url = markupLabel(dim(job.url))
    gtk_label_set_line_wrap(url, 0)
    gtk_label_set_ellipsize(url, PANGO_ELLIPSIZE_END)
    addClass(url, "webby-md-dim")
    add url
  if job.savedAt != 0 and not job.running:
    let note = markupLabel(dim("Saved summary from " & whenText(job.savedAt) & ". Summarize again for a new one."))
    addClass(note, "webby-md-dim")
    add note
  if job.error.len > 0: add(markupLabel(danger(job.error)), 12)
  elif job.text.len == 0 and job.running:
    let reading = markupLabel(escapeMarkup(waitingText(job.hasPage, job.chat != nil and job.chat.queued, job.provider)))
    addClass(reading, "webby-md-dim")
    add(reading, 12)
  else: add(markdownView(job.text.strip), 12)
  for qa in job.questions:
    let q = markupLabel("<b>" & escapeMarkup(qa.question) & "</b>")
    addClass(q, "webby-summary-question")
    add(q, 16)
    if qa.answer.strip.len > 0: add(markdownView(qa.answer.strip), 8)
    elif qa.running:
      let thinking = markupLabel(escapeMarkup("Thinking…"))
      addClass(thinking, "webby-md-dim")
      add(thinking, 8)
    if qa.error.len > 0: add(markupLabel(danger(qa.error)), 8)
  gtk_widget_show_all(panel.content)
  if not busy: gtk_widget_hide(panel.spinner)

proc onAdjustmentChanged(a: Widget, data: pointer) {.cdecl.} =
  if panel.stickToBottom:
    gtk_adjustment_set_value(a, gtk_adjustment_get_upper(a) - gtk_adjustment_get_page_size(a))

proc onScrolled(a: Widget, data: pointer) {.cdecl.} =
  if gtk_adjustment_get_value(a) < gtk_adjustment_get_upper(a) - gtk_adjustment_get_page_size(a) - 24:
    panel.stickToBottom = false

proc askFromEntry() =
  let job = panelJob
  let key = apiKey()
  let question = ($gtk_entry_get_text(panel.entry)).strip
  if job == nil or key.len == 0 or question.len == 0 or job.running or job.answering: return
  gtk_entry_set_text(panel.entry, "")
  panel.stickToBottom = true
  job.ask(key, question, provider())
  render()
  onAdjustmentChanged(panel.adjustment, nil)

proc onEntryActivate(e: Widget, data: pointer) {.cdecl.} = askFromEntry()

proc showPanel(job: Job) =
  ## Shows `job` in the side panel (replacing whatever was there).
  switchingPanel = true
  panelJob = nil
  if sidePanelShowing(): closeSidePanel()
  switchingPanel = false
  let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  addClass(root, "webby-md")   # markdownCss font sizes, matching the Flutter panel
  let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
  gtk_widget_set_margin_end(bar, 4)
  panel.redoButton = iconButton("refresh", "Summarize again", proc () =
    let job = panelJob
    let key = apiKey()
    if job != nil and key.len > 0 and not job.running and not job.answering:
      panel.stickToBottom = false
      job.start(key, provider(), fresh = true)
      render())
  panel.copyButton = iconButton("copy", "Copy summary", proc () =
    if panelJob != nil and panelJob.text.len > 0:
      gtk_clipboard_set_text(systemClipboard(), withoutSourceLinks(panelJob.text).cstring, -1))
  panel.spinner = gtk_spinner_new()
  gtk_box_pack_end(bar, panel.redoButton, 0, 0, 0)
  gtk_box_pack_end(bar, panel.copyButton, 0, 0, 0)
  gtk_box_pack_end(bar, panel.spinner, 0, 0, 6)
  gtk_box_pack_start(root, bar, 0, 0, 0)
  gtk_box_pack_start(root, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, 0, 0)

  let scroller = gtk_scrolled_window_new(nil, nil)
  gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
  panel.content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  for side in [gtk_widget_set_margin_start, gtk_widget_set_margin_end, gtk_widget_set_margin_top,
      gtk_widget_set_margin_bottom]:
    side(panel.content, 14)
  gtk_container_add(scroller, panel.content)
  connect(scroller, "scroll-event", onPanelWheel)
  gtk_box_pack_start(root, scroller, 1, 1, 0)
  panel.adjustment = gtk_scrolled_window_get_vadjustment(scroller)
  panel.stickToBottom = false
  connect(panel.adjustment, "changed", onAdjustmentChanged)
  connect(panel.adjustment, "value-changed", onScrolled)

  gtk_box_pack_start(root, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, 0, 0)
  let askRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
  for side in [gtk_widget_set_margin_start, gtk_widget_set_margin_end, gtk_widget_set_margin_top,
      gtk_widget_set_margin_bottom]:
    side(askRow, 8)
  panel.entry = gtk_entry_new()
  gtk_entry_set_placeholder_text(panel.entry, "Ask about this page")
  connect(panel.entry, "activate", onEntryActivate)
  panel.sendButton = iconButton("send", "Ask", askFromEntry)
  gtk_box_pack_start(askRow, panel.entry, 1, 1, 0)
  gtk_box_pack_start(askRow, panel.sendButton, 0, 0, 0)
  gtk_box_pack_start(root, askRow, 0, 0, 0)
  panel.root = root

  showSidePanel("Summary", root, 380, proc () =
    let shown = panelJob
    panelJob = nil
    panel = Panel()
    if not switchingPanel and shown != nil: shown.close())
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
  var key = apiKey()
  if key.len == 0:
    showSummarizeSettings()
    key = apiKey()
    if key.len == 0: return
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
        alert("Go back to the summarized page to jump to that part.")
    discard addToolbarButton("summarize_outlined", "Summarize this page", toggleSummary, "summarize", "Summary")
    if children(moreMenu).len > 0: addMenuSeparator()
    addMenuItem("Summarize this page", summarizePage)
    if not incognito or setSecret == nil: addMenuItem("Summarize settings…", showSummarizeSettings)
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
