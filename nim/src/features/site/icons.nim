## Site icons (favicons) in the tab strip. The Dart app (app/lib/src/site_icon.dart) shows them only in saved-tab
## lists, from Google's favicon service; here each page reports its own <link rel=icon> (else /favicon.ico) and
## fetches it for the tab strip, so no host names go to a third party.

import std/[strutils, tables]
import ../../browser
import http, images, permissions

const iconScript = """
(() => {
  if (window.__webbyIcon) return;
  window.__webbyIcon = true;
  const PREFIX = $1;
  const prompt = window.prompt;
  let last = null;
  const report = () => {
    let best = null, score = -1;
    for (const link of document.querySelectorAll('link[rel][href]')) {
      const rel = link.rel.toLowerCase().split(/\s+/);
      if (!rel.includes('icon')) continue;
      const sizes = (link.getAttribute('sizes') || '').toLowerCase();
      const s = sizes.includes('32x32') ? 3 : sizes.includes('16x16') ? 2 : sizes ? 0 : 1;
      if (s > score) { best = link; score = s; }
    }
    const href = best ? best.href : location.origin + '/favicon.ico';
    if (href === last) return;
    last = href;
    try { prompt.call(window, PREFIX + JSON.stringify({ type: 'siteIcon', href })); } catch (e) {}
  };
  report();
  try { new MutationObserver(report).observe(document.head || document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel', 'sizes'] }); } catch (e) {}
})();
"""

var cache: Table[string, pointer]   ## icon URL to a 16 px GdkPixbuf (nil: it failed)

proc setDefault(t: Tab) =
  setIcon(t.icon, "public")

proc show(t: Tab, href: string) =
  if t.closed or t.props.getOrDefault("site.icon") != href: return
  let p = cache.getOrDefault(href)
  if p != nil: gtk_image_set_from_pixbuf(t.icon, p) else: setDefault(t)

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith("{\"type\":\"siteIcon\""): return false
  let href = try: parseJson(text){"href"}.getStr except CatchableError: ""
  if href.len == 0 or t.props.getOrDefault("site.icon") == href: return true
  t.props["site.icon"] = href
  if href in cache:
    show(t, href)
    return true
  fetch(t, href, proc (ok: bool, body, kind: string) =
    let full = if ok: decodeImage(body) else: nil
    cache[href] = if full == nil: nil else: scaled(full, 16)
    if full != nil: g_object_unref(full)
    show(t, href), maxBytes = 1 shl 20)
  true

proc onTabState(t: Tab) =
  let origin = originOf(t.url)
  if t.props.getOrDefault("site.iconOrigin") != origin:
    t.props["site.iconOrigin"] = origin
    t.props.del "site.icon"
    setDefault(t)

proc install*() =
  pageScriptHooks.add proc (t: Tab): string =
    if originOf(t.url).len == 0: "" else: iconScript.replace("$1", $(%t.messagePrefix))
  pageMessageHooks.add onMessage
  tabStateHooks.add onTabState
