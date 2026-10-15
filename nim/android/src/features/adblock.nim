## Ad and tracker blocking on Android (src/features/adblock.nim on the desktop): core.nim switches the engine on
## before Ladybird starts; Java's ⋮ menu shows "Block ads and trackers" from the state's "adblock" and runs
## adblock.set, which answers {"live": bool} (false: the runtime applies it at the next start).

import ../core
import ../../../src/features/adblock/store

proc install*() =
  stateHooks.add proc (t: Tab, state: JsonNode) =
    state["adblock"] = %enabled()
  commands["adblock.set"] = proc (args: JsonNode): JsonNode =
    let on = args{"on"}.getBool(true)
    setEnabled(on)
    if appliesLive():
      let t = current()
      if t != nil and t.view != nil and t.url.len > 0: webby_view_reload(t.view)
    wake()
    sendState()
    %*{"live": appliesLive()}
