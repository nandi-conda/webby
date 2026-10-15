## Passwords and passkeys for webby-nim, a port of app/lib/src/passwords (except sync/) and passkey_dialog.dart.
##
##   passwords/vault.nim     the encrypted vault, byte-compatible with vault.dart (same file, key, cipher, JSON)
##   passwords/keyring.nim   the vault key in the desktop keyring through libsecret (falls back to vault.key)
##   passwords/crypto.nim    AES-256-GCM and random bytes from libcrypto
##   passwords/manager.nim   the open vault (theVault, vaultError) and the authenticator's passkeys kept in it
##   passwords/panel.nim     the "Passwords and passkeys" side panel
##   passwords/generator.nim strong passwords
## This module: the page script (read from page_script.dart at compile time), save / fill / generate offers in a bar
## above the page, the passkey dialog (webauthnHandler) and the vault's secrets (getSecret/setSecret/secretSyncs).
##
## For sync (a separate feature on top of this one), import features/passwords/[vault, manager, panel]:
##   theVault (nil if it couldn't open; read-only in incognito), theVault.onChange.add(proc), theVault.toSyncDoc()
##   and theVault.applySyncDoc(merged) (records keyed by id / credentialId / origin, tombstones {"updatedAt",
##   "deleted": true}), theVault.syncSettings / setSyncSettings (the raw "sync" JSON that SyncSettings reads),
##   passkeysSynced(removedIds) after applySyncDoc returns true, panelActionHooks to put a Sync button in the panel.
##   Every change is saved at once; secrets never enter toSyncDoc.

import std/strutils
import ../browser
from nimkit/core as kit import nil
import passwords/[vault, manager, generator, panel]

# page_script.dart's passwordPageScript(prefix), unescaped from its Dart string at compile time.
const prefixMark = "\x01PREFIX\x01"
const pageScript = staticRead("../scripts/passwords.js").replace("${jsonEncode(prefix)}", prefixMark)

const messageTag = "passwords:"   ## after the tab's prefix, so other features' messages aren't ours

type
  OfferKind = enum noOffer, saveOffer, fillOffer, generateOffer
  Offer = object
    kind: OfferKind
    origin, username, password: string
    existing: SavedPassword
    accounts: seq[SavedPassword]

  Agent = ref object      ## one tab's password state (PasswordAgent)
    tab: Tab
    offer: Offer
    url: string
    filledOrigin: string
    generated: string     ## the generated password put in the page, saved without asking once it's sent

var
  agents: seq[Agent]
  bar: kit.Widget

proc agentFor(t: Tab): Agent =
  for a in agents:
    if a.tab == t: return a

proc js(s: string): string = $(%s)

proc deferred(source: string): string =
  ## Runs after the current task: Ladybird can run our JavaScript inside the page script's own prompt() call (the one
  ## that sent the message we're answering), before that script has defined window.__webbyPasswords.
  "setTimeout(() => { " & source & " }, 0);"

# ---------------------------------------------------------------------------------------------------------------
# The bar above the page

proc showBar()

proc setOffer(a: Agent, offer: Offer) =
  a.offer = offer
  if a.tab == currentTab(): showBar()

proc dismiss(a: Agent) = a.setOffer(Offer())

proc fill(a: Agent, account: SavedPassword) =
  let origin = originOf(a.tab.url)
  if origin.len == 0 or origin != account.origin: return
  a.filledOrigin = origin
  a.tab.runJs(deferred("window.__webbyPasswords && window.__webbyPasswords.fill(" & js(account.username) & ", " &
    js(account.password) & ", " & js(origin) & ");"))
  wake()
  if a.offer.kind == fillOffer: a.dismiss()

proc useGenerated(a: Agent) =
  let o = a.offer
  if originOf(a.tab.url) != o.origin: return
  a.generated = o.password
  a.tab.runJs(deferred("window.__webbyPasswords && window.__webbyPasswords.fillNew(" & js(o.password) & ", " &
    js(o.origin) & ");"))
  wake()
  a.dismiss()

proc showBar() =
  kit.clear(bar)
  let t = currentTab()
  let a = if t == nil: nil else: agentFor(t)
  if a == nil or a.offer.kind == noOffer:
    kit.`visible=`(bar, false)
    return
  let o = a.offer
  let host = "<b>" & kit.escapeRich(hostOf(o.origin)) & "</b>"
  proc button(text: string, action: proc (), class = ""): kit.Widget =
    result = kit.button(text, action)
    if class.len > 0: kit.addClass(result, class)
  var message: string
  var actions: seq[kit.Widget]
  case o.kind
  of saveOffer:
    let who = "<b>" & kit.escapeRich(if o.username.len == 0: "this account" else: o.username) & "</b>"
    message = (if o.existing != nil: "Update the saved password for " else: "Save the password for ") & who & " on " &
      host & "?"
    if o.existing == nil:
      actions.add button("Never for this site", proc () =
        if theVault != nil: theVault.setNeverSave(o.origin, true)
        a.dismiss(), "flat")
    actions.add button("Not now", proc () = a.dismiss())
    actions.add button(if o.existing != nil: "Update" else: "Save", proc () =
      if theVault != nil: theVault.savePassword(o.origin, o.username, o.password)
      a.dismiss(), "suggested")
  of generateOffer:
    message = "Use a strong password  <b><tt>" & kit.escapeRich(o.password) & "</tt></b>"
    actions.add kit.iconButton("refresh", "Another one", proc () =
      a.setOffer(Offer(kind: generateOffer, origin: o.origin, password: generatePassword())), 14)
    actions.add button("No thanks", proc () = a.dismiss())
    actions.add button("Use password", proc () = a.useGenerated(), "suggested")
  of fillOffer:
    message = "Fill a saved password for " & host
    proc accountButton(account: SavedPassword): kit.Widget =
      # A proc per button: closures made in a loop body would share one `account`.
      result = button(if account.username.len == 0: "(no username)" else: account.username, proc () = a.fill(account))
      kit.`iconName=`(result, "account_circle")
    for i, account in o.accounts:
      if i == 4: break
      actions.add accountButton(account)
    actions.add kit.iconButton("close", "Close", proc () = a.dismiss(), 14)
  of noOffer: discard
  let text = kit.richLabel(message)
  kit.`maxChars=`(text, 200)
  kit.add(bar, kit.icon("key", 18))
  kit.add(bar, kit.expand(text))
  for w in actions: kit.add(bar, w)
  kit.`visible=`(bar, true)

# ---------------------------------------------------------------------------------------------------------------
# Page messages (see page_script.dart)

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith(messageTag): return false
  result = true
  let a = agentFor(t)
  let v = theVault
  let origin = originOf(t.url)
  if a == nil or v == nil or origin.len == 0: return
  var message: JsonNode
  try: message = parseJson(text[messageTag.len .. ^1])
  except CatchableError: return
  let kind = message{"type"}.getStr
  # Nothing is saved from an incognito window, so there's nothing to offer.
  if incognito and kind in ["newPassword", "submit"]: return
  case kind
  of "newPassword":
    # Not again for the confirm field once a password is in, or while one is on offer.
    if a.generated.len > 0 or a.offer.kind == saveOffer or
        (a.offer.kind == generateOffer and a.offer.origin == origin): return
    a.setOffer(Offer(kind: generateOffer, origin: origin, password: generatePassword()))
  of "fields", "focus":
    let accounts = v.passwordsFor(origin)
    if accounts.len == 0 or a.offer.kind == saveOffer: return
    if accounts.len == 1 and kind == "fields" and a.filledOrigin != origin:
      a.fill(accounts[0])   # one account: fill it straight away, the way other browsers do
    elif a.filledOrigin != origin or accounts.len > 1:
      a.setOffer(Offer(kind: fillOffer, origin: origin, accounts: accounts))
  of "submit":
    let username = message{"username"}.getStr
    let password = message{"password"}.getStr
    if password.len == 0: return
    if password == a.generated:
      a.generated = ""
      v.savePassword(origin, username, password)
      if a.offer.kind == generateOffer: a.dismiss()
      return
    if v.isNeverSave(origin): return
    let existing = v.find(origin, username)
    if existing != nil and existing.password == password: return
    a.setOffer(Offer(kind: saveOffer, origin: origin, username: username, password: password, existing: existing))
  else: discard

proc onTabState(t: Tab) =
  let a = agentFor(t)
  if a == nil or t.url == a.url: return
  a.url = t.url
  a.filledOrigin = ""
  a.generated = ""
  if a.offer.kind == fillOffer and a.offer.origin != originOf(t.url): a.dismiss()

proc pageScriptFor(t: Tab): string =
  if originOf(t.url).len == 0: return ""
  pageScript.replace(prefixMark, js(t.messagePrefix & messageTag))

# ---------------------------------------------------------------------------------------------------------------
# Passkeys (passkey_dialog.dart)

var pendingPasskey: seq[(Tab, JsonNode)]   ## the first one is showing

proc passkeyDialog(t: Tab, prompt: JsonNode, onDone: proc ()) =
  let rpId = prompt{"rpId"}.getStr
  let bold = proc (s: string): string = "<b>" & kit.escapeRich(s) & "</b>"
  var title, body: string
  var buttons: seq[string]
  var accounts: seq[JsonNode]
  if prompt{"type"}.getStr == "create":
    let userName = prompt{"userName"}.getStr
    let display = prompt{"userDisplayName"}.getStr
    let account = if display.len > 0 and display != userName: display & " (" & userName & ")" else: userName
    if prompt{"alreadyRegistered"}.getBool:
      title = "Passkey already saved"
      body = "This browser already has a passkey for your account on " & kit.escapeRich(rpId) & "."
      buttons = @["Cancel", "OK"]
    else:
      title = "Create a passkey?"
      body = "Save a passkey for " & bold(if account.len == 0: "your account" else: account) & " on " & bold(rpId) &
        ". It stays in this browser and signs you in without a password."
      buttons = @["Cancel", "Create"]
  else:
    accounts = prompt{"accounts"}.getElems
    if accounts.len == 0:
      title = "No passkeys"
      body = "This browser has no passkeys for " & kit.escapeRich(rpId) & "."
      buttons = @["OK"]
    else:
      title = "Sign in to " & rpId
      body = "Choose a passkey:"
      buttons = @["Cancel"]
  let content = kit.column(kit.richLabel(body))
  var d: kit.Dialog
  const accountBase = 100   ## account i answers accountBase + i
  proc accountButton(index: int, account: JsonNode): kit.Widget =
    let name = account{"userName"}.getStr
    let display = account{"userDisplayName"}.getStr
    let text = kit.column(kit.richLabel(bold(if display.len > 0: display else: name)))
    text.spacing = 0
    if display.len > 0: kit.add(text, kit.addClass(kit.label(name), "small"))
    result = kit.item(kit.icon("account_circle", 18), kit.expand(text), onClick = proc () =
      kit.dialogResult(d, accountBase + index))
  for i, account in accounts: kit.add(content, accountButton(i, account))
  d = kit.dialog(title, content, buttons, proc (r: int) =
    if not t.closed:
      if accounts.len > 0:
        let chosen = if r >= accountBase: r - accountBase else: -1
        webby_view_webauthn_respond(t.view, (chosen >= 0).cint, chosen.cint)
      else: webby_view_webauthn_respond(t.view, (r == 1).cint, -1)
      wake()
    onDone())

proc runPasskeyDialogs()

proc nextPasskeyDialog() =
  pendingPasskey.delete(0)
  runPasskeyDialogs()

proc runPasskeyDialogs() =
  ## Shows the first waiting request; each answered one shows the next.
  while pendingPasskey.len > 0:
    let (t, prompt) = pendingPasskey[0]
    if t.closed:
      pendingPasskey.delete(0)
      continue
    # A site in a background tab asking for a passkey brings its tab forward.
    if t != currentTab(): activateTab(t)
    passkeyDialog(t, prompt, nextPasskeyDialog)
    return

proc onWebauthn(t: Tab, request: JsonNode) =
  pendingPasskey.add (t, request)
  if pendingPasskey.len == 1:
    discard after(0, runPasskeyDialogs)

# ---------------------------------------------------------------------------------------------------------------

proc install*() =
  browser.getSecret = proc (name: string): string = (if theVault == nil: "" else: vault.secret(theVault, name))
  browser.setSecret = proc (name, value: string, sync: bool) =
    if theVault != nil: vault.setSecret(theVault, name, value, sync)
    else: stderr.writeLine "webby: no password vault to keep ", name, " in"
  browser.secretSyncs = proc (name: string): bool = theVault == nil or vault.secretSyncs(theVault, name)
  webauthnHandler = onWebauthn
  windowHooks.add proc () =
    startManager()
    if theVault != nil: theVault.onChange.add refreshPanel
    loadCss(""".webby-password-bar { padding: 4px 12px; border-left: 3px solid @theme_selected_bg_color;
      border-bottom: 1px solid alpha(currentColor, 0.15); }
.webby-vault { padding: 8px; }
.webby-vault-row { margin: 4px 4px 4px 8px; }
.webby-vault-row button { padding: 2px; min-height: 0; }
.webby-vault-note { margin: 24px 16px 0 16px; }
.webby-vault-heading { margin-left: 8px; }""")
    bar = kit.row()
    kit.addClass(bar, "webby-password-bar")
    kit.`visible=`(bar, false)
    kit.add(barSlot, bar)
    # The vault belongs to the normal windows; incognito ones only fill from it.
    if not incognito:
      discard addToolbarButton("key_outlined", "Passwords and passkeys", toggleVaultPanel, "key", "Passwords and passkeys")
      addMenuItem("Passwords and passkeys", showVaultPanel)
  tabCreatedHooks.add proc (t: Tab) = agents.add Agent(tab: t)
  tabClosedHooks.add proc (t: Tab) =
    for i, a in agents:
      if a.tab == t:
        agents.delete(i)
        break
  activeTabHooks.add proc (t: Tab) = showBar()
  tabStateHooks.add onTabState
  pageScriptHooks.add pageScriptFor
  pageMessageHooks.add onMessage
  shutdownHooks.add syncPasskeys
