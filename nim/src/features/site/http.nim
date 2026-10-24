## Small downloads (manifests, app icons, favicons), fetched by the page itself: a script calls fetch() and hands the
## bytes back through the page-message channel. Same-origin files (and CORS-enabled ones) work. No HTTP client of our own (std/net's OpenSSL setup breaks libwebby loading).

import std/[base64, strutils, tables, uri]
import ../../browser

type Fetched* = proc (ok: bool, body, contentType: string)

var
  waiting: Table[int, Fetched]
  nextId = 1

const fetchScript = """
(async () => {
  const prompt = window.prompt;
  const send = (m) => { const text = $1 + JSON.stringify(m); setTimeout(() => { try { prompt.call(window, text); } catch (e) {} }, 0); };
  try {
    const r = await fetch($2, { headers: $3, credentials: 'same-origin' });
    if (!r.ok) throw 0;
    const b = new Uint8Array(await r.arrayBuffer());
    if (b.length > $4) throw 0;
    let s = '';
    for (let i = 0; i < b.length; i += 32768) s += String.fromCharCode.apply(null, b.subarray(i, i + 32768));
    send({ type: 'webbyFetch', id: $5, ok: true, kind: r.headers.get('content-type') || '', body: btoa(s) });
  } catch (e) {
    send({ type: 'webbyFetch', id: $5, ok: false });
  }
})();
"""

proc finish(id: int, ok: bool, body, kind: string) =
  if id notin waiting: return
  let done = waiting[id]
  waiting.del id
  done(ok, body, kind)

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith("{\"type\":\"webbyFetch\""): return false
  let m = try: parseJson(text) except CatchableError: return true
  var body = ""
  let ok = m{"ok"}.getBool
  if ok:
    try: body = decode(m{"body"}.getStr) except CatchableError: discard
  finish(m{"id"}.getInt, ok, body, m{"kind"}.getStr.split(';')[0].strip.toLowerAscii)
  true

proc dataUrl(url: string): (bool, string, string) =
  ## The bytes and MIME type of a data: URL.
  let comma = url.find(',')
  if comma < 0: return (false, "", "")
  let meta = url[5 ..< comma]
  let payload = url[comma + 1 .. ^1]
  try:
    if meta.endsWith(";base64"): (true, decode(payload), meta.split(';')[0])
    else: (true, decodeUrl(payload), meta.split(';')[0])
  except CatchableError: (false, "", "")

proc fetch*(t: Tab, url: string, done: Fetched, accept = "", maxBytes = 4 shl 20, timeoutMs = 20000) =
  ## Downloads `url` (http, https or data) from `t`'s page and calls `done`; fails after `timeoutMs`.
  if url.startsWith("data:"):
    let (ok, body, kind) = dataUrl(url)
    done(ok, body, kind)
    return
  if t == nil or t.closed or not (url.startsWith("http://") or url.startsWith("https://")):
    done(false, "", "")
    return
  let id = nextId
  inc nextId
  waiting[id] = done
  let headers = if accept.len > 0: $(%*{"Accept": accept}) else: "{}"
  t.runJs(fetchScript.multiReplace(("$1", $(%t.messagePrefix)), ("$2", $(%url)), ("$3", headers),
    ("$4", $maxBytes), ("$5", $id)))
  wake()
  discard after(timeoutMs, proc () = finish(id, false, "", ""))

proc install*() =
  pageMessageHooks.add onMessage
