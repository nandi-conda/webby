## Site icons (favicons) in the tab strip. Each page reports its own <link rel=icon> (else /favicon.ico) and
## fetches it for the tab strip, so no host names go to a third party.

import std/[os, strutils, tables]
import ../../browser
from nimkit/core as kit import nil
import http, images, permissions

const iconScript = """
(() => {
  if (window.__webbyIcon) return;
  window.__webbyIcon = true;
  const PREFIX = $1;
  const prompt = window.prompt;
  let last = null;
  // Not while the document is still being parsed: a prompt() then can leave Ladybird's parser paused for good (no
  // DOMContentLoaded, no first paint, the page loading forever; joshuamorris.info's head scripts adding <link>s did it).
  // A change seen while loading is reported on DOMContentLoaded instead.
  const report = () => {
    if (document.readyState === 'loading') return;
    // The sharpest: an SVG, else the smallest size listed of at least 32 px (pinned tabs on a 2x screen draw 32
    // device pixels), else the biggest; a touch icon only when there's no plain one; else /favicon.ico.
    let best = null, score = -1, touch = null;
    for (const link of document.querySelectorAll('link[rel][href]')) {
      const rel = link.rel.toLowerCase().split(/\s+/);
      if (rel.includes('apple-touch-icon') || rel.includes('apple-touch-icon-precomposed')) { touch = touch || link; continue; }
      if (!rel.includes('icon')) continue;
      const type = (link.type || '').toLowerCase(), sizes = (link.getAttribute('sizes') || '').toLowerCase();
      let s = 1;
      if (type === 'image/svg+xml' || /\.svg($|[?#])/i.test(link.href) || sizes === 'any') s = 10000;
      else {
        const px = Math.max(0, ...sizes.split(/\s+/).map(z => parseInt(z, 10) || 0));
        if (px >= 32) s = 5000 - px; else if (px > 0) s = 2 + px;
      }
      if (s > score) { best = link; score = s; }
    }
    best = best || touch;
    const href = best ? best.href : location.origin + '/favicon.ico';
    if (href === last) return;
    last = href;
    const text = PREFIX + JSON.stringify({ type: 'siteIcon', href });
    setTimeout(() => { try { prompt.call(window, text); } catch (e) {} }, 0);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', report, { once: true });
  else report();
  try { new MutationObserver(report).observe(document.head || document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel', 'sizes'] }); } catch (e) {}
})();
"""

var cache: Table[string, string]   ## icon URL to the picture's bytes ("": it failed)

proc diskFile(origin: string): string =
  ## Each site's last icon, so tabs restored asleep at the next start (and pinned tabs) show it before they load.
  var name = ""
  for c in origin: name.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '.', '-'}: c else: '_')
  profileDir() / "site-icons" / name

proc savedIcon*(origin: string): string =
  ## The site's icon as last seen, for lists of sites (the notification centre); "" if there's none.
  result = if origin.len == 0: "" else: (try: readFile(diskFile(origin)) except CatchableError: "")
  if kit.imageMime(result).len == 0: result = ""

proc changed(t: Tab) =
  ## The strip shows a letter badge or the picture (features/tabs/strip.nim), so it hears of every change.
  updateTabButton(t)

proc show(t: Tab, href: string) =
  if t.closed or t.props.getOrDefault("site.icon") != href: return
  let bytes = cache.getOrDefault(href)
  if bytes.len == 0: return   # keeps the one from the disk, if any
  kit.`image=`(t.icon, bytes)
  changed(t)

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith("{\"type\":\"siteIcon\""): return false
  let href = try: parseJson(text){"href"}.getStr except CatchableError: ""
  if href.len == 0 or t.props.getOrDefault("site.icon") == href: return true
  t.props["site.icon"] = href
  if href in cache:
    show(t, href)
    return true
  let origin = originOf(t.url)
  fetch(t, href, proc (ok: bool, body, kind: string) =
    let good = ok and kit.imageMime(body).len > 0
    cache[href] = if good: body else: ""
    if good and not incognito and origin.len > 0:
      try: writeFileAtomic(diskFile(origin), body) except CatchableError: discard
    show(t, href), maxBytes = 1 shl 20)
  true

proc onTabButton(t: Tab) =
  ## A new site in the tab: drop the old site's icon and show this one's from the disk until the page reports its own.
  let origin = originOf(t.url)
  if t.props.getOrDefault("site.iconOrigin") == origin and "site.iconOrigin" in t.props: return
  t.props["site.iconOrigin"] = origin
  t.props.del "site.icon"
  let saved = if origin.len == 0: "" else: (try: readFile(diskFile(origin)) except CatchableError: "")
  kit.`image=`(t.icon, if kit.imageMime(saved).len > 0: saved else: "")
  changed(t)

proc install*() =
  pageScriptHooks.add proc (t: Tab): string =
    if originOf(t.url).len == 0: "" else: iconScript.replace("$1", $(%t.messagePrefix))
  pageMessageHooks.add onMessage
  tabButtonHooks.add onTabButton
