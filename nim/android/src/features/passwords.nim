## Passwords and passkeys on Android (src/features/passwords.nim on the desktop): the same encrypted vault
## (features/passwords/vault.nim; its key in the Android Keystore through MainActivity.keystore*), the same page
## script, and save / fill / generate offers, which Java shows in a bar above the page ("passwordOffer" events).
## The passkey dialog is Java's ("passkey" events); the Passwords screen lists, edits and deletes.

import std/[algorithm, sequtils, strutils]
import ../core
import ../../../src/features/passwords/[vault, manager, generator, keyring]

const prefixMark = "\x01PREFIX\x01"
const pageScript = block:
  let dart = staticRead("../../../../app/lib/src/passwords/page_script.dart")
  let start = dart.find("=> '''") + 6
  dart[start ..< dart.find("''';", start)].replace("${jsonEncode(prefix)}", prefixMark).replace("\\\\", "\\")

const messageTag = "passwords:"

type
  OfferKind = enum noOffer, saveOffer, fillOffer, generateOffer
  Offer = object
    kind: OfferKind
    origin, username, password: string
    existing: SavedPassword
    accounts: seq[SavedPassword]

  Agent = ref object
    offer: Offer
    url: string
    filledOrigin: string
    generated: string

var
  agents: Table[int, Agent]
  lastOffer = ""

proc agentFor(t: Tab): Agent =
  if t == nil: return nil
  result = agents.getOrDefault(t.id)
  if result == nil:
    result = Agent()
    agents[t.id] = result

proc js(s: string): string = $(%s)

proc deferred(source: string): string = "setTimeout(() => { " & source & " }, 0);"

proc sendOffer() =
  ## The active tab's offer, for the bar above the page.
  let t = current()
  let a = agentFor(t)
  var j = %*{"kind": "none"}
  if a != nil and a.offer.kind != noOffer:
    let o = a.offer
    j = %*{"kind": $o.kind, "host": hostOf(o.origin), "username": o.username, "password": o.password,
      "update": o.existing != nil}
    var accounts = newJArray()
    for i, acc in o.accounts:
      if i == 4: break
      accounts.add %*{"index": i, "username": acc.username}
    j["accounts"] = accounts
  let text = $j
  if text != lastOffer:
    lastOffer = text
    event("passwordOffer", j)

proc setOffer(a: Agent, offer: Offer) =
  a.offer = offer
  sendOffer()

proc dismiss(a: Agent) = a.setOffer(Offer())

proc fill(t: Tab, a: Agent, account: SavedPassword) =
  let origin = originOf(t.url)
  if origin.len == 0 or origin != account.origin: return
  a.filledOrigin = origin
  t.runJs(deferred("window.__webbyPasswords && window.__webbyPasswords.fill(" & js(account.username) & ", " &
    js(account.password) & ", " & js(origin) & ");"))
  wake()
  if a.offer.kind == fillOffer: a.dismiss()

proc onMessage(t: Tab, raw: string): bool =
  if not raw.startsWith(messageTag): return false
  result = true
  let a = agentFor(t)
  let v = theVault
  let origin = originOf(t.url)
  if v == nil or origin.len == 0: return
  var message: JsonNode
  try: message = parseJson(raw[messageTag.len .. ^1])
  except CatchableError: return
  let kind = message{"type"}.getStr
  if incognito and kind in ["newPassword", "submit"]: return
  case kind
  of "newPassword":
    if a.generated.len > 0 or a.offer.kind == saveOffer or
        (a.offer.kind == generateOffer and a.offer.origin == origin): return
    a.setOffer(Offer(kind: generateOffer, origin: origin, password: generatePassword()))
  of "fields", "focus":
    let accounts = v.passwordsFor(origin)
    if accounts.len == 0 or a.offer.kind == saveOffer: return
    if accounts.len == 1 and kind == "fields" and a.filledOrigin != origin:
      fill(t, a, accounts[0])
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
  if t.url == a.url: return
  a.url = t.url
  a.filledOrigin = ""
  a.generated = ""
  if a.offer.kind == fillOffer and a.offer.origin != originOf(t.url): a.dismiss()

proc offerAction(args: JsonNode): JsonNode =
  ## {action: save | never | dismiss | use | another | fill, index}
  let t = current()
  let a = agentFor(t)
  if a == nil: return nil
  let o = a.offer
  case args{"action"}.getStr
  of "save":
    if theVault != nil and o.kind == saveOffer: theVault.savePassword(o.origin, o.username, o.password)
    a.dismiss()
  of "never":
    if theVault != nil: theVault.setNeverSave(o.origin, true)
    a.dismiss()
  of "use":
    if o.kind == generateOffer and originOf(t.url) == o.origin:
      a.generated = o.password
      t.runJs(deferred("window.__webbyPasswords && window.__webbyPasswords.fillNew(" & js(o.password) & ", " &
        js(o.origin) & ");"))
    a.dismiss()
  of "another":
    a.setOffer(Offer(kind: generateOffer, origin: o.origin, password: generatePassword()))
  of "fill":
    let i = args{"index"}.getInt
    if i in 0 ..< o.accounts.len: fill(t, a, o.accounts[i])
  else: a.dismiss()
  nil

# ---------------------------------------------------------------------------------------------------------------
# Passkeys: Java's dialog answers with "passkey.respond".

proc onWebauthn(t: Tab, request: JsonNode) =
  let r = request.copy
  r["tab"] = %t.id
  r["prompt"] = %t.webauthnJson
  if t != current(): activate(tabIndex(t.id))
  event("passkey", r)

proc passkeyRespond(args: JsonNode): JsonNode =
  ## {tab, prompt, ok, account (-1 for none)}
  let i = tabIndex(args{"tab"}.getInt)
  if i < 0: return nil
  let t = tabs[i]
  if str(webby_view_webauthn_prompt(t.view)) != args{"prompt"}.getStr: return nil
  webby_view_webauthn_respond(t.view, args{"ok"}.getBool.cint, args{"account"}.getInt(-1).cint)
  nil

# ---------------------------------------------------------------------------------------------------------------
# The Passwords screen

proc matches(p: SavedPassword, words: seq[string]): bool =
  let hay = (p.origin & " " & p.username).toLowerAscii
  for w in words:
    if w notin hay: return false
  true

proc list(args: JsonNode): JsonNode =
  ## {query} -> {error, passwords: [{id, origin, host, username, password}], passkeys, neverSave}
  let words = args{"query"}.getStr.toLowerAscii.splitWhitespace
  result = %*{"error": vaultError, "passwords": [], "passkeys": [], "neverSave": []}
  let v = theVault
  if v == nil: return
  syncPasskeys()
  var entries = v.passwords
  entries.sort(proc (a, b: SavedPassword): int = cmp(hostOf(a.origin), hostOf(b.origin)))
  for p in entries:
    if matches(p, words):
      result["passwords"].add %*{"id": p.id, "origin": p.origin, "host": hostOf(p.origin), "username": p.username,
        "password": p.password}
  var keys = v.passkeys
  keys.sort(proc (a, b: JsonNode): int = cmp(a{"rpId"}.getStr, b{"rpId"}.getStr))
  for k in keys:
    let hay = (k{"rpId"}.getStr & " " & k{"userName"}.getStr).toLowerAscii
    var ok = true
    for w in words:
      if w notin hay: ok = false
    if ok:
      result["passkeys"].add %*{"credentialId": k{"credentialId"}.getStr, "rpId": k{"rpId"}.getStr,
        "userName": k{"userName"}.getStr, "userDisplayName": k{"userDisplayName"}.getStr}
  for o in v.neverSave:
    if words.len == 0 or words.allIt(it in o.toLowerAscii): result["neverSave"].add %o

proc savePassword(args: JsonNode): JsonNode =
  ## {id ("" = new), origin (or a URL), username, password}
  let v = theVault
  if v == nil: return %*{"error": "The password vault isn't open."}
  var origin = originOf(args{"origin"}.getStr)
  if origin.len == 0: origin = originOf("https://" & args{"origin"}.getStr)
  if origin.len == 0: return %*{"error": "Enter the site's address, like https://example.com."}
  let id = args{"id"}.getStr
  var entry: SavedPassword = nil
  for p in v.passwords:
    if p.id == id: entry = p
  if entry != nil: v.updatePassword(entry, origin, args{"username"}.getStr, args{"password"}.getStr)
  else: v.savePassword(origin, args{"username"}.getStr, args{"password"}.getStr)
  %*{"ok": true}

proc deletePassword(args: JsonNode): JsonNode =
  let v = theVault
  if v == nil: return nil
  for p in v.passwords:
    if p.id == args{"id"}.getStr:
      v.deletePassword(p)
      break
  nil

proc install*() =
  androidKeyring.lookup = proc (profile: string): (bool, string) =
    let (ok, r) = callJava("keystoreGet", profile)
    if not ok: raise newException(KeyringError, "the Android keystore failed")
    (r.len > 0, r)
  androidKeyring.store = proc (profile, secret: string) =
    let (ok, r) = callJava("keystorePut", $(%*{"profile": profile, "secret": secret}))
    if not ok or r != "ok": raise newException(KeyringError, "the Android keystore failed")
  base.getSecret = proc (name: string): string = (if theVault == nil: "" else: vault.secret(theVault, name))
  base.setSecret = proc (name, value: string) =
    if theVault != nil: vault.setSecret(theVault, name, value)
  startupHooks.add proc () = startManager()
  webauthnHandler = onWebauthn
  tabStateHooks.add onTabState
  tabClosedHooks.add proc (t: Tab) = agents.del t.id
  activeTabHooks.add proc (t: Tab) = sendOffer()
  pageScriptHooks.add proc (t: Tab): string =
    if originOf(t.url).len == 0: "" else: pageScript.replace(prefixMark, js(t.messagePrefix & messageTag))
  pageTextHooks.add onMessage
  commands["passwords.offer"] = offerAction
  commands["passwords.list"] = list
  commands["passwords.save"] = savePassword
  commands["passwords.delete"] = deletePassword
  commands["passwords.allowSaving"] = proc (args: JsonNode): JsonNode =
    if theVault != nil: theVault.setNeverSave(args{"origin"}.getStr, false)
  commands["passwords.generate"] = proc (args: JsonNode): JsonNode = %generatePassword()
  commands["passkeys.delete"] = proc (args: JsonNode): JsonNode =
    deletePasskey(args{"credentialId"}.getStr)
  commands["passkey.respond"] = passkeyRespond
