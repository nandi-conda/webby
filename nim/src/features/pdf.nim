## PDFs: webby shows them itself with MuPDF instead of the pdf.js viewer Ladybird opens for them (which never gets
## the document on some live sites). When a tab lands on Ladybird's viewer page, the PDF is fetched again here and
## webby-pdf (nim/pdf/, a MuPDF program; separate so a bad PDF can only crash it, and so MuPDF's AGPL stays out of
## this binary) renders its pages, which are painted over the page canvas in place of the viewer.
##
## The bar under the toolbar has the page number (type one to go there), zoom (Ctrl+plus/minus/0, Ctrl+wheel),
## Fit width, Contents (the outline, in the side panel), Save to the downloads folder and Open in another app.
## Ctrl+F finds text (features/find.nim asks pageFindHooks), dragging selects it and Ctrl+C copies, links work.
## Keys: arrows, Page Up/Down, Space, Home/End.
##
## A site that won't hand webby the file (Cloudflare's challenge on dl.acm.org needs the engine's cookies) gets it
## through Ladybird's own download instead, which then also stays in the downloads folder.

import std/[algorithm, base64, hashes, math, os, posix, strutils, tables, unicode, uri]
import ../browser
import nimkit/services
from nimkit/core as kit import nil
import downloads

proc g_spawn_async_with_pipes(dir: cstring, argv, envp: cstringArray, flags: cint, setup, data: pointer,
  pid: ptr cint, stdinFd, stdoutFd, stderrFd: ptr cint, err: pointer): cint {.importc, cdecl.}
proc g_child_watch_add(pid: cint, fn, data: pointer): cuint {.importc, cdecl.}
proc g_spawn_close_pid(pid: cint) {.importc, cdecl.}
proc g_unix_fd_add(fd: cint, condition: cuint, fn, data: pointer): cuint {.importc, cdecl.}
proc g_source_remove(id: cuint): cint {.importc, cdecl.}
proc g_app_info_launch_default_for_uri(uri: cstring, ctx: pointer, err: pointer): cint {.importc, cdecl.}

const
  gIoIn = 1.cuint
  gIoErr = 8.cuint
  gIoHup = 16.cuint
  viewerTitle = "PDF.js viewer"      ## Ladybird's viewer page (share/Lagom/ladybird/pdfjs/web/viewer.html)
  gapCss = 10.0                      ## between pages and around them, in CSS pixels
  pxPerPt = 96.0 / 72.0              ## at 100% a point is 1⅓ CSS pixels, as in other viewers
  zoomSteps = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]
  maxInFlight = 2                    ## page renders asked for at a time, so scrolling fast doesn't queue up work
  background = 0xFF525659'u32        ## around the pages (Chrome's PDF viewer grey)
  selectionColor = 0x3390FF'u32
  matchColor = 0xFFD000'u32
  currentMatchColor = 0xFF8C00'u32

# Hands webby pdf.js's copy of the PDF once it has the whole document, in base64 pieces through the page message
# channel: where the engine's navigation got the file and nothing else can (Cloudflare on dl.acm.org turns away
# webby's own request and Ladybird's download alike). The viewer page isn't the PDF's origin, so it can't fetch it.
const bytesScript = """
(async () => {
  const P = PREFIX, ID = DOCID;
  const prompt = window.prompt;
  const send = m => { const t = P + JSON.stringify(Object.assign({ type: 'webbyPdfData', id: ID }, m)); setTimeout(() => { try { prompt.call(window, t); } catch (e) {} }, 0); };
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  // Not yet the viewer (the old document right after the navigation started), or still parsing: a prompt() then
  // can wedge Ladybird's parser.
  for (let i = 0; i < 50 && !(window.PDFViewerApplication || document.getElementById('viewerContainer')); i++) await sleep(200);
  for (let i = 0; i < 50 && document.readyState === 'loading'; i++) await sleep(200);
  if (document.readyState === 'loading') return send({ error: 'still loading' });
  let bytes = null;
  for (let i = 0; i < 600 && !bytes; i++) {
    const app = window.PDFViewerApplication;
    if (app && app.pdfDocument) {
      try { bytes = await app.pdfDocument.getData(); } catch (e) { return send({ error: String(e) }); }
    } else await sleep(200);
  }
  if (!bytes) return send({ error: 'pdf.js never got the document' });
  const n = 3 * 65536;
  for (let i = 0; i < bytes.length; i += n) {
    const c = bytes.subarray(i, i + n);
    let s = '';
    for (let j = 0; j < c.length; j += 8192) s += String.fromCharCode.apply(null, c.subarray(j, j + 8192));
    send({ data: btoa(s) });
  }
  send({ done: true });
})();
"""

# Detects the viewer page even after pdf.js changed its title (a PDF it did get).
const detectScript = """
(() => {
  if (window.__webbyPdf || document.readyState === 'loading') return;
  if (!(window.PDFViewerApplication || document.getElementById('viewerContainer'))) return;
  window.__webbyPdf = true;
  const prompt = window.prompt, text = PREFIX + JSON.stringify({ type: 'webbyPdf' });
  setTimeout(() => { try { prompt.call(window, text); } catch (e) {} }, 0);
})();
"""

type
  PChar = object
    x0, y0, x1, y1: float32       ## points, from the page's top left
    c: Rune
    lineEnd: bool                 ## the last character on its line

  Link = object
    x0, y0, x1, y1: float
    uri: string                   ## outside the document; "" for a page in it
    page: int
    y: float

  Page = object
    w, h: float                   ## points
    img: string                   ## BGRA pixels, imgW x imgH, rendered at imgScale pixels per point
    imgW, imgH: int
    imgScale: float
    askedScale: float             ## the scale of the last render asked for and not back yet (0: none)
    chars: seq[PChar]
    links: seq[Link]
    textState: int                ## 0 not asked, 1 asked, 2 here
    findText: seq[Rune]           ## chars (lower case unless matching case), a space at line ends
    findMap: seq[int]             ## findText index -> chars index (-1: an added space)

  Caret = tuple[page, index: int]

  Match = tuple[page, first, last: int]   ## chars first ..< last

  DocState = enum dsFetching, dsOpening, dsReady, dsFailed

  Doc = ref object
    tab: Tab
    url, path, title, status: string
    state: DocState
    downloadId: uint64            ## fetching through Ladybird's download (the site wanted its cookies)
    id: int                       ## tells this document's page messages from an earlier one's
    pageData: string              ## the PDF so far from inside the page (bytesScript)
    pageFailed, gioFailed, engineTried, engineFailed: bool
    pid: cint
    inFd, outFd: cint
    watch: cuint
    buf: string
    pages: seq[Page]
    tops: seq[float]              ## each page's top, in pixels at the current scale
    outline: seq[tuple[level: int, title: string, page: int, y: float]]
    inFlight: int
    zoom: float
    fitWidth: bool
    scrollX, scrollY: float       ## pixels
    frame: seq[uint32]
    frameW, frameH: int
    dirty: bool
    selA, selB: Caret             ## selection anchor and focus (equal: nothing selected)
    dragging: bool
    downAt: tuple[x, y: float]
    query: string
    matchCase: bool
    matches: seq[Match]
    current: int                  ## index in matches, -1 none
    findShown: bool
    lastPage: int                 ## the page number the bar shows
    barHover: int                 ## the scrollbar under the pointer: 0 none, 1 vertical, 2 horizontal
    barDrag: int                  ## the scrollbar whose thumb is being dragged (same numbers)
    barGrab: float                ## where in the thumb it was grabbed, in pixels from its start

var
  docs: Table[int, Doc]           ## by the tab's address
  nextId = 1
  cacheDir: string
  bar, pageEntry, pageCount, zoomLabel, statusLabel, fitButton: kit.Widget
  barShown = false

proc key(t: Tab): int = cast[int](t)

proc docOf(t: Tab): Doc = docs.getOrDefault(key(t))

proc helperPath(): string = getAppDir() / "webby-pdf"

proc ratio(): float = max(pageSize().ratio, 0.5)

proc scale(d: Doc): float = d.zoom * ratio() * pxPerPt

proc gap(): float = gapCss * ratio()

proc layout(d: Doc) =
  let s = d.scale
  d.tops.setLen d.pages.len
  var y = gap()
  for i, p in d.pages:
    d.tops[i] = y
    y += round(p.h * s) + gap()

proc totalHeight(d: Doc): float =
  if d.pages.len == 0: 0.0 else: d.tops[^1] + round(d.pages[^1].h * d.scale) + gap()

proc totalWidth(d: Doc): float =
  var w = 0.0
  for p in d.pages: w = max(w, p.w)
  round(w * d.scale) + 2 * gap()

proc clampScroll(d: Doc) =
  let (vw, vh, _) = pageSize()
  d.scrollY = clamp(d.scrollY, 0.0, max(0.0, d.totalHeight - vh.float))
  d.scrollX = clamp(d.scrollX, 0.0, max(0.0, d.totalWidth - vw.float))

proc pageLeft(d: Doc, i: int): float =
  ## The page's left edge on the canvas.
  let (vw, _, _) = pageSize()
  let pw = round(d.pages[i].w * d.scale)
  if d.totalWidth <= vw.float: round((vw.float - pw) / 2) else: round((d.totalWidth - pw) / 2 - d.scrollX)

proc visibleRange(d: Doc): (int, int) =
  ## The first and last page on screen (-1, -1 for none).
  let (_, vh, _) = pageSize()
  let s = d.scale
  result = (-1, -1)
  for i in 0 ..< d.pages.len:
    let top = d.tops[i] - d.scrollY
    if top + d.pages[i].h * s < 0: continue
    if top > vh.float: break
    if result[0] < 0: result[0] = i
    result[1] = i

proc currentPage(d: Doc): int =
  ## The page at the canvas's middle third (the one being read), 0-based.
  let (_, vh, _) = pageSize()
  let mid = d.scrollY + vh.float / 3
  result = 0
  for i in 0 ..< d.pages.len:
    if d.tops[i] <= mid: result = i

proc fitZoom(d: Doc): float =
  let (vw, _, _) = pageSize()
  var w = 0.0
  for p in d.pages: w = max(w, p.w)
  if w <= 0 or vw <= 0: return 1.0
  clamp((vw.float - 2 * gap()) / (w * ratio() * pxPerPt), 0.25, 1.25)

# ---------------------------------------------------------------------------------------------------------------
# The bar

proc refreshBar() =
  let t = currentTab()
  let d = if t == nil: nil else: docOf(t)
  let show = d != nil
  if show != barShown:
    barShown = show
    kit.`visible=`(bar, show)
  if d == nil: return
  let ready = d.state == dsReady
  kit.`text=`(statusLabel, d.status)
  kit.`visible=`(statusLabel, d.status.len > 0)
  if ready:
    let p = d.currentPage + 1
    if p != d.lastPage or kit.text(pageCount) != "of " & $d.pages.len:
      d.lastPage = p
      kit.`text=`(pageEntry, $p)
      kit.`text=`(pageCount, "of " & $d.pages.len)
    kit.`text=`(zoomLabel, $int(round(d.zoom * 100)) & "%")
  kit.setClass(fitButton, "webby-pdf-on", d.fitWidth)
  for w in [pageEntry, pageCount, zoomLabel]: kit.`visible=`(w, ready)

proc invalidate(d: Doc) =
  d.dirty = true
  if d.tab == currentTab():
    kit.invalidate(browser.page)
    refreshBar()

# ---------------------------------------------------------------------------------------------------------------
# webby-pdf

proc send(d: Doc, line: string) =
  if d.inFd < 0: return
  let s = line & "\n"
  var done = 0
  while done < s.len:
    let n = posix.write(d.inFd, unsafeAddr s[done], s.len - done)
    if n < 0:
      if errno == EINTR: continue
      return
    done += n

proc pumpRequests(d: Doc)

proc stopHelper(d: Doc) =
  if d.watch != 0:
    discard g_source_remove(d.watch)
    d.watch = 0
  if d.inFd >= 0: discard posix.close(d.inFd)
  if d.outFd >= 0: discard posix.close(d.outFd)
  d.inFd = -1
  d.outFd = -1
  if d.pid > 0: discard posix.kill(d.pid, SIGTERM)
  d.pid = 0

proc fail(d: Doc, why: string) =
  d.state = dsFailed
  d.status = why
  stopHelper(d)
  invalidate(d)

proc buildFindText(d: Doc, i: int) =
  var p = addr d.pages[i]
  p.findText.setLen 0
  p.findMap.setLen 0
  for k, ch in p.chars:
    p.findText.add(if d.matchCase: ch.c else: ch.c.toLower)
    p.findMap.add k
    if ch.lineEnd and ch.c != Rune('-') and not ch.c.isWhiteSpace:
      p.findText.add Rune(' ')
      p.findMap.add -1

proc findInPage(d: Doc, i: int): seq[Match] =
  let q = (if d.matchCase: d.query else: d.query.toLower).toRunes
  if q.len == 0: return
  let p = addr d.pages[i]
  var at = 0
  while at + q.len <= p.findText.len:
    var ok = true
    for k in 0 ..< q.len:
      if p.findText[at + k] != q[k]:
        ok = false
        break
    if ok:
      var first = -1
      var last = -1
      for k in at ..< at + q.len:
        if p.findMap[k] >= 0:
          if first < 0: first = p.findMap[k]
          last = p.findMap[k]
      if first >= 0: result.add (i, first, last + 1)
      at += q.len
    else: inc at

proc reportFind(d: Doc) =
  let t = d.tab
  t.findCurrent = (if d.current >= 0: d.current + 1 else: 0)
  t.findTotal = d.matches.len
  for h in findHooks: h(t)

proc scrollToMatch(d: Doc)

proc rematch(d: Doc, keepPage = -1) =
  ## Finds the query in every page whose text is here; the current match stays on (or after) keepPage.
  d.matches.setLen 0
  for i in 0 ..< d.pages.len:
    if d.pages[i].textState == 2: d.matches.add findInPage(d, i)
  d.current = -1
  if d.matches.len > 0:
    let from0 = if keepPage >= 0: keepPage else: d.currentPage
    d.current = 0
    for k, m in d.matches:
      if m.page >= from0:
        d.current = k
        break

proc onText(d: Doc, j: JsonNode) =
  let i = j{"page"}.getInt(-1)
  if i notin 0 ..< d.pages.len: return
  var p = addr d.pages[i]
  p.textState = 2
  p.chars.setLen 0
  for line in j{"lines"}.getElems:
    let n = line.len
    for k, c in line.getElems:
      if c.len < 5: continue
      p.chars.add PChar(x0: c[0].getFloat.float32, y0: c[1].getFloat.float32, x1: c[2].getFloat.float32,
        y1: c[3].getFloat.float32, c: Rune(c[4].getInt), lineEnd: k == n - 1)
  p.links.setLen 0
  for l in j{"links"}.getElems:
    if l.len < 7: continue
    p.links.add Link(x0: l[0].getFloat, y0: l[1].getFloat, x1: l[2].getFloat, y1: l[3].getFloat, uri: l[4].getStr,
      page: l[5].getInt, y: l[6].getFloat)
  buildFindText(d, i)
  if d.findShown and d.query.len > 0:
    let hadCurrent = d.current >= 0
    let cur = if hadCurrent: d.matches[d.current] else: (-1, 0, 0)
    rematch(d)
    if hadCurrent:
      for k, m in d.matches:
        if m == cur: d.current = k
    reportFind(d)
    if not hadCurrent and d.current >= 0: scrollToMatch(d)
  invalidate(d)

proc onOpen(d: Doc, j: JsonNode) =
  if not j{"ok"}.getBool:
    fail(d, "Couldn't open this PDF: " & j{"error"}.getStr)
    return
  d.pages.setLen 0
  for s in j{"pages"}.getElems:
    d.pages.add Page(w: max(s[0].getFloat, 1.0), h: max(s[1].getFloat, 1.0))
  for o in j{"outline"}.getElems:
    if o.len >= 4: d.outline.add (o[0].getInt, o[1].getStr, o[2].getInt, o[3].getFloat)
  d.title = j{"title"}.getStr.strip
  d.state = dsReady
  d.status = ""
  d.fitWidth = true
  d.zoom = d.fitZoom
  layout(d)
  # The tab is named after the PDF rather than "PDF.js viewer".
  var name = d.title
  if name.len == 0:
    name = d.url.parseUri.path.extractFilename.decodeUrl
    if name.len == 0: name = d.url
  d.tab.runJs("document.title = " & $(%name) & ";")
  if d.findShown and d.query.len > 0:
    for i in 0 ..< d.pages.len: send(d, "text\t" & $i)
    for i in 0 ..< d.pages.len: d.pages[i].textState = 1
  pumpRequests(d)
  invalidate(d)

proc onRender(d: Doc, j: JsonNode, pixels: string) =
  let i = j{"page"}.getInt(-1)
  dec d.inFlight
  if i notin 0 ..< d.pages.len: return
  let sc = j{"tag"}.getInt / 1000
  var p = addr d.pages[i]
  if abs(p.askedScale - sc) < 0.0005: p.askedScale = 0
  let w = j{"w"}.getInt
  let h = j{"h"}.getInt
  # A render at an older zoom still beats a blank page until the current one comes.
  if w > 0 and h > 0 and pixels.len == w * h * 4 and (abs(sc - d.scale) < 0.0005 or p.img.len == 0 or
      abs(p.imgScale - d.scale) >= 0.0005):
    p.img = pixels
    p.imgW = w
    p.imgH = h
    p.imgScale = sc
  pumpRequests(d)
  invalidate(d)

proc parseOutput(d: Doc) =
  while true:
    let nl = d.buf.find('\n')
    if nl < 0: return
    let j = try: parseJson(d.buf[0 ..< nl]) except CatchableError: newJObject()
    let n = j{"bytes"}.getInt
    if d.buf.len < nl + 1 + n: return
    let pixels = if n > 0: d.buf[nl + 1 ..< nl + 1 + n] else: ""
    d.buf = d.buf[nl + 1 + n .. ^1]
    case j{"op"}.getStr
    of "open": onOpen(d, j)
    of "render": onRender(d, j, pixels)
    of "text": onText(d, j)
    else: discard
    if d.inFd < 0: return

proc onOutput(fd: cint, condition: cuint, data: pointer): cint {.cdecl.} =
  let d = docs.getOrDefault(cast[int](data))
  if d == nil or d.outFd != fd: return 0
  var chunk = newString(1 shl 20)
  let n = posix.read(fd, chunk.cstring, chunk.len)
  if n > 0:
    chunk.setLen n
    d.buf.add chunk
    parseOutput(d)
    return 1
  if n < 0 and errno in [EINTR, EAGAIN]: return 1
  d.watch = 0
  if d.state != dsFailed: fail(d, "The PDF renderer stopped (a damaged PDF?)")
  0

proc startHelper(d: Doc) =
  if not fileExists(helperPath()):
    fail(d, "webby-pdf is missing next to webby")
    return
  let argv = allocCStringArray([helperPath()])
  defer: deallocCStringArray(argv)
  d.inFd = -1
  d.outFd = -1
  # G_SPAWN_DO_NOT_REAP_CHILD; the helper's stderr (MuPDF's warnings) is webby's.
  if g_spawn_async_with_pipes(nil, argv, nil, 2, nil, nil, addr d.pid, addr d.inFd, addr d.outFd, nil, nil) == 0:
    fail(d, "Couldn't start webby-pdf")
    return
  discard g_child_watch_add(d.pid, proc (pid, status: cint, data: pointer) {.cdecl.} = g_spawn_close_pid(pid), nil)
  d.watch = g_unix_fd_add(d.outFd, gIoIn or gIoHup or gIoErr, onOutput, cast[pointer](key(d.tab)))
  d.state = dsOpening
  d.status = "Opening…"
  send(d, "open\t" & d.path)

proc pumpRequests(d: Doc) =
  ## Asks webby-pdf for what's on screen and not here yet: pages at the current zoom (nearest first, a page either
  ## side too), then their text (selection, links).
  if d.state != dsReady or d.tab != currentTab(): return
  let (first, last) = d.visibleRange
  if first < 0: return
  let s = d.scale
  let tag = int(round(s * 1000))
  let mid = d.currentPage
  var want: seq[int]
  for i in max(0, first - 1) .. min(d.pages.high, last + 1): want.add i
  want.sort(proc (a, b: int): int = cmp(abs(a - mid), abs(b - mid)))
  for i in want:
    if d.inFlight >= maxInFlight: break
    let p = addr d.pages[i]
    if abs(p.imgScale - tag / 1000) < 0.0005 and p.img.len > 0: continue
    if abs(p.askedScale - tag / 1000) < 0.0005: continue
    p.askedScale = tag / 1000
    inc d.inFlight
    send(d, "render\t" & $i & "\t" & formatFloat(tag / 1000, ffDecimal, 3) & "\t" & $tag)
  for i in first .. last:
    if d.pages[i].textState == 0:
      d.pages[i].textState = 1
      send(d, "text\t" & $i)
  # Pages far off screen give their pixels back.
  for i in 0 ..< d.pages.len:
    if (i < first - 3 or i > last + 3) and d.pages[i].img.len > 0:
      d.pages[i].img = ""
      d.pages[i].imgScale = 0

# ---------------------------------------------------------------------------------------------------------------
# Fetching

proc isPdf(data: string): bool = data.find("%PDF-", 0, min(data.high, 1023)) >= 0

proc opened(d: Doc, path: string) =
  d.path = path
  startHelper(d)
  invalidate(d)

proc closeDoc(t: Tab)

proc giveUp(d: Doc) =
  ## No way to get the file: Ladybird's own viewer shows instead, and this address isn't tried again in this tab.
  if d.state != dsFetching or docOf(d.tab) != d: return
  stderr.writeLine "webby: couldn't get the PDF at ", d.url, ", leaving it to Ladybird's viewer"
  d.tab.props["pdfGaveUp"] = d.url
  closeDoc(d.tab)

proc gotBytes(d: Doc, data: string) =
  if d.state != dsFetching or docOf(d.tab) != d: return
  let path = cacheDir / ($hash(d.url) & ".pdf")
  try:
    createDir(cacheDir)
    writeFile(path, data)
  except CatchableError:
    fail(d, "Couldn't save the PDF: " & getCurrentExceptionMsg())
    return
  opened(d, path)

proc fetchWithEngine(d: Doc) =
  ## Ladybird downloads it (with the site's cookies); features/pdf watches the list for the file.
  d.engineTried = true
  if webby_downloads_start != nil: d.downloadId = webby_downloads_start(d.url.cstring, incognito.cint)
  d.engineFailed = d.downloadId == 0
  invalidate(d)

proc sourceFailed(d: Doc) =
  ## webby's own request came back without it: Ladybird's download (with the site's cookies) is tried while pdf.js
  ## may still be getting it. With all three out, Ladybird's viewer is left to show what it can.
  if d.state != dsFetching or docOf(d.tab) != d: return
  if d.gioFailed and not d.engineTried: fetchWithEngine(d)
  if d.gioFailed and d.engineFailed and d.pageFailed: giveUp(d)

proc fetch(d: Doc, url: string, redirects = 0) =
  request("GET", url, proc (r: Response) =
    if docOf(d.tab) != d: return
    if r.status in [301, 302, 303, 307, 308] and redirects < 5 and r.header("location").len > 0:
      fetch(d, $combine(parseUri(url), parseUri(r.header("location"))), redirects + 1)
      return
    if r.status == 200 and isPdf(r.body): gotBytes(d, r.body)
    else:
      d.gioFailed = true
      sourceFailed(d),
    headers = @[("Accept", "application/pdf,*/*")])

proc onPageData(t: Tab, msg: string): bool =
  if not msg.startsWith("{\"type\":\"webbyPdfData\""): return false
  result = true
  let d = docOf(t)
  let j = try: parseJson(msg) except CatchableError: return
  if d == nil or j{"id"}.getInt != d.id or d.state != dsFetching or d.pageFailed: return
  if j.hasKey("error"):
    stderr.writeLine "webby: PDF from the page: ", j{"error"}.getStr
    d.pageFailed = true
    sourceFailed(d)
  elif j.hasKey("data"):
    try: d.pageData.add decode(j{"data"}.getStr)
    except CatchableError:
      d.pageFailed = true
      sourceFailed(d)
  elif j{"done"}.getBool:
    let data = move d.pageData
    if isPdf(data): gotBytes(d, data)
    else:
      d.pageFailed = true
      sourceFailed(d)

proc checkDownload(d: Doc) =
  if d.downloadId == 0 or webby_downloads_json == nil: return
  let list = try: parseJson($webby_downloads_json()) except CatchableError: return
  for e in list.getElems:
    if e{"id"}.getBiggestInt.uint64 != d.downloadId: continue
    case e{"status"}.getStr
    of "completed":
      d.downloadId = 0
      let path = e{"path"}.getStr
      if d.state == dsFetching and fileExists(path) and isPdf(readFile(path)): opened(d, path)
      else:
        d.engineFailed = true
        sourceFailed(d)
    of "failed", "canceled":
      d.downloadId = 0
      stderr.writeLine "webby: downloading the PDF failed: ", e{"error"}.getStr
      d.engineFailed = true
      sourceFailed(d)
    else:
      let got = e{"received"}.getBiggestInt
      let total = e{"total"}.getBiggestInt
      let s = if total > 0: "Downloading… " & $(got * 100 div total) & "%" else: "Downloading…"
      if s != d.status:
        d.status = s
        invalidate(d)

proc closeDoc(t: Tab) =
  let d = docOf(t)
  if d == nil: return
  docs.del key(t)
  stopHelper(d)
  if d.path.startsWith(cacheDir):
    try: removeFile(d.path) except CatchableError: discard
  if t.findTotal > 0 or t.findCurrent > 0:
    t.findCurrent = 0
    t.findTotal = 0
  if t == currentTab():
    kit.invalidate(browser.page)
    refreshBar()

proc show(t: Tab) =
  ## The tab is on Ladybird's PDF viewer: webby takes over.
  if t.url.len == 0 or not (t.url.startsWith("http://") or t.url.startsWith("https://") or t.url.startsWith("file:")):
    return
  let old = docOf(t)
  if old != nil and old.url == t.url: return
  if t.props.getOrDefault("pdfGaveUp") == t.url: return
  closeDoc(t)
  let d = Doc(tab: t, url: t.url, state: dsFetching, status: "Loading PDF…", zoom: 1.0, fitWidth: true,
    pid: 0, inFd: -1, outFd: -1, current: -1, dirty: true, id: nextId)
  inc nextId
  docs[key(t)] = d
  if t.url.startsWith("file:"):
    let path = decodeUrl(t.url.parseUri.path)
    if fileExists(path): opened(d, path) else: fail(d, "No such file")
  else:
    # Both at once: webby's own request is quickest where the site doesn't care (arXiv), the page's has its cookies.
    fetch(d, t.url)
    t.runJs(bytesScript.replace("PREFIX", $(%t.messagePrefix)).replace("DOCID", $d.id))
  invalidate(d)

# ---------------------------------------------------------------------------------------------------------------
# Painting

proc blend(dst: var uint32, rgb: uint32, a: uint32) =
  ## Puts rgb at a/255 over an opaque pixel.
  let ia = 255'u32 - a
  let r = (((dst shr 16) and 0xFF) * ia + ((rgb shr 16) and 0xFF) * a) div 255
  let g = (((dst shr 8) and 0xFF) * ia + ((rgb shr 8) and 0xFF) * a) div 255
  let b = ((dst and 0xFF) * ia + (rgb and 0xFF) * a) div 255
  dst = 0xFF000000'u32 or (r shl 16) or (g shl 8) or b

proc tint(d: Doc, x0, y0, x1, y1: float, rgb: uint32, a: uint32) =
  let ix0 = max(0, int(floor(x0)))
  let iy0 = max(0, int(floor(y0)))
  let ix1 = min(d.frameW, int(ceil(x1)))
  let iy1 = min(d.frameH, int(ceil(y1)))
  for y in iy0 ..< iy1:
    let row = y * d.frameW
    for x in ix0 ..< ix1: blend(d.frame[row + x], rgb, a)

proc selRange(d: Doc): (Caret, Caret) =
  if d.selA <= d.selB: (d.selA, d.selB) else: (d.selB, d.selA)

proc hasSelection(d: Doc): bool = d.selA != d.selB

proc tintChars(d: Doc, i, first, last: int, left, top, s: float, rgb: uint32, a: uint32) =
  ## Highlights chars first ..< last of page i, a box per run on one line.
  let p = addr d.pages[i]
  var k = first
  while k < last:
    var x0 = p.chars[k].x0
    var y0 = p.chars[k].y0
    var x1 = p.chars[k].x1
    var y1 = p.chars[k].y1
    while not p.chars[k].lineEnd and k + 1 < last:
      inc k
      x0 = min(x0, p.chars[k].x0); y0 = min(y0, p.chars[k].y0)
      x1 = max(x1, p.chars[k].x1); y1 = max(y1, p.chars[k].y1)
    inc k
    d.tint(left + x0 * s, top + y0 * s, left + x1 * s, top + y1 * s, rgb, a)

proc drawScrollbars(d: Doc)
proc composePages(d: Doc)

proc compose(d: Doc) =
  d.composePages
  d.drawScrollbars

proc composePages(d: Doc) =
  let (vw, vh, _) = pageSize()
  if vw <= 0 or vh <= 0: return
  d.frameW = vw
  d.frameH = vh
  d.frame.setLen vw * vh
  for px in d.frame.mitems: px = background
  d.dirty = false
  if d.state != dsReady: return
  let s = d.scale
  let (first, last) = d.visibleRange
  if first < 0: return
  let (lo, hi) = d.selRange
  for i in first .. last:
    let p = addr d.pages[i]
    let left = d.pageLeft(i)
    let top = d.tops[i] - d.scrollY
    let pw = int(round(p.w * s))
    let ph = int(round(p.h * s))
    let x0 = max(0, int(left))
    let x1 = min(vw, int(left) + pw)
    let y0 = max(0, int(top))
    let y1 = min(vh, int(top) + ph)
    if x1 <= x0 or y1 <= y0: continue
    if p.img.len > 0 and p.imgW == pw and p.imgH == ph:
      let src = cast[ptr UncheckedArray[uint32]](p.img.cstring)
      for y in y0 ..< y1:
        copyMem(addr d.frame[y * vw + x0], addr src[(y - int(top)) * pw + (x0 - int(left))], (x1 - x0) * 4)
    elif p.img.len > 0:
      # An older zoom's pixels, stretched until the new ones come.
      let src = cast[ptr UncheckedArray[uint32]](p.img.cstring)
      let fx = p.imgW / pw
      let fy = p.imgH / ph
      for y in y0 ..< y1:
        let sy = min(p.imgH - 1, int(float(y - int(top)) * fy))
        let row = y * vw
        for x in x0 ..< x1:
          d.frame[row + x] = src[sy * p.imgW + min(p.imgW - 1, int(float(x - int(left)) * fx))]
    else:
      for y in y0 ..< y1:
        for x in x0 ..< x1: d.frame[y * vw + x] = 0xFFFFFFFF'u32
    if p.textState == 2 and p.chars.len > 0:
      if d.findShown:
        for k, m in d.matches:
          if m.page == i:
            d.tintChars(i, m.first, m.last, left, top, s, if k == d.current: currentMatchColor else: matchColor, 110)
      if d.hasSelection and i >= lo.page and i <= hi.page:
        let a = if i == lo.page: lo.index else: 0
        let b = if i == hi.page: hi.index else: p.chars.len
        if b > a: d.tintChars(i, a, min(b, p.chars.len), left, top, s, selectionColor, 90)

# Scrollbars, drawn as Ladybird draws a page's (a thin pill that widens over a track while the pointer is on it), in
# light colours for the dark grey around the pages.

proc scrollTo(d: Doc, y: float, x = -1.0)

proc barThickness(d: Doc, which: int): float =
  (if d.barHover == which or d.barDrag == which: 12.0 else: 8.0) * ratio()

proc scrollbarShown(d: Doc, which: int): bool =
  let (vw, vh, _) = pageSize()
  if d.state != dsReady: return false
  if which == 1: d.totalHeight > vh.float + 0.5 else: d.totalWidth > vw.float + 0.5

proc barTrack(d: Doc, which: int): tuple[x0, y0, x1, y1: float] =
  ## The scrollbar's whole strip along the canvas's right (1) or bottom (2) edge.
  let (vw, vh, _) = pageSize()
  let t = d.barThickness(which)
  let other = 12.0 * ratio()
  if which == 1: (vw.float - t, 0.0, vw.float, vh.float - (if d.scrollbarShown(2): other else: 0.0))
  else: (0.0, vh.float - t, vw.float - (if d.scrollbarShown(1): other else: 0.0), vh.float)

proc barThumb(d: Doc, which: int): tuple[start, length: float] =
  ## The thumb along its track: where it starts and how long it is, in pixels.
  let (vw, vh, _) = pageSize()
  let tr = d.barTrack(which)
  let room = if which == 1: tr.y1 - tr.y0 else: tr.x1 - tr.x0
  let (view, total, pos) = if which == 1: (vh.float, d.totalHeight, d.scrollY) else: (vw.float, d.totalWidth, d.scrollX)
  let len = clamp(room * view / max(total, 1.0), min(24.0 * ratio(), room), room)
  let span = max(total - view, 1.0)
  (clamp(pos / span, 0.0, 1.0) * (room - len), len)

proc pill(d: Doc, x0, y0, x1, y1: float, rgb: uint32, a: uint32) =
  ## A rectangle with fully rounded ends, edges smoothed.
  let r = min(x1 - x0, y1 - y0) / 2
  for y in max(0, int(floor(y0))) ..< min(d.frameH, int(ceil(y1))):
    for x in max(0, int(floor(x0))) ..< min(d.frameW, int(ceil(x1))):
      let px = x.float + 0.5
      let py = y.float + 0.5
      let cx = clamp(px, x0 + r, x1 - r)
      let cy = clamp(py, y0 + r, y1 - r)
      let cover = clamp(r + 0.5 - hypot(px - cx, py - cy), 0.0, 1.0)
      if cover > 0: blend(d.frame[y * d.frameW + x], rgb, uint32(a.float * cover))

proc drawScrollbars(d: Doc) =
  for which in [1, 2]:
    if not d.scrollbarShown(which): continue
    let tr = d.barTrack(which)
    let wide = d.barHover == which or d.barDrag == which
    if wide: d.tint(tr.x0, tr.y0, tr.x1, tr.y1, 0xFFFFFF'u32, 26)
    let th = d.barThumb(which)
    let inset = 2.0 * ratio()
    # Ladybird's grey thumb, with a light rim so it shows on the dark surround and on a white page alike.
    let alpha = if d.barDrag == which: 230'u32 elif wide: 210'u32 else: 190'u32
    var (x0, y0, x1, y1) = if which == 1: (tr.x0 + inset, tr.y0 + th.start + inset, tr.x1 - inset / 2,
                                           tr.y0 + th.start + th.length - inset)
                           else: (tr.x0 + th.start + inset, tr.y0 + inset, tr.x0 + th.start + th.length - inset,
                                  tr.y1 - inset / 2)
    let rim = ratio()
    d.pill(x0 - rim, y0 - rim, x1 + rim, y1 + rim, 0xFFFFFF'u32, 150)
    d.pill(x0, y0, x1, y1, 0x6A6A6A'u32, alpha)

proc barAt(d: Doc, x, y: float): int =
  ## The scrollbar under a canvas point (its widened strip), or 0.
  let (vw, vh, _) = pageSize()
  let grab = 12.0 * ratio()
  if d.scrollbarShown(1) and x >= vw.float - grab and x <= vw.float: return 1
  if d.scrollbarShown(2) and y >= vh.float - grab and y <= vh.float: return 2

proc scrollFromBar(d: Doc, which: int, along: float) =
  ## Puts the thumb's start at `along` (pixels along the track).
  let (vw, vh, _) = pageSize()
  let tr = d.barTrack(which)
  let th = d.barThumb(which)
  let room = (if which == 1: tr.y1 - tr.y0 else: tr.x1 - tr.x0) - th.length
  let f = if room > 0: clamp(along / room, 0.0, 1.0) else: 0.0
  if which == 1: d.scrollTo(f * (d.totalHeight - vh.float))
  else: d.scrollTo(d.scrollY, f * (d.totalWidth - vw.float))

proc frameFor(t: Tab): tuple[data: pointer, width, height, stride: int] =
  let d = docOf(t)
  if d == nil: return
  let (vw, vh, _) = pageSize()
  if d.dirty or d.frameW != vw or d.frameH != vh: compose(d)
  if d.frame.len == 0: return
  (pointer(addr d.frame[0]), d.frameW, d.frameH, d.frameW * 4)

# ---------------------------------------------------------------------------------------------------------------
# Moving around

proc scrollTo(d: Doc, y: float, x = -1.0) =
  d.scrollY = y
  if x >= 0: d.scrollX = x
  d.clampScroll
  pumpRequests(d)
  invalidate(d)

proc goToPage(d: Doc, i: int, yPt = 0.0) =
  if d.state != dsReady or d.pages.len == 0: return
  let i = clamp(i, 0, d.pages.high)
  d.scrollTo(d.tops[i] + yPt * d.scale - (if yPt > 0: gap() * 2 else: gap()))

proc scrollToMatch(d: Doc) =
  if d.current notin 0 ..< d.matches.len: return
  let m = d.matches[d.current]
  let p = addr d.pages[m.page]
  let s = d.scale
  let (vw, vh, _) = pageSize()
  let y = d.tops[m.page] + p.chars[m.first].y0 * s
  if y < d.scrollY + vh.float * 0.1 or y > d.scrollY + vh.float * 0.8:
    d.scrollY = y - vh.float / 3
  let x = d.pageLeft(m.page) + d.scrollX + p.chars[m.first].x0 * s
  if d.totalWidth > vw.float and (x < d.scrollX or x > d.scrollX + vw.float * 0.9):
    d.scrollX = x - vw.float / 3
  d.scrollTo(d.scrollY)

proc setZoom(d: Doc, z: float, fit = false, anchorX = -1.0, anchorY = -1.0) =
  if d.state != dsReady: return
  let (vw, vh, _) = pageSize()
  let ax = if anchorX >= 0: anchorX else: vw.float / 2
  let ay = if anchorY >= 0: anchorY else: vh.float / 2
  # The spot under the anchor stays put.
  let oldH = max(1.0, d.totalHeight)
  let oldW = max(1.0, d.totalWidth)
  let fy = (d.scrollY + ay) / oldH
  let fx = (d.scrollX + ax) / oldW
  d.fitWidth = fit
  d.zoom = clamp(z, zoomSteps[0], zoomSteps[^1])
  layout(d)
  d.scrollY = fy * d.totalHeight - ay
  d.scrollX = fx * d.totalWidth - ax
  d.scrollTo(d.scrollY)

proc zoomStep(d: Doc, up: bool, anchorX = -1.0, anchorY = -1.0) =
  var z = d.zoom
  if up:
    for s in zoomSteps:
      if s > d.zoom + 0.001:
        z = s
        break
  else:
    for i in countdown(zoomSteps.high, 0):
      if zoomSteps[i] < d.zoom - 0.001:
        z = zoomSteps[i]
        break
  d.setZoom(z, false, anchorX, anchorY)

# ---------------------------------------------------------------------------------------------------------------
# Text: hit testing, selection, copying

proc hit(d: Doc, x, y: float): tuple[page: int, px, py: float] =
  ## The page under (or nearest to) a canvas point, and the point in that page's points.
  let s = d.scale
  result = (-1, 0.0, 0.0)
  if d.state != dsReady or d.pages.len == 0: return
  let docY = y + d.scrollY
  var best = 0
  for i in 0 ..< d.pages.len:
    if d.tops[i] - gap() / 2 <= docY: best = i
  result.page = best
  result.px = (x - d.pageLeft(best)) / s
  result.py = (docY - d.tops[best]) / s

proc caretAt(d: Doc, i: int, x, y: float): int =
  ## The caret (a chars index: before that char) nearest to (x, y) in page i's points.
  let p = addr d.pages[i]
  if p.chars.len == 0: return 0
  if y < p.chars[0].y0 - 2 and x < p.chars[0].x1: return 0
  # The line: the one whose height spans y and is nearest across, else the nearest one.
  var bestStart, bestEnd = 0
  var bestDist = Inf
  var k = 0
  while k < p.chars.len:
    let start = k
    var x0 = p.chars[k].x0
    var x1 = p.chars[k].x1
    var y0 = p.chars[k].y0
    var y1 = p.chars[k].y1
    while not p.chars[k].lineEnd and k + 1 < p.chars.len:
      inc k
      x0 = min(x0, p.chars[k].x0); x1 = max(x1, p.chars[k].x1)
      y0 = min(y0, p.chars[k].y0); y1 = max(y1, p.chars[k].y1)
    let dy = if y < y0: y0 - y elif y > y1: y - y1 else: 0.0
    let dx = if x < x0: x0 - x elif x > x1: x - x1 else: 0.0
    let dist = dy * 4 + dx
    if dist < bestDist:
      bestDist = dist
      bestStart = start
      bestEnd = k
    inc k
  for c in bestStart .. bestEnd:
    if x < (p.chars[c].x0 + p.chars[c].x1) / 2: return c
  bestEnd + 1

proc caretFrom(d: Doc, x, y: float): Caret =
  let h = d.hit(x, y)
  if h.page < 0: return (0, 0)
  (h.page, d.caretAt(h.page, h.px, h.py))

proc charAt(d: Doc, x, y: float): tuple[page, index: int] =
  ## The char right under a canvas point, or (-1, -1).
  let h = d.hit(x, y)
  result = (-1, -1)
  if h.page < 0: return
  let p = addr d.pages[h.page]
  for k, c in p.chars:
    if h.px >= c.x0 and h.px <= c.x1 and h.py >= c.y0 and h.py <= c.y1: return (h.page, k)

proc linkAt(d: Doc, x, y: float): Link =
  let h = d.hit(x, y)
  result.page = -1
  if h.page < 0: return
  for l in d.pages[h.page].links:
    if h.px >= l.x0 and h.px <= l.x1 and h.py >= l.y0 and h.py <= l.y1: return l

proc selectedText(d: Doc): string =
  let (lo, hi) = d.selRange
  for i in lo.page .. hi.page:
    let p = addr d.pages[i]
    let a = if i == lo.page: lo.index else: 0
    let b = min(if i == hi.page: hi.index else: p.chars.len, p.chars.len)
    for k in a ..< b:
      result.add p.chars[k].c
      if p.chars[k].lineEnd and k + 1 < b or p.chars[k].lineEnd and i < hi.page and k == b - 1:
        if p.chars[k].c == Rune('-'): result.setLen result.len - 1
        elif not p.chars[k].c.isWhiteSpace: result.add '\n'
  result = result.strip(leading = false)

proc copySelection(d: Doc) =
  if d.hasSelection: copyText(d.selectedText)

proc isWordChar(c: Rune): bool = c.isAlpha or (c.int < 128 and char(c.int) in {'0'..'9', '_', '\''})

proc selectWord(d: Doc, c: Caret, line: bool) =
  let p = addr d.pages[c.page]
  if p.chars.len == 0: return
  var a = min(c.index, p.chars.high)
  var b = a
  if line:
    while a > 0 and not p.chars[a - 1].lineEnd: dec a
    while b < p.chars.high and not p.chars[b].lineEnd: inc b
  elif p.chars[a].c.isWordChar:
    while a > 0 and not p.chars[a - 1].lineEnd and p.chars[a - 1].c.isWordChar: dec a
    while b < p.chars.high and not p.chars[b].lineEnd and p.chars[b + 1].c.isWordChar: inc b
  d.selA = (c.page, a)
  d.selB = (c.page, b + 1)

proc selectAll(d: Doc) =
  for i in 0 ..< d.pages.len:
    if d.pages[i].textState == 0:
      d.pages[i].textState = 1
      send(d, "text\t" & $i)
  d.selA = (0, 0)
  d.selB = (d.pages.high, int.high div 2)
  invalidate(d)

# ---------------------------------------------------------------------------------------------------------------
# Saving and other apps

proc fileUri(path: string): string = "file://" & encodeUrl(path, usePlus = false).replace("%2F", "/")

proc fileName(d: Doc): string =
  result = d.url.parseUri.path.extractFilename.decodeUrl
  if result.len == 0: result = "document"
  if not result.toLowerAscii.endsWith(".pdf"): result.add ".pdf"

proc save(d: Doc) =
  if d.path.len == 0: return
  if not d.path.startsWith(cacheDir):
    d.status = "Saved in " & d.path
    invalidate(d)
    return
  let dir = downloadsDir()
  let (stem, ext) = (d.fileName.changeFileExt(""), ".pdf")
  var target = dir / d.fileName
  var n = 1
  while fileExists(target):
    target = dir / (stem & " (" & $n & ")" & ext)
    inc n
  try:
    createDir(dir)
    copyFile(d.path, target)
    d.status = "Saved as " & target.extractFilename
  except CatchableError:
    d.status = "Couldn't save: " & getCurrentExceptionMsg()
  invalidate(d)

proc openElsewhere(d: Doc) =
  if d.path.len > 0: discard g_app_info_launch_default_for_uri(fileUri(d.path).cstring, nil, nil)

proc showContents(d: Doc) =
  if d.outline.len == 0:
    alert("This PDF has no contents list")
    return
  let col = kit.column()
  for i in 0 ..< d.outline.len:
    closureScope:
      let target = d.outline[i]
      let l = kit.label(repeat("    ", target.level) & target.title)
      kit.`maxChars=`(l, 48)
      kit.add(col, kit.item(l, onClick = proc () =
        if docOf(d.tab) == d: d.goToPage(target.page, target.y)))
  showSidePanel("Contents", kit.scroll(col))

# ---------------------------------------------------------------------------------------------------------------
# Input

proc contextMenu(d: Doc) =
  var items: seq[kit.MenuItem]
  if d.hasSelection: items.add kit.menuItem("Copy", proc () = copySelection(d), shortcut = "Ctrl+C")
  items.add kit.menuItem("Select all", proc () = selectAll(d), shortcut = "Ctrl+A")
  items.add kit.menuSeparator()
  items.add kit.menuItem("Save PDF", proc () = save(d), shortcut = "Ctrl+S")
  items.add kit.menuItem("Open in another app", proc () = openElsewhere(d))
  if d.outline.len > 0: items.add kit.menuItem("Contents", proc () = showContents(d))
  items.add kit.menuSeparator()
  items.add kit.menuItem("Zoom in", proc () = zoomStep(d, true), shortcut = "Ctrl++")
  items.add kit.menuItem("Zoom out", proc () = zoomStep(d, false), shortcut = "Ctrl+-")
  items.add kit.menuItem("Fit width", proc () = d.setZoom(d.fitZoom, true), shortcut = "Ctrl+0")
  kit.popupMenu(items)

proc onPointer(t: Tab, e: kit.PointerEvent): bool =
  let d = docOf(t)
  if d == nil: return false
  if d.state != dsReady: return true
  case e.kind
  of kit.pkDown:
    kit.focus(browser.page)
    if e.button == 3:
      contextMenu(d)
      return true
    if e.button == 8: (goBack(); return true)
    if e.button == 9: (goForward(); return true)
    if e.button != 1 and e.button != 2: return true
    d.downAt = (e.x, e.y)
    if e.button == 2: return true
    let bar = d.barAt(e.x, e.y)
    if bar != 0:
      # On the thumb: drag it from where it was grabbed. Elsewhere on the track: the thumb jumps there.
      let th = d.barThumb(bar)
      let tr = d.barTrack(bar)
      let along = if bar == 1: e.y - tr.y0 else: e.x - tr.x0
      d.barDrag = bar
      d.barGrab = if along >= th.start and along <= th.start + th.length: along - th.start else: th.length / 2
      d.scrollFromBar(bar, along - d.barGrab)
      invalidate(d)
      return true
    let c = d.caretFrom(e.x, e.y)
    if e.clicks >= 2 and c.page >= 0 and d.pages[c.page].textState == 2:
      d.selectWord(c, e.clicks >= 3)
      d.dragging = false
    elif (e.mods and modShift) != 0 and d.hasSelection:
      d.selB = c
      d.dragging = true
    else:
      d.selA = c
      d.selB = c
      d.dragging = true
    invalidate(d)
  of kit.pkMove:
    if d.barDrag != 0:
      if (e.buttons and 1) == 0:
        d.barDrag = 0
        invalidate(d)
      else:
        let tr = d.barTrack(d.barDrag)
        d.scrollFromBar(d.barDrag, (if d.barDrag == 1: e.y - tr.y0 else: e.x - tr.x0) - d.barGrab)
      return true
    let bar = if d.dragging: 0 else: d.barAt(e.x, e.y)
    if bar != d.barHover:
      d.barHover = bar
      invalidate(d)
    if bar != 0:
      kit.`cursor=`(browser.page, "default")
      return true
    if d.dragging and (e.buttons and 1) != 0:
      d.selB = d.caretFrom(e.x, e.y)
      # Dragging past the top or bottom edge scrolls.
      let (_, vh, _) = pageSize()
      if e.y < 0: d.scrollTo(d.scrollY + e.y)
      elif e.y > vh.float: d.scrollTo(d.scrollY + e.y - vh.float)
      invalidate(d)
    else:
      let l = d.linkAt(e.x, e.y)
      let cursor = if l.page >= 0 or l.uri.len > 0: "pointer" elif d.charAt(e.x, e.y).page >= 0: "text" else: "default"
      kit.`cursor=`(browser.page, cursor)
      t.hovered = l.uri
      refreshChrome()
  of kit.pkUp:
    if d.barDrag != 0:
      d.barDrag = 0
      d.barHover = d.barAt(e.x, e.y)
      invalidate(d)
      return true
    let wasDrag = d.dragging
    d.dragging = false
    let still = abs(e.x - d.downAt.x) < 4 and abs(e.y - d.downAt.y) < 4
    if still and (e.button == 1 or e.button == 2):
      let l = d.linkAt(e.x, e.y)
      if l.uri.len > 0:
        if e.button == 2 or (e.mods and modCtrl) != 0: discard openTab(l.uri, focus = false, index = tabs.find(t) + 1)
        else: t.loadUrl(l.uri)
        return true
      if l.page >= 0:
        d.goToPage(l.page, l.y)
        return true
    if wasDrag and d.hasSelection: discard
  of kit.pkLeave:
    if d.barHover != 0 and d.barDrag == 0:
      d.barHover = 0
      invalidate(d)
    if t.hovered.len > 0:
      t.hovered = ""
      refreshChrome()
  of kit.pkCancel:
    d.dragging = false
    d.barDrag = 0
  true

proc onWheel(t: Tab, e: kit.WheelEvent): bool =
  let d = docOf(t)
  if d == nil: return false
  if d.state != dsReady: return true
  if (e.mods and modCtrl) != 0:
    if e.dy != 0: zoomStep(d, e.dy < 0, e.x, e.y)
    return true
  let s = 53.0 * ratio()
  var dx = e.dx * s
  var dy = e.dy * s
  if (e.mods and modShift) != 0 and dx == 0: swap(dx, dy)
  d.scrollX += dx
  d.scrollTo(d.scrollY + dy)
  true

proc onKey(t: Tab, e: kit.KeyEvent): bool =
  let d = docOf(t)
  if d == nil: return false
  if not e.down or d.state != dsReady: return true
  let (_, vh, _) = pageSize()
  let ctrl = (e.mods and modCtrl) != 0
  let shift = (e.mods and modShift) != 0
  let line = 40.0 * ratio()
  if ctrl:
    # Punctuation by the character it types (its key code depends on the backend), keypad keys by GDK keyval.
    let ch = if e.text in 0x20'u32 .. 0x7e'u32: char(e.text) else: '\0'
    if ch in {'=', '+'} or e.keyval == 0xffab: zoomStep(d, true)       # Ctrl+= / Ctrl++ / keypad +
    elif ch == '-' or e.keyval == 0xffad: zoomStep(d, false)            # Ctrl+- / keypad -
    elif ch == '0' or e.keyval == 0xffb0: d.setZoom(d.fitZoom, true)    # Ctrl+0
    else:
      case e.code
      of 0x43: copySelection(d)                  # Ctrl+C
      of 0x41: selectAll(d)                      # Ctrl+A
      of 0x53: save(d)                           # Ctrl+S
      of 0x24: d.scrollTo(0)                     # Ctrl+Home
      of 0x23: d.scrollTo(d.totalHeight)         # Ctrl+End
      else: return false
    return true
  case e.code
  of 0x28: d.scrollTo(d.scrollY + line)                                  # Down
  of 0x26: d.scrollTo(d.scrollY - line)                                  # Up
  of 0x22: d.scrollTo(d.scrollY + vh.float * 0.9)                        # Page Down
  of 0x21: d.scrollTo(d.scrollY - vh.float * 0.9)                        # Page Up
  of 0x20: d.scrollTo(d.scrollY + (if shift: -1.0 else: 1.0) * vh.float * 0.9)  # Space
  of 0x24: d.scrollTo(0)                                                 # Home
  of 0x23: d.scrollTo(d.totalHeight)                                     # End
  of 0x25:                                                               # Left
    if d.totalWidth > pageSize().width.float: d.scrollTo(d.scrollY, max(0.0, d.scrollX - line))
    else: d.goToPage(d.currentPage - 1)
  of 0x27:                                                               # Right
    if d.totalWidth > pageSize().width.float: d.scrollTo(d.scrollY, d.scrollX + line)
    else: d.goToPage(d.currentPage + 1)
  of 0x1B:                                                               # Esc
    if d.hasSelection:
      d.selB = d.selA
      invalidate(d)
    else: return false
  else: discard
  true

proc onFind(t: Tab, op, query: string, matchCase: bool): bool =
  let d = docOf(t)
  if d == nil: return false
  case op
  of "find":
    d.findShown = true
    if matchCase != d.matchCase:
      d.matchCase = matchCase
      for i in 0 ..< d.pages.len:
        if d.pages[i].textState == 2: buildFindText(d, i)
    d.query = query
    if d.state == dsReady:
      for i in 0 ..< d.pages.len:
        if d.pages[i].textState == 0:
          d.pages[i].textState = 1
          send(d, "text\t" & $i)
    rematch(d)
    reportFind(d)
    scrollToMatch(d)
  of "next", "previous":
    if d.matches.len > 0:
      d.current = (d.current + (if op == "next": 1 else: d.matches.len - 1)) mod d.matches.len
      reportFind(d)
      scrollToMatch(d)
  of "end":
    d.findShown = false
    d.matches.setLen 0
    d.current = -1
  else: discard
  invalidate(d)
  true

# ---------------------------------------------------------------------------------------------------------------

proc buildBar() =
  let withDoc = proc (f: proc (d: Doc)): proc () =
    result = proc () =
      let t = currentTab()
      let d = if t == nil: nil else: docOf(t)
      if d != nil: f(d)
  pageEntry = kit.entry("", "1", onSubmit = proc (text: string) =
    let t = currentTab()
    let d = if t == nil: nil else: docOf(t)
    if d == nil: return
    try: d.goToPage(parseInt(text.strip) - 1) except ValueError: discard
    d.lastPage = 0
    refreshBar()
    focusPage())
  kit.`maxChars=`(pageEntry, 4)
  pageCount = kit.label("")
  zoomLabel = kit.label("100%")
  discard kit.sized(zoomLabel, 48)
  statusLabel = kit.label("")
  fitButton = kit.button("Fit width", withDoc(proc (d: Doc) = d.setZoom(d.fitZoom, true)))
  bar = kit.row(
    kit.iconButton("toc", "Contents", withDoc(showContents)),
    kit.label("Page"), pageEntry, pageCount,
    kit.iconButton("remove", "Zoom out (Ctrl+-)", withDoc(proc (d: Doc) = zoomStep(d, false))),
    zoomLabel,
    kit.iconButton("add", "Zoom in (Ctrl++)", withDoc(proc (d: Doc) = zoomStep(d, true))),
    fitButton,
    kit.spacer(), statusLabel,
    kit.iconButton("download", "Save PDF (Ctrl+S)", withDoc(save)),
    kit.iconButton("open_in_new", "Open in another app", withDoc(openElsewhere)))
  bar.spacing = 6
  kit.addClass(bar, "webby-pdf-bar")
  kit.`visible=`(bar, false)
  kit.add(barSlot, bar)

proc install*() =
  cacheDir = getTempDir() / ("webby-pdf-" & $getCurrentProcessId())
  windowHooks.add proc () =
    buildBar()
    loadCss(".webby-pdf-bar { border-bottom: 1px solid alpha(currentColor, 0.15); padding: 2px 6px; }\n" &
      ".webby-pdf-on { font-weight: bold; }")
  pageFrameHooks.add frameFor
  pagePointerHooks.add onPointer
  pageWheelHooks.add onWheel
  pageKeyHooks.add onKey
  pageFindHooks.add onFind
  pageResizeHooks.add proc () =
    let t = currentTab()
    let d = if t == nil: nil else: docOf(t)
    if d == nil or d.state != dsReady: return
    if d.fitWidth:
      d.zoom = d.fitZoom
      layout(d)
    d.clampScroll
    pumpRequests(d)
    invalidate(d)
  pageScriptHooks.add proc (t: Tab): string =
    if docOf(t) != nil and docOf(t).url == t.url: ""
    else: detectScript.replace("PREFIX", $(%t.messagePrefix))
  pageMessageHooks.add onPageData
  pageMessageHooks.add proc (t: Tab, msg: string): bool =
    if msg != "{\"type\":\"webbyPdf\"}": return false
    show(t)
    true
  tabStateHooks.add proc (t: Tab) =
    let d = docOf(t)
    if d != nil and d.url != t.url: closeDoc(t)
    if t.props.getOrDefault("pdfGaveUp").len > 0 and t.props["pdfGaveUp"] != t.url: t.props.del "pdfGaveUp"
    if t.title == viewerTitle: show(t)
  activeTabHooks.add proc (t: Tab) =
    let d = docOf(t)
    if d != nil:
      pumpRequests(d)
      d.dirty = true
    refreshBar()
  tabClosedHooks.add proc (t: Tab) = closeDoc(t)
  var lastSerial = 0'u64
  pumpHooks.add proc () =
    if webby_downloads_serial == nil: return
    let s = webby_downloads_serial()
    if s == lastSerial: return
    lastSerial = s
    for d in docs.values:
      if d.downloadId != 0: checkDownload(d)
  shutdownHooks.add proc () =
    for d in docs.values: stopHelper(d)
    try: removeDir(cacheDir) except CatchableError: discard
