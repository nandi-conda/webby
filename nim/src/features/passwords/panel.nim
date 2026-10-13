## The "Passwords and passkeys" side panel (vault_page.dart): lists, edits and deletes saved passwords and passkeys.

import std/[algorithm, os, sets, strutils, times]
import ../../browser
import vault, manager, generator, ui

var
  panelActionHooks*: seq[proc (box: Widget)]  ## add buttons beside "Add password" (sync puts its own there)
  panelOpen = false
  search, passwordList, passkeyList, statusLabel: Widget
  revealed: HashSet[string]

proc refreshPanel*()

proc matches(text: string): bool =
  let q = ($gtk_entry_get_text(search)).strip.toLowerAscii
  q.len == 0 or q in text.toLowerAscii

proc date(seconds: int64): string =
  if seconds <= 0: "" else: fromUnix(seconds).local.format("yyyy-MM-dd")

proc say(text: string) = gtk_label_set_text(statusLabel, text.cstring)

proc row(icon, title, subtitle: string, trailing: seq[Widget], monoSubtitle = false): Widget =
  result = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
  gtk_widget_set_margin_start(result, 8)
  gtk_widget_set_margin_end(result, 4)
  gtk_widget_set_margin_top(result, 4)
  gtk_widget_set_margin_bottom(result, 4)
  gtk_box_pack_start(result, icon(icon, 18), 0, 0, 0)
  let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  gtk_box_pack_start(text, markupLabel("<b>" & escapeMarkup(title) & "</b>"), 0, 0, 0)
  if subtitle.len > 0: gtk_box_pack_start(text, markupLabel("<small>" & subtitle & "</small>"), 0, 0, 0)
  gtk_box_pack_start(result, text, 1, 1, 0)
  for w in trailing: gtk_box_pack_start(result, w, 0, 0, 0)

proc emptyNote(list: Widget, text: string) =
  let l = markupLabel("<span alpha='60%'>" & escapeMarkup(text) & "</span>", wrap = true)
  gtk_label_set_xalign(l, 0.5)
  gtk_widget_set_margin_top(l, 24)
  gtk_widget_set_margin_start(l, 16)
  gtk_widget_set_margin_end(l, 16)
  gtk_list_box_insert(list, l, -1)

proc editPassword*(entry: SavedPassword = nil) =
  ## The Add/Edit password dialog.
  let v = theVault
  if v == nil: return
  let d = gtk_dialog_new_with_buttons(cstring(if entry == nil: "Add password" else: "Edit password"), window,
    GTK_DIALOG_MODAL, "_Cancel", GTK_RESPONSE_CANCEL, "_Save", GTK_RESPONSE_OK, nil)
  gtk_dialog_set_default_response(d, GTK_RESPONSE_OK)
  let grid = gtk_grid_new()
  gtk_container_set_border_width(grid, 12)
  gtk_grid_set_row_spacing(grid, 8)
  gtk_grid_set_column_spacing(grid, 8)
  var fields: array[3, Widget]
  for i, name in ["Site", "Username", "Password"]:
    let l = gtk_label_new(name.cstring)
    gtk_label_set_xalign(l, 1)
    gtk_grid_attach(grid, l, 0, i.cint, 1, 1)
    fields[i] = gtk_entry_new()
    gtk_entry_set_width_chars(fields[i], 32)
    gtk_entry_set_activates_default(fields[i], 1)
    gtk_grid_attach(grid, fields[i], 1, i.cint, 1, 1)
  let (site, user, pass) = (fields[0], fields[1], fields[2])
  if entry != nil:
    gtk_entry_set_text(site, entry.origin.cstring)
    gtk_entry_set_text(user, entry.username.cstring)
    gtk_entry_set_text(pass, entry.password.cstring)
  gtk_entry_set_visibility(pass, 0)
  let tools = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
  let show = gtk_check_button_new_with_label("Show password")
  show.on("toggled", proc () = gtk_entry_set_visibility(pass, gtk_toggle_button_get_active(show)))
  gtk_box_pack_start(tools, show, 0, 0, 0)
  gtk_box_pack_end(tools, button("Generate a strong password", proc () =
    gtk_entry_set_text(pass, generatePassword().cstring)
    gtk_toggle_button_set_active(show, 1)), 0, 0, 0)
  gtk_grid_attach(grid, tools, 1, 3, 1, 1)
  let error = markupLabel("")
  gtk_grid_attach(grid, error, 1, 4, 1, 1)
  gtk_box_pack_start(gtk_dialog_get_content_area(d), grid, 1, 1, 0)
  gtk_widget_show_all(d)
  gtk_widget_grab_focus(if entry == nil: site else: pass)
  while gtk_dialog_run(d) == GTK_RESPONSE_OK:
    var text = ($gtk_entry_get_text(site)).strip
    if text.len > 0 and "://" notin text: text = "https://" & text
    let origin = originOf(text)
    if origin.len == 0:
      gtk_label_set_markup(error, "<span foreground='#c01c28'>Enter a web address, like https://example.com</span>")
      continue
    if entry == nil: v.savePassword(origin, $gtk_entry_get_text(user), $gtk_entry_get_text(pass))
    else: v.updatePassword(entry, origin, $gtk_entry_get_text(user), $gtk_entry_get_text(pass))
    break
  gtk_widget_destroy(d)

# Rows are made by procs so each row's closures get their own entry (closures in a loop body share its variables).

proc passwordRow(entry: SavedPassword): Widget =
  let shown = entry.id in revealed
  let subtitle = escapeMarkup(if entry.username.len == 0: "(no username)" else: entry.username) & "   <tt>" &
    escapeMarkup(if shown: entry.password else: "••••••••••") & "</tt>"
  row("language", hostOf(entry.origin), subtitle, @[
    smallIconButton(if shown: "visibility_off" else: "visibility",
      if shown: "Hide password" else: "Show password", proc () =
        if entry.id in revealed: revealed.excl entry.id else: revealed.incl entry.id
        refreshPanel()),
    smallIconButton("person_outline", "Copy username", proc () =
      copyText(entry.username); say("Username copied")),
    smallIconButton("copy", "Copy password", proc () =
      copyText(entry.password); say("Password copied")),
    smallIconButton("edit_outlined", "Edit", proc () = editPassword(entry)),
    smallIconButton("delete_outline", "Delete", proc () =
      if confirm("Delete password?", "The password for " &
          (if entry.username.len == 0: "this account" else: entry.username) & " on " & hostOf(entry.origin) &
          " will be removed from Webby."):
        theVault.deletePassword(entry))])

proc neverSaveRow(origin: string): Widget =
  row("block", hostOf(origin), "", @[
    button("Allow saving", proc () = theVault.setNeverSave(origin, false), flat = true)])

proc passkeyRow(p: JsonNode): Widget =
  let rpId = p{"rpId"}.getStr
  let id = p{"credentialId"}.getStr
  var parts: seq[string]
  let display = p{"userDisplayName"}.getStr
  if display.len > 0 and display != p{"userName"}.getStr: parts.add display
  if p{"userName"}.getStr.len > 0: parts.add p{"userName"}.getStr
  let created = date(p{"createdAt"}.getBiggestInt)
  if created.len > 0: parts.add "created " & created
  row("key", rpId, escapeMarkup(parts.join(" · ")), @[
    smallIconButton("delete_outline", "Delete", proc () =
      if confirm("Delete passkey?", "You won't be able to sign in to " & rpId & " with this passkey any more. " &
          "The site may still list it until you remove it there too."):
        deletePasskey(id))])

proc fillPasswords() =
  clearChildren(passwordList)
  let v = theVault
  if v == nil:
    emptyNote(passwordList, if vaultError.len > 0: vaultError else: "Opening the vault…")
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
  for entry in entries: gtk_list_box_insert(passwordList, passwordRow(entry), -1)
  if never.len > 0:
    gtk_list_box_insert(passwordList, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), -1)
    let header = markupLabel("<small><span alpha='60%'>Never saved for</span></small>")
    gtk_widget_set_margin_start(header, 8)
    gtk_list_box_insert(passwordList, header, -1)
    for origin in never: gtk_list_box_insert(passwordList, neverSaveRow(origin), -1)

proc fillPasskeys() =
  clearChildren(passkeyList)
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
  for p in keys: gtk_list_box_insert(passkeyList, passkeyRow(p), -1)

proc refreshPanel*() =
  if not panelOpen: return
  fillPasswords()
  fillPasskeys()
  gtk_widget_show_all(passwordList)
  gtk_widget_show_all(passkeyList)

proc scrolledList(list: var Widget): Widget =
  list = gtk_list_box_new()
  gtk_list_box_set_selection_mode(list, GTK_SELECTION_NONE)
  result = gtk_scrolled_window_new(nil, nil)
  gtk_scrolled_window_set_policy(result, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
  gtk_container_add(result, list)

proc showVaultPanel*() =
  let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
  gtk_container_set_border_width(root, 8)
  let v = theVault
  if v != nil and v.keyStore == ksFile:
    let banner = markupLabel("<small>No keyring was found, so the vault's key is in a file next to it (" &
      escapeMarkup(v.path.parentDir & "/vault.key") & "). Anyone who can read your files can read your passwords. " &
      "Install GNOME Keyring or another Secret Service and restart Webby to move the key there.</small>", wrap = true)
    let frame = gtk_frame_new(nil)
    gtk_widget_set_margin_start(banner, 6)
    gtk_widget_set_margin_end(banner, 6)
    gtk_widget_set_margin_top(banner, 6)
    gtk_widget_set_margin_bottom(banner, 6)
    gtk_container_add(frame, banner)
    gtk_box_pack_start(root, frame, 0, 0, 0)
  let stack = gtk_stack_new()
  gtk_stack_add_titled(stack, scrolledList(passwordList), "passwords", "Passwords")
  gtk_stack_add_titled(stack, scrolledList(passkeyList), "passkeys", "Passkeys")
  let switcher = gtk_stack_switcher_new()
  gtk_stack_switcher_set_stack(switcher, stack)
  gtk_box_pack_start(root, switcher, 0, 0, 0)
  search = gtk_search_entry_new()
  gtk_entry_set_placeholder_text(search, "Search")
  search.on("search-changed", refreshPanel)
  let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
  gtk_box_pack_start(actions, search, 1, 1, 0)
  if v != nil:
    gtk_box_pack_end(actions, button("Add password", proc () = editPassword(), suggested = true), 0, 0, 0)
    for h in panelActionHooks: h(actions)
  gtk_box_pack_start(root, actions, 0, 0, 0)
  gtk_box_pack_start(root, stack, 1, 1, 0)
  statusLabel = markupLabel("")
  gtk_box_pack_start(root, statusLabel, 0, 0, 0)
  revealed.clear
  showSidePanel("Passwords and passkeys", root, 440, proc () = panelOpen = false)
  panelOpen = true
  refreshPanel()

proc toggleVaultPanel*() =
  if panelOpen: closeSidePanel() else: showVaultPanel()
