## Shared by the Plasma integration's parts: bringing the window to the front when the desktop asks.

import ../../browser

proc gtk_window_set_startup_id(w: pointer, id: cstring) {.importc, cdecl.}
proc gtk_window_present(w: pointer) {.importc, cdecl.}

var activationToken*: string   ## from KRunner's SetActivationToken, for the next raise (Wayland's xdg-activation)

proc raiseWindow*(token = "") =
  ## On Wayland a window can only take the focus with an activation token from whoever asked (KRunner hands one
  ## over; without one KWin shows that webby wants attention instead).
  if window == nil: return
  let t = if token.len > 0: token else: activationToken
  activationToken = ""
  if t.len > 0: gtk_window_set_startup_id(window, t.cstring)
  gtk_window_present(window)

proc showTab*(t: Tab, token = "") =
  activateTab(t)
  raiseWindow(token)
