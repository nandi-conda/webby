## Fitting the page beside the side panel. The panel takes its width from the page, which then lays out narrower.
## Most pages reflow, but some get their right side cut off: captnemo.in's wide tables, under overflow-x: hidden,
## end at the panel's edge, which reads as the panel covering the page. Such a page is drawn smaller instead: fewer
## pixels per CSS pixel (Tab.pageScale) give it back the CSS width it had without the panel. A page that still
## overflows at that width (it overflows without the panel too) goes back to normal size.

import std/strutils
import ../browser
from nimkit/core as kit import nil

const
  measureScript = """(() => {
  const send = () => {
    const r = document.documentElement, b = document.body;
    if (!r) return;
    const m = { type: 'pagefit', id: __ID__, width: r.clientWidth || innerWidth,
      need: Math.max(r.scrollWidth, b ? b.scrollWidth : 0) };
    const prompt = window.prompt, sent = __PREFIX__ + JSON.stringify(m);
    setTimeout(() => { try { prompt.call(window, sent); } catch (e) {} }, 0);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', send, { once: true });
  else send();
})();"""
  slack = 8          ## CSS pixels of overflow that don't count (scrollbar-width rounding, 100vw boxes)
  minScale = 0.5

var
  serial = 0
  resizeGeneration = 0

proc js(s: string): string = $(%s)

proc scaleOf(t: Tab): float = (if t.pageScale > 0: t.pageScale else: 1.0)

proc target(): float =
  ## The scale that gives the page its width without the panel.
  let (w, _, ratio) = pageSize()
  if w <= 0 or not sidePanelShowing(): return 1.0
  let wide = w.float + kit.splitSize(pageSplit) * ratio
  result = clamp(w.float / wide, minScale, 1.0)
  if result > 0.98: result = 1.0

proc setScale(t: Tab, scale: float) =
  if abs(scaleOf(t) - scale) < 0.001: return
  t.pageScale = scale
  if t == currentTab(): resizeView(t)

proc measure(t: Tab) =
  if t == nil or t.closed or t.view == nil or not sidePanelShowing(): return
  inc serial
  t.props["pagefit"] = $serial
  t.runJs(measureScript.replace("__ID__", $serial).replace("__PREFIX__", js(t.messagePrefix)))

proc measureSoon(t: Tab, ms = 300) =
  discard after(ms, proc () = (if t == currentTab(): measure(t)))

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith("{\"type\":\"pagefit\""): return false
  result = true
  let j = try: parseJson(text) except CatchableError: return
  if $j{"id"}.getInt != t.props.getOrDefault("pagefit") or not sidePanelShowing(): return
  let over = j{"need"}.getInt > j{"width"}.getInt + slack
  if scaleOf(t) < 1.0:
    # Drawn smaller and still too wide: it overflows anyway, so smaller only makes it harder to read.
    if over:
      t.props["pagefitGaveUp"] = t.url
      setScale(t, 1.0)
  elif over and t.props.getOrDefault("pagefitGaveUp") != t.url:
    let s = target()
    if s < 1.0:
      setScale(t, s)
      measureSoon(t)   # check it fits now

proc pageOf(url: string): string =
  let hash = url.find('#')
  if hash >= 0: url[0 ..< hash] else: url

proc install*() =
  pageMessageHooks.add onMessage
  pageResizeHooks.add proc () =
    if not sidePanelShowing():
      for t in tabs:
        if t.pageScale > 0 and t.pageScale < 1.0: setScale(t, 1.0)
        t.props.del("pagefitGaveUp")
      return
    # The panel opened, was dragged wider or narrower, or the window changed size: once it settles, a page drawn
    # smaller gets the new width's scale, and any page is measured again.
    inc resizeGeneration
    let generation = resizeGeneration
    discard after(250, proc () =
      if generation != resizeGeneration: return
      let t = currentTab()
      if t == nil: return
      t.props.del("pagefitGaveUp")   # the new width may fit
      if scaleOf(t) < 1.0: setScale(t, target())
      measure(t))
  activeTabHooks.add proc (t: Tab) =
    if not sidePanelShowing(): return
    if scaleOf(t) < 1.0: setScale(t, target())
    measureSoon(t)
  navigationHooks.add proc (t: Tab) =
    # A new page starts at normal size; it's measured once loaded and again when late content has come in.
    if pageOf(t.props.getOrDefault("pagefitUrl")) != pageOf(t.url):
      t.props["pagefitUrl"] = t.url
      t.props.del("pagefitGaveUp")
      setScale(t, 1.0)
    if t == currentTab() and sidePanelShowing():
      measureSoon(t)
      measureSoon(t, 2000)
