## Uploading a bug report to Jam (jam.dev) as a screenshot or video Jam, with the page's console, network and user
## events on its timeline. This is the API Jam's own CLI (`jam create jam`) uses, with a personal access token
## (jam_pat_..., made at https://jam.dev/s/settings/mcp with the mcp:read and mcp:write scopes):
##
##   GET  api.jam.dev/whoami                      the token's team
##   POST graphql.jam.dev/graphql bulkRegisterMedia   one upload URL per file (a Google Cloud Storage resumable
##                                                session, filled with PUTs of Content-Range chunks)
##   POST graphql.jam.dev/graphql createScreenshot | createVideo   the Jam, pointing at the uploaded media; the
##                                                events go up as one more file (an rrweb-style JSON array)
##
## Requests go through nimkit's HTTP service (GIO on the desktop), never std/httpclient.

import std/[json, strutils, times]
import nimkit/services

const
  apiUrl {.strdefine: "jamApiUrl".} = "https://api.jam.dev"
  graphqlUrl {.strdefine: "jamGraphqlUrl".} = "https://graphql.jam.dev/graphql"
  chunkBytes = 16 * 256 * 1024   ## GCS wants chunks in multiples of 256 KiB; 4 MiB each keeps a request short
  shareUrl* = "https://jam.dev/c/"
  tokenSite* = "https://jam.dev/s/settings/mcp"
  ## Jam lets a personal access token make media and Jams only from its CLI, which says so with these headers;
  ## without them bulkRegisterMedia answers 403 "You are not authorized to perform this action".
  clientHeaders* = @[("x-jam-origin", "native_cli"), ("x-jam-cli-version", "1.31.1")]

type
  Upload* = object
    token*: string
    video*: bool                 ## a video Jam (WebM in `media`) or a screenshot Jam (PNG in `media`)
    media*, mediaType*: string
    poster*: string              ## video: a PNG of its first frame
    title*, description*, url*: string
    width*, height*: int         ## the screenshot's or video's size in pixels
    durationMs*: int
    viewport*: tuple[width, height: int]  ## the page's size in CSS pixels
    browser*, browserVersion*, os*, osVersion*: string
    events*: JsonNode            ## an array of Jam events (see events.nim), or nil

  Done* = proc (ok: bool, jamUrl, error: string)

proc answer(r: Response): string =
  ## What Jam said, for error messages: its error text if it gave one, else the start of the body.
  try:
    let j = parseJson(r.body)
    if j{"error_description"} != nil: return j{"error_description"}.getStr
    if j{"errors"} != nil and j{"errors"}.len > 0: return j{"errors"}[0]{"message"}.getStr
  except CatchableError: discard
  r.body[0 ..< min(r.body.len, 200)].strip

proc graphqlErrors(j: JsonNode): string =
  if j.kind != JObject or j{"errors"} == nil: return ""
  var messages: seq[string]
  for e in j{"errors"}.getElems: messages.add e{"message"}.getStr("error")
  messages.join("; ")

proc call(token, op, query: string, variables: JsonNode, done: proc (data: JsonNode, error: string)) =
  let body = $(%*{"operationName": op, "query": query, "variables": variables})
  request("POST", graphqlUrl & "?op=" & op, proc (r: Response) =
    if r.status == 0: done(nil, r.error); return
    if r.status in [401, 403]:
      done(nil, op & ": Jam refused the token (HTTP " & $r.status & "): " & answer(r))
      return
    let j = try: parseJson(r.body) except CatchableError: nil
    if j == nil: done(nil, op & ": Jam answered HTTP " & $r.status & " " & answer(r)); return
    let errors = graphqlErrors(j)
    if errors.len > 0 or j{"data"} == nil or j{"data"}.kind != JObject:
      done(nil, op & ": " & (if errors.len > 0: errors else: "Jam answered HTTP " & $r.status))
    else: done(j{"data"}, ""),
    headers = @[("Authorization", "Bearer " & token), ("Content-Type", "application/json"),
                ("Accept", "application/json")] & clientHeaders, body = body)

proc whoami(token: string, done: proc (teamId, error: string)) =
  request("GET", apiUrl & "/whoami", proc (r: Response) =
    if r.status == 0: done("", r.error); return
    if r.status in [401, 403]:
      done("", "Jam refused the token (HTTP " & $r.status & "): " & answer(r))
      return
    try:
      let team = parseJson(r.body){"data"}{"attributes"}{"team"}{"id"}.getStr
      if team.len > 0: done(team, "") else: done("", "Jam's /whoami named no team (HTTP " & $r.status & ")")
    except CatchableError: done("", "Jam's /whoami answered HTTP " & $r.status),
    headers = @[("Authorization", "Bearer " & token), ("Accept", "application/json")])

proc putChunks(url: string, extra: seq[(string, string)], data, contentType: string, offset: int,
               done: proc (error: string)) =
  ## The bytes from `offset` on, one chunk per PUT; GCS answers 308 until it has them all, then 200 or 201.
  let last = min(offset + chunkBytes, data.len)
  var headers = extra
  headers.add ("Content-Type", contentType)
  headers.add ("Content-Range", "bytes " & $offset & "-" & $(last - 1) & "/" & $data.len)
  request("PUT", url, proc (r: Response) =
    if r.status == 0: done("Upload failed: " & r.error)
    elif r.status in [200, 201]: done("")
    elif r.status == 308:
      # Range: bytes=0-N says how much is stored; without it, nothing is.
      var next = 0
      let range = r.header("range")
      if range.startsWith("bytes=") and '-' in range:
        try: next = parseInt(range.split('-')[^1]) + 1 except ValueError: next = last
      if next <= offset: done("Upload stalled at " & $offset & " of " & $data.len & " bytes")
      else: putChunks(url, extra, data, contentType, next, done)
    else: done("Upload failed (HTTP " & $r.status & "): " & r.body[0 ..< min(r.body.len, 200)]),
    headers = headers, body = data[offset ..< last])

const registerQuery = """
mutation bulkRegisterMedia($teamId: String!, $items: [MediaRegistrationItemInput!]!) {
  bulkRegisterMedia(teamId: $teamId, items: $items) {
    items { key uploadUrl extraHeaders { name value } media { id } }
  }
}"""

proc uploadMedia(token, teamId: string, files: seq[tuple[kind, contentType, data: string]],
                 done: proc (ids: seq[string], error: string)) =
  var items = newJArray()
  for i, f in files:
    items.add %*{"key": $i, "type": f.kind, "contentType": f.contentType, "uncompressedBytes": f.data.len,
                 "chunked": true}
  call(token, "bulkRegisterMedia", registerQuery, %*{"teamId": teamId, "items": items}, proc (data: JsonNode, error: string) =
    if data == nil: done(@[], error); return
    var slots: seq[JsonNode] = newSeq[JsonNode](files.len)
    for item in data{"bulkRegisterMedia"}{"items"}.getElems:
      let k = (try: parseInt(item{"key"}.getStr) except ValueError: -1)
      if k in 0 ..< files.len: slots[k] = item
    for s in slots:
      if s == nil: done(@[], "Jam gave no upload address"); return
    var ids: seq[string]
    proc next(i: int) =
      if i == files.len: done(ids, ""); return
      var extra: seq[(string, string)]
      for h in slots[i]{"extraHeaders"}.getElems: extra.add (h{"name"}.getStr, h{"value"}.getStr)
      putChunks(slots[i]{"uploadUrl"}.getStr, extra, files[i].data, files[i].contentType, 0, proc (error: string) =
        if error.len > 0: done(@[], error); return
        ids.add slots[i]{"media"}{"id"}.getStr
        next(i + 1))
    next(0))

proc proseMirror*(text: string): string =
  ## Jam keeps descriptions as ProseMirror JSON: a paragraph per line here, "- " lines as a bullet list.
  var content = newJArray()
  var bullets: JsonNode = nil
  proc paragraph(s: string): JsonNode =
    if s.len == 0: %*{"type": "paragraph"} else: %*{"type": "paragraph", "content": [{"type": "text", "text": s}]}
  for raw in text.strip.splitLines:
    let line = raw.strip(leading = false)
    if line.startsWith("- "):
      if bullets == nil:
        bullets = %*{"type": "bulletList", "content": []}
        content.add bullets
      bullets["content"].add %*{"type": "listItem", "content": [paragraph(line[2 .. ^1])]}
    else:
      bullets = nil
      content.add paragraph(line)
  if content.len == 0: content.add paragraph("")
  $(%*{"type": "doc", "content": content})

proc createJam(u: Upload, teamId: string, ids: seq[string], eventsId: string, withEvents: bool, done: Done) =
  let op = if u.video: "createVideo" else: "createScreenshot"
  let input = if u.video: "CreateVideoInput" else: "CreateScreenshotInput"
  let query = "mutation " & op & "($jam: " & input & "!, $comment: BasicCommentInput!) {\n  " & op &
    "(jam: $jam, comment: $comment) { __typename ... on BaseJam { id } }\n}"
  var jam = %*{
    "teamId": teamId,
    "clientInfo": {
      "browser": {"name": u.browser, "version": u.browserVersion},
      "os": {"name": u.os, "version": u.osVersion},
      "screenDimensions": {"width": u.width, "height": u.height},
      "jamClient": {"version": u.browserVersion},
      "other": []},
    "url": u.url,
    "title": u.title,
    "timezoneLocation": now().timezone.name}
  if u.description.strip.len > 0: jam["description"] = %proseMirror(u.description)
  if withEvents and eventsId.len > 0: jam["eventsId"] = %eventsId
  if u.video:
    jam["data"] = %*{"mediaId": ids[0], "posterImageMediaId": ids[1], "durationMs": u.durationMs, "width": u.width,
      "height": u.height, "viewport": {"width": u.viewport.width, "height": u.viewport.height},
      "recordingSurface": "browser", "micEnabled": false}
  else:
    jam["data"] = %*{"mediaId": ids[0]}
  call(u.token, op, query, %*{"jam": jam, "comment": {"message": "", "attachments": []}}, proc (data: JsonNode, error: string) =
    if data == nil:
      # A screenshot Jam may not take events on every Jam API version; it still beats no Jam.
      if withEvents and eventsId.len > 0 and "eventsId" in error:
        createJam(u, teamId, ids, eventsId, false, done)
      else: done(false, "", error)
      return
    let id = data{op}{"id"}.getStr
    if id.len == 0: done(false, "", "Jam made no Jam")
    else: done(true, shareUrl & id, ""))

proc upload*(u: Upload, progress: proc (text: string), done: Done) =
  if u.token.len == 0: done(false, "", "No Jam token"); return
  progress("Checking the Jam token…")
  whoami(u.token, proc (teamId, error: string) =
    if teamId.len == 0: done(false, "", error); return
    var files = @[(kind: (if u.video: "Video" else: "Screenshot"), contentType: u.mediaType, data: u.media)]
    if u.video: files.add (kind: "Screenshot", contentType: "image/png", data: u.poster)
    let hasEvents = u.events != nil and u.events.len > 0
    if hasEvents: files.add (kind: "Events", contentType: "application/json", data: $u.events)
    var size = 0
    for f in files: size += f.data.len
    progress("Uploading " & formatSize(size, includeSpace = true) & "…")
    uploadMedia(u.token, teamId, files, proc (ids: seq[string], error: string) =
      if error.len > 0: done(false, "", error); return
      progress("Making the Jam…")
      createJam(u, teamId, ids, (if hasEvents: ids[^1] else: ""), true, done)))
