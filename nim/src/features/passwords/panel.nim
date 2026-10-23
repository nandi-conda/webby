## The "Passwords and passkeys" side panel (vault_page.dart): lists, edits and deletes saved passwords and passkeys.

import std/[algorithm, os, sets, strutils, times]
import ../../browser
from nimkit/core as kit import nil
import vault, manager, generator

var
  panelActionHooks*: seq[proc (box: kit.Widget)]  ## add buttons beside "Add password" (sync puts its own there)
  panelOpen = false
  search, passwordList, passkeyList, statusLabel: kit.Widget
  revealed: HashSet[string]

proc refreshPanel*()

proc matches(text: string): bool =
  let q = kit.text(search).strip.toLowerAscii
  q.len == 0 or q in text.toLowerAscii

proc date(seconds: int64): string =
  if seconds <= 0: "" else: fromUnix(seconds).local.format("yyyy-MM-dd")

proc say(text: string) = kit.`text=`(statusLabel, text)

proc oneLine(text: string): kit.Widget =
  result = kit.label(text)
  kit.`maxChars=`(result, 200)

proc smallButton(icon, tooltip: string, action: proc ()): kit.Widget = kit.iconButton(icon, tooltip, action, 14)

proc row(icon, title: string, subtitle: seq[kit.Widget], trailing: seq[kit.Widget]): kit.Widget =
  let text = kit.column(kit.addClass(oneLine(title), "bold"))
  if subtitle.len > 0:
    let sub = kit.row(subtitle)
    sub.spacing = 12
    kit.add(text, sub)
  result = kit.addClass(kit.row(kit.icon(icon, 18), kit.expand(text)), "webby-vault-row")
  result.spacing = 6
  for w in trailing: kit.add(result, w)

proc small(text: string, cls = ""): kit.Widget =
  result = kit.addClass(oneLine(text), "small")
  if cls.len > 0: kit.addClass(result, cls)

proc emptyNote(list: kit.Widget, text: string) =
  kit.add(list, kit.addClass(kit.addClass(kit.label(text), "dim"), "webby-vault-note"))

proc editPassword*(entry: SavedPassword = nil) =
  ## The Add/Edit password dialog.
  let v = theVault
  if v == nil: return
  var fields: array[3, kit.Widget]
  let content = kit.column()
  content.spacing = 8
  for i, name in ["Site", "Username", "Password"]:
    fields[i] = kit.entry()
    let l = kit.label(name)
    discard kit.sized(l, 80)
    let r = kit.row(l, kit.expand(kit.sized(fields[i], 300)))
    r.spacing = 8
    kit.add(content, r)
  let (site, user, pass) = (fields[0], fields[1], fields[2])
  if entry != nil:
    kit.`text=`(site, entry.origin)
    kit.`text=`(user, entry.username)
    kit.`text=`(pass, entry.password)
  kit.`password=`(pass, true)
  let show = kit.check("Show password", false, proc (on: bool) = kit.`password=`(pass, not on))
  let tools = kit.row(show, kit.spacer(), kit.button("Generate a strong password", proc () =
    kit.`text=`(pass, generatePassword())
    kit.`checked=`(show, true)))
  tools.spacing = 6
  kit.add(content, tools)
  let error = kit.addClass(kit.label(""), "error")
  kit.add(content, error)
  var d: kit.Dialog
  d = kit.dialog(if entry == nil: "Add password" else: "Edit password", content, @["Cancel", "Save"],
    proc (i: int) =
      if i != 1: return
      var text = kit.text(site).strip
      if text.len > 0 and "://" notin text: text = "https://" & text
      let origin = originOf(text)
      if origin.len == 0:
        kit.`text=`(error, "Enter a web address, like https://example.com")
        kit.showDialog(d)
        kit.focus(site)
        return
      if entry == nil: v.savePassword(origin, kit.text(user), kit.text(pass))
      else: v.updatePassword(entry, origin, kit.text(user), kit.text(pass)))
  for f in fields: f.onSubmit = proc (s: string) = kit.dialogResult(d, 1)
  kit.focus(if entry == nil: site else: pass)

# Rows are made by procs so each row's closures get their own entry (closures in a loop body share its variables).

proc passwordRow(entry: SavedPassword): kit.Widget =
  let shown = entry.id in revealed
  row("language", hostOf(entry.origin), @[
    small(if entry.username.len == 0: "(no username)" else: entry.username),
    small(if shown: entry.password else: "••••••••••", "mono")], @[
    smallButton(if shown: "visibility_off" else: "visibility",
      if shown: "Hide password" else: "Show password", proc () =
        if entry.id in revealed: revealed.excl entry.id else: revealed.incl entry.id
        refreshPanel()),
    smallButton("person_outline", "Copy username", proc () =
      copyText(entry.username); say("Username copied")),
    smallButton("copy", "Copy password", proc () =
      copyText(entry.password); say("Password copied")),
    smallButton("edit_outlined", "Edit", proc () = editPassword(entry)),
    smallButton("delete_outline", "Delete", proc () =
      kit.confirm("Delete password?", "The password for " &
          (if entry.username.len == 0: "this account" else: entry.username) & " on " & hostOf(entry.origin) &
          " will be removed from Webby.", "Delete", destructive = true, onResult = proc (ok: bool) =
        if ok: theVault.deletePassword(entry)))])

proc neverSaveRow(origin: string): kit.Widget =
  row("block", hostOf(origin), @[], @[
    kit.addClass(kit.button("Allow saving", proc () = theVault.setNeverSave(origin, false)), "flat")])

proc passkeyRow(p: JsonNode): kit.Widget =
  let rpId = p{"rpId"}.getStr
  let id = p{"credentialId"}.getStr
  var parts: seq[string]
  let display = p{"userDisplayName"}.getStr
  if display.len > 0 and display != p{"userName"}.getStr: parts.add display
  if p{"userName"}.getStr.len > 0: parts.add p{"userName"}.getStr
  let created = date(p{"createdAt"}.getBiggestInt)
  if created.len > 0: parts.add "created " & created
  row("key", rpId, @[small(parts.join(" · "))], @[
    smallButton("delete_outline", "Delete", proc () =
      kit.confirm("Delete passkey?", "You won't be able to sign in to " & rpId & " with this passkey any more. " &
          "The site may still list it until you remove it there too.", "Delete", destructive = true,
        onResult = proc (ok: bool) = (if ok: deletePasskey(id))))])

proc fillPasswords() =
  kit.clear(passwordList)
  let v = theVault
  if v == nil:
    emptyNote(passwordList, if vaultError.len > 0: vaultError else: "Opening the vault…")
    if vaultError.len > 0:
      kit.add(passwordList, kit.addClass(kit.button("Try again", proc () = (retryVault(); refreshPanel())),
        "webby-vault-note"))
    return
  var entries: seq[SavedPassword]
  for p in v.passwords:
    if matches(p.origin) or matches(p.username): entries.add p
  entries.sort(proc (a, b: SavedPassword): int = cmp(hostOf(a.origin), hostOf(b.origin)))
  var never: seq[string]
  for o in v.neverSave:
    if matches(o): never.add o
  if entries.len == 0 and never.len == 0:
    emptyNote(passwordList, "No saved passwords. Webby offers to save one when you sign in to a site.")
    return
  for entry in entries: kit.add(passwordList, passwordRow(entry))
  if never.len > 0:
    kit.add(passwordList, kit.separator())
    kit.add(passwordList, kit.addClass(small("Never saved for", "dim"), "webby-vault-heading"))
    for origin in never: kit.add(passwordList, neverSaveRow(origin))

proc fillPasskeys() =
  kit.clear(passkeyList)
  if theVault == nil: return
  if not passkeysInVault:
    emptyNote(passkeyList, "This version of the Ladybird runtime keeps passkeys in its own file, outside the " &
      "vault. Update webby-ladybird to manage them here.")
    return
  var keys: seq[JsonNode]
  for p in theVault.passkeys:
    if matches(p{"rpId"}.getStr) or matches(p{"userName"}.getStr): keys.add p
  keys.sort(proc (a, b: JsonNode): int = cmp(a{"rpId"}.getStr, b{"rpId"}.getStr))
  if keys.len == 0:
    emptyNote(passkeyList, "No passkeys. Sites that support them offer to create one when you sign up.")
    return
  for p in keys: kit.add(passkeyList, passkeyRow(p))

proc refreshPanel*() =
  if not panelOpen: return
  fillPasswords()
  fillPasskeys()

proc showVaultPanel*() =
  let root = kit.addClass(kit.column(), "webby-vault")
  root.spacing = 6
  let v = theVault
  if v != nil and v.keyStore == ksFile:
    kit.add(root, kit.addClass(kit.addClass(kit.label("No keyring was found, so the vault's key is in a file next " &
      "to it (" & v.path.parentDir & "/vault.key). Anyone who can read your files can read your passwords. " &
      "Install GNOME Keyring or another Secret Service and restart Webby to move the key there."), "small"),
      "card"))
  passwordList = kit.column()
  passkeyList = kit.column()
  let passwordPage = kit.expand(kit.scroll(passwordList))
  let passkeyPage = kit.expand(kit.scroll(passkeyList))
  kit.`visible=`(passkeyPage, false)
  var tabs: array[2, kit.Widget]
  proc pick(i: int) =
    kit.`visible=`(passwordPage, i == 0)
    kit.`visible=`(passkeyPage, i == 1)
    for j, t in tabs: kit.`checked=`(t, i == j)
  tabs[0] = kit.toggle("Passwords", true, proc (on: bool) = pick(0))
  tabs[1] = kit.toggle("Passkeys", false, proc (on: bool) = pick(1))
  let switcher = kit.addClass(kit.row(kit.spacer(), tabs[0], tabs[1], kit.spacer()), "linked")
  switcher.spacing = 0
  kit.add(root, switcher)
  search = kit.entry("Search", onChange = proc (s: string) = refreshPanel())
  let actions = kit.row(kit.expand(search))
  actions.spacing = 6
  if v != nil:
    kit.add(actions, kit.addClass(kit.button("Add password", proc () = editPassword()), "suggested"))
    for h in panelActionHooks: h(actions)
  kit.add(root, actions)
  kit.add(root, passwordPage)
  kit.add(root, passkeyPage)
  statusLabel = kit.label("")
  kit.add(root, statusLabel)
  revealed.clear
  showSidePanel("Passwords and passkeys", root, 440, proc () = panelOpen = false)
  panelOpen = true
  refreshPanel()

proc toggleVaultPanel*() =
  if panelOpen: closeSidePanel() else: showVaultPanel()
