## @passport (atpassport.net) built in: what its browser extension does, for AT Protocol (Bluesky) handles.
##
## The handles come from the user's @passport session: on atpassport.net the page script reads the session's handle
## list (/api/user/handles, the extension's own source) and hands it over. Handles can also be added here by hand.
## Then
##   - a sign-in field for a handle (name="handle", a "handle" placeholder, Bluesky's username field) gets a bar
##     above the page with the handles: one click fills the field;
##   - sites using @atpassport/client's FedCM handle assist (navigator.credentials.get with @passport's FedCM config,
##     which Ladybird lacks) get webby's own account chooser and the token @passport would give;
##   - the "AT Protocol handles" side panel lists them; clicking one fills the page's field, or copies the handle.
## @passport's redirect sign-in (atpassport.net/authentication?callback=...) is a plain web page and needs nothing.
## Kept in atpassport.json in the profile; incognito windows use the handles but keep nothing.

import std/[strutils, uri]
import ../browser
from nimkit/core as kit import nil
import sync/http

const prefixMark = "\x01PREFIX\x01"
const pageScript = staticRead("../scripts/atpassport.js").replace("${jsonEncode(prefix)}", prefixMark)
const messageTag = "atpassport:"
const siteUrl = "https://atpassport.net/"
const resolveUrl = "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle="

type
  Account = object
    handle, did, displayName: string
    local: bool          ## added in webby rather than read from @passport

  Agent = ref object     ## one tab's state
    offering: bool       ## the bar shows for this tab
    url: string
    dismissedUrl: string ## closed with ✕ on this page

var
  accounts: seq[Account]
  agents: Table[string, Agent]   ## by the tab's message prefix
  bar: kit.Widget
  panelOpen = false
  panelList, panelStatus, addEntry: kit.Widget

proc agent(t: Tab): Agent = agents.mgetOrPut(t.messagePrefix, Agent())

proc js(s: string): string = $(%s)

proc storePath(): string = profileFile("atpassport.json")

proc toJson(a: Account): JsonNode =
  %*{"handle": a.handle, "did": a.did, "displayName": a.displayName, "local": a.local}

proc load() =
  accounts = @[]
  let node = readJsonFile(storePath())
  if node == nil or node.kind != JObject: return
  for a in node{"accounts"}.getElems:
    let handle = a{"handle"}.getStr
    if handle.len > 0:
      accounts.add Account(handle: handle, did: a{"did"}.getStr, displayName: a{"displayName"}.getStr,
        local: a{"local"}.getBool)

proc save() =
  if incognito: return
  var list = newJArray()
  for a in accounts: list.add a.toJson
  try: writeJsonFile(storePath(), %*{"accounts": list}, pretty = true)
  except CatchableError as e: stderr.writeLine "webby: couldn't save ", storePath(), ": ", e.msg

proc cleanHandle(s: string): string =
  result = s.strip.toLowerAscii
  if result.startsWith("@"): result = result[1 .. ^1]
  if result.startsWith("at://"): result = result[5 .. ^1]

proc validHandle(h: string): bool =
  ## The atproto handle syntax: dot-separated labels of letters, digits and hyphens, the last one not all digits.
  if h.len == 0 or h.len > 253: return false
  let labels = h.split('.')
  if labels.len < 2: return false
  for l in labels:
    if l.len == 0 or l.len > 63 or l[0] == '-' or l[^1] == '-': return false
    for c in l:
      if c notin {'a'..'z', '0'..'9', '-'}: return false
  labels[^1][0] notin {'0'..'9'}

proc validDid(d: string): bool =
  if not d.startsWith("did:"): return false
  let parts = d.split(':', 2)
  if parts.len < 3 or parts[1].len == 0 or parts[2].len == 0: return false
  for c in parts[1]:
    if c notin {'a'..'z'}: return false
  for c in parts[2]:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', ':', '%', '-'}: return false
  true

proc refreshPanel()
proc showBar()
proc showSidePanelNow()

proc changed() =
  save()
  refreshPanel()
  showBar()

proc setFromPassport(list: JsonNode) =
  ## The handles @passport has for this browser's session replace the ones it gave before; ones added here stay.
  var next: seq[Account]
  for a in list.getElems:
    let handle = cleanHandle(a{"handle"}.getStr)
    if not validHandle(handle): continue
    var dup = false
    for b in next:
      if b.handle == handle: dup = true
    if not dup:
      next.add Account(handle: handle, did: a{"did"}.getStr, displayName: a{"displayName"}.getStr.strip)
  for a in accounts:
    if a.local:
      var dup = false
      for b in next:
        if b.handle == a.handle: dup = true
      if not dup: next.add a
  if next != accounts:
    accounts = next
    changed()

# ---------------------------------------------------------------------------------------------------------------
# Filling a page's field

proc fill(t: Tab, a: Account) =
  if t == nil or t.closed: return
  t.runJs("setTimeout(() => { window.__webbyAtPassport && window.__webbyAtPassport.fill(" & js(a.handle) & "); }, 0);")
  wake()

proc dismiss(t: Tab) =
  let ag = agent(t)
  ag.offering = false
  ag.dismissedUrl = t.url
  showBar()

proc accountLabel(a: Account): string = "@" & a.handle

proc showBar() =
  if bar == nil: return
  kit.clear(bar)
  let t = currentTab()
  if t == nil or accounts.len == 0 or not agent(t).offering:
    kit.`visible=`(bar, false)
    return
  let text = kit.richLabel("Sign in with your <b>AT Protocol</b> handle")
  kit.`maxChars=`(text, 120)
  kit.add(bar, kit.icon("account_circle", 18))
  kit.add(bar, kit.expand(text))
  proc accountButton(a: Account): kit.Widget =
    # A proc per button: closures made in a loop body would share one `a`.
    result = kit.button(accountLabel(a), proc () = (fill(t, a); dismiss(t)))
    if a.displayName.len > 0: kit.`tooltip=`(result, a.displayName)
  for i, a in accounts:
    if i == 4: break
    kit.add(bar, accountButton(a))
  if accounts.len > 4:
    kit.add(bar, kit.button("More…", showSidePanelNow))
  kit.add(bar, kit.iconButton("close", "Close", proc () = dismiss(t), 14))
  kit.`visible=`(bar, true)

# ---------------------------------------------------------------------------------------------------------------
# FedCM: the account chooser

proc answerFedCm(t: Tab, id: int, token, error: string) =
  if t.closed: return
  t.runJs("setTimeout(() => { window.__webbyAtPassport && window.__webbyAtPassport.answer(" & $id & ", " &
    (if token.len > 0: js(token) else: "null") & ", " & js(error) & "); }, 0);")
  wake()

proc chooser(t: Tab, id: int, rp: string) =
  var usable: seq[Account]
  for a in accounts:
    if validDid(a.did): usable.add a
  if usable.len == 0:
    answerFedCm(t, id, "", "IdentityCredentialError")
    return
  if t != currentTab(): activateTab(t)
  let bold = proc (s: string): string = "<b>" & kit.escapeRich(s) & "</b>"
  let content = kit.column(kit.richLabel("Choose a handle to give " & bold(rp) & ". The site then asks your " &
    "account's server to sign you in."))
  var d: kit.Dialog
  var answered = false
  const accountBase = 100   ## account i answers accountBase + i
  proc accountRow(index: int, a: Account): kit.Widget =
    let text = kit.column(kit.richLabel(bold(if a.displayName.len > 0: a.displayName else: accountLabel(a))))
    text.spacing = 0
    if a.displayName.len > 0: kit.add(text, kit.addClass(kit.label(accountLabel(a)), "small"))
    kit.item(kit.icon("account_circle", 18), kit.expand(text), onClick = proc () =
      kit.dialogResult(d, accountBase + index))
  for i, a in usable: kit.add(content, accountRow(i, a))
  d = kit.dialog("Sign in to " & rp & " with @passport", content, @["Cancel"], proc (r: int) =
    if answered: return
    answered = true
    if r >= accountBase and r - accountBase < usable.len:
      let a = usable[r - accountBase]
      answerFedCm(t, id, $(%*{"v": 1, "did": a.did, "username": a.handle}), "")
    else: answerFedCm(t, id, "", "AbortError"))

# ---------------------------------------------------------------------------------------------------------------
# The side panel

proc addHandle(text: string) =
  let handle = cleanHandle(text)
  if not validHandle(handle):
    kit.`text=`(panelStatus, "That isn't a handle (like alice.bsky.social).")
    return
  for a in accounts:
    if a.handle == handle:
      kit.`text=`(panelStatus, "@" & handle & " is already in the list.")
      return
  kit.`text=`(panelStatus, "Looking up @" & handle & "…")
  # The DID makes the handle usable for FedCM sign-ins, and checks it exists.
  request("GET", resolveUrl & encodeUrl(handle, usePlus = false), [("Accept", "application/json")], "",
    proc (r: Response) =
      var did = ""
      if r.status == 200:
        try: did = parseJson(r.body){"did"}.getStr except CatchableError: discard
      if not validDid(did):
        if panelStatus != nil:
          kit.`text=`(panelStatus, if r.status == 0: "Couldn't look up @" & handle & ": " & r.error
            else: "No account has the handle @" & handle & ".")
        return
      for a in accounts:
        if a.handle == handle: return
      accounts.add Account(handle: handle, did: did, local: true)
      if addEntry != nil: kit.`text=`(addEntry, "")
      if panelStatus != nil: kit.`text=`(panelStatus, "")
      changed())

proc remove(handle: string) =
  for i, a in accounts:
    if a.handle == handle:
      accounts.delete(i)
      break
  changed()

proc handleRow(a: Account): kit.Widget =
  let text = kit.column(kit.addClass(kit.label(accountLabel(a)), "bold"))
  text.spacing = 0
  var sub: seq[string]
  if a.displayName.len > 0: sub.add a.displayName
  sub.add(if a.local: "added in Webby" else: "from @passport")
  kit.add(text, kit.addClass(kit.label(sub.join(" · ")), "small"))
  let copy = kit.iconButton("copy", "Copy handle", proc () =
    copyText(a.handle)
    kit.toast("Handle copied"), 14)
  let trailing = if a.local:
      kit.iconButton("delete_outline", "Remove", proc () = remove(a.handle), 14)
    else:
      kit.iconButton("open_in_new", "Manage on atpassport.net", proc () = discard openTab(siteUrl), 14)
  result = kit.item(kit.icon("account_circle", 18), kit.expand(text), copy, trailing, onClick = proc () =
    let t = currentTab()
    if t != nil: fill(t, a))
  kit.`tooltip=`(result, "Fill @" & a.handle & " into the page")

proc refreshPanel() =
  if not panelOpen or panelList == nil: return
  kit.clear(panelList)
  if accounts.len == 0:
    kit.add(panelList, kit.addClass(kit.addClass(kit.label("No handles yet. Register yours on atpassport.net " &
      "and open it here once: Webby picks up the handles of your @passport session. Or add one below."), "dim"),
      "webby-atp-note"))
    return
  for a in accounts: kit.add(panelList, handleRow(a))

proc showPanel() =
  let root = kit.addClass(kit.column(), "webby-atp")
  root.spacing = 6
  kit.add(root, kit.addClass(kit.label("Webby offers these on sign-in pages that ask for an AT Protocol (Bluesky) " &
    "handle. Click one to fill the page's field."), "small"))
  panelList = kit.column()
  kit.add(root, kit.expand(kit.scroll(panelList)))
  addEntry = kit.entry("Add a handle, like alice.bsky.social")
  addEntry.onSubmit = proc (s: string) = addHandle(s)
  let addRow = kit.row(kit.expand(addEntry), kit.button("Add", proc () = addHandle(kit.text(addEntry))))
  addRow.spacing = 6
  kit.add(root, addRow)
  kit.add(root, kit.button("Sync from atpassport.net", proc () = discard openTab(siteUrl)))
  panelStatus = kit.addClass(kit.label(""), "small")
  kit.add(root, panelStatus)
  showSidePanel("AT Protocol handles", root, 380, proc () =
    panelOpen = false
    panelList = nil
    panelStatus = nil
    addEntry = nil)
  panelOpen = true
  refreshPanel()

proc togglePanel() =
  if panelOpen: closeSidePanel() else: showPanel()

proc showSidePanelNow() = (if not panelOpen: showPanel())

# ---------------------------------------------------------------------------------------------------------------
# Page messages

proc isPassportSite(url: string): bool =
  try:
    let u = parseUri(url)
    u.scheme == "https" and u.hostname in ["atpassport.net", "preview.atpassport.net"]
  except CatchableError: false

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith(messageTag): return false
  result = true
  var m: JsonNode
  try: m = parseJson(text[messageTag.len .. ^1])
  except CatchableError: return
  let ag = agent(t)
  case m{"type"}.getStr
  of "offer":
    # Remembered with no handles too: the bar shows once some arrive (added in the panel, say).
    if ag.offering or ag.dismissedUrl == t.url: return
    ag.offering = true
    if t == currentTab(): showBar()
  of "gone":
    if ag.offering:
      ag.offering = false
      if t == currentTab(): showBar()
  of "filled":
    if not m{"ok"}.getBool:
      let handle = m{"handle"}.getStr
      copyText(handle)
      kit.toast("No handle field on the page: @" & handle & " copied")
  of "fedcm":
    chooser(t, m{"id"}.getInt, m{"rp"}.getStr)
  of "accounts":
    # Only from @passport's own site, the one place that knows the session's handles.
    if isPassportSite(t.url) and m{"accounts"} != nil: setFromPassport(m{"accounts"})
  else: discard

proc onTabState(t: Tab) =
  let ag = agent(t)
  if t.url == ag.url: return
  ag.url = t.url
  ag.dismissedUrl = ""
  if ag.offering:
    ag.offering = false
    if t == currentTab(): showBar()

proc pageScriptFor(t: Tab): string =
  if not (t.url.startsWith("http://") or t.url.startsWith("https://")): return ""
  pageScript.replace(prefixMark, js(t.messagePrefix & messageTag))

proc install*() =
  load()
  windowHooks.add proc () =
    loadCss(""".webby-atp-bar { padding: 4px 12px; border-left: 3px solid @theme_selected_bg_color;
      border-bottom: 1px solid alpha(currentColor, 0.15); }
.webby-atp { padding: 8px; }
.webby-atp-note { margin: 24px 16px 0 16px; }""")
    bar = kit.row()
    kit.addClass(bar, "webby-atp-bar")
    kit.`visible=`(bar, false)
    kit.add(barSlot, bar)
    addMenuItem("AT Protocol handles", togglePanel)
  tabClosedHooks.add proc (t: Tab) = agents.del t.messagePrefix
  activeTabHooks.add proc (t: Tab) = showBar()
  tabStateHooks.add onTabState
  pageScriptHooks.add pageScriptFor
  pageMessageHooks.add onMessage
