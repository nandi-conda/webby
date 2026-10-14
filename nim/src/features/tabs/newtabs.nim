## window.open(url, '_blank', 'noopener') as a tab of its own (app/lib/src/tabs/new_tab_requests.dart): Ladybird puts
## every window a page opens on the opener's WebContent process, so tabs opened from a busy page (Pulseboard) stayed
## blank while it ran. The Dart app's page script sends {"type": "openTab", "url"} instead; the tab opened here gets a
## process of its own.

import std/[json, strutils]
import ../../browser

const newTabScript = block:
  let dart = staticRead("../../../../app/lib/src/tabs/new_tab_requests.dart")
  let head = "String newTabPageScript(String prefix) => '''"
  let start = dart.find(head) + head.len
  dart[start ..< dart.find("''';", start)].replace("\\\\", "\x01").replace("\\$", "$").replace("\x01", "\\")

proc pageScript(t: Tab): string =
  if t.messagePrefix.len == 0: return ""
  newTabScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix))

proc onMessage(t: Tab, msg: string): bool =
  if not msg.startsWith("{\"type\":\"openTab\""): return false
  let url = try: parseJson(msg){"url"}.getStr except CatchableError: ""
  if url.startsWith("http://") or url.startsWith("https://"):
    let i = tabs.find(t)
    discard openTab(url, true, if i >= 0: i + 1 else: -1)
  true

proc install*() =
  pageScriptHooks.add pageScript
  pageMessageHooks.add onMessage
