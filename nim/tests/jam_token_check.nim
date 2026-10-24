## Looks at the Jam token saved in webby's vault (⋮ > Jam settings) against Jam's API, step by step, printing each
## answer's status and the start of its body (never the token). For diagnosing "Jam refused the token".
##
## Usage (with the desktop session's D-Bus for the keyring): pixi run nim/tests/jam_token_check

import std/[json, os, strutils, sugar]
from nimkit/backend/gtk as nkgtk import nil   # nimkit's services on GLib: HTTP over GIO, timers
import nimkit/services
import ../src/features/passwords/vault
import ../src/features/bugreport/jam

proc g_main_loop_new(ctx: pointer, running: cint): pointer {.importc, cdecl.}
proc g_main_loop_run(loop: pointer) {.importc, cdecl.}
proc g_main_loop_quit(loop: pointer) {.importc, cdecl.}

let loop = g_main_loop_new(nil, 0)
let token = if getEnv("JAM_TOKEN").len > 0: getEnv("JAM_TOKEN") else: openVault(readOnly = true).secret("jam-token")
echo "token: ", token.len, " chars, starts ", token[0 ..< min(8, token.len)], ", whitespace inside: ",
  token != token.strip or ' ' in token or '\n' in token

proc show(label: string, r: Response) =
  echo label, ": HTTP ", r.status, " ", r.error, "\n  ", r.body[0 ..< min(r.body.len, 400)].replace("\n", " ")

let auth = ("Authorization", "Bearer " & token.strip)
var teamId = ""
let gql = $(%*{"query": "query { __typename }"})
var steps: seq[proc (next: proc ())]
steps.add proc (next: proc ()) =
  request("GET", "https://api.jam.dev/whoami", proc (r: Response) =
    show("whoami", r)
    try: teamId = parseJson(r.body){"data"}{"attributes"}{"team"}{"id"}.getStr except CatchableError: discard
    next(), @[auth])
steps.add proc (next: proc ()) =
  request("GET", "https://api.jam.dev/whoami", proc (r: Response) = (show("whoami + Accept json", r); next()),
    @[auth, ("Accept", "application/json")])
steps.add proc (next: proc ()) =
  request("POST", "https://graphql.jam.dev/graphql", proc (r: Response) = (show("graphql", r); next()),
    @[auth, ("Content-Type", "application/json")], gql)
steps.add proc (next: proc ()) =
  request("POST", "https://graphql.jam.dev/graphql", proc (r: Response) = (show("graphql + x-jam-origin", r); next()),
    @[auth, ("Content-Type", "application/json"), ("x-jam-origin", "native_cli")], gql)

# Registering a media slot makes no Jam; it shows whether the token may write, and which headers it needs.
proc register(): string =
  $(%*{"operationName": "bulkRegisterMedia", "variables": {"teamId": teamId, "items": [{"key": "0", "type": "Screenshot",
    "contentType": "image/png", "uncompressedBytes": 67, "chunked": true}]}, "query": "mutation bulkRegisterMedia($teamId: String!, $items: [MediaRegistrationItemInput!]!) { bulkRegisterMedia(teamId: $teamId, items: $items) { items { key media { id } } } }"})
for (label, extra) in [("bulkRegisterMedia", newSeq[(string, string)]()), ("bulkRegisterMedia + CLI headers", clientHeaders)]:
  capture label, extra:
    steps.add proc (next: proc ()) =
      request("POST", "https://graphql.jam.dev/graphql?op=bulkRegisterMedia", proc (r: Response) = (show(label, r); next()),
        @[auth, ("Content-Type", "application/json")] & extra, register())

# What GCS says to an empty file's upload ("bytes 0--1/0", as webby sent before it refused empty files).
steps.add proc (next: proc ()) =
  let body = $(%*{"operationName": "bulkRegisterMedia", "variables": {"teamId": teamId, "items": [{"key": "0",
    "type": "Screenshot", "contentType": "image/png", "uncompressedBytes": 0, "chunked": true}]},
    "query": "mutation bulkRegisterMedia($teamId: String!, $items: [MediaRegistrationItemInput!]!) { bulkRegisterMedia(teamId: $teamId, items: $items) { items { key uploadUrl extraHeaders { name value } } } }"})
  request("POST", "https://graphql.jam.dev/graphql?op=bulkRegisterMedia", proc (r: Response) =
    let items = try: parseJson(r.body){"data"}{"bulkRegisterMedia"}{"items"} except CatchableError: nil
    if items == nil or items.len == 0:
      show("register empty file", r)
      next()
      return
    let item = items[0]
    var headers: seq[(string, string)]
    for h in item{"extraHeaders"}.getElems: headers.add (h{"name"}.getStr, h{"value"}.getStr)
    headers.add ("Content-Type", "image/png")
    headers.add ("Content-Range", "bytes 0--1/0")
    request("PUT", item{"uploadUrl"}.getStr, proc (r: Response) = (show("PUT empty file, bytes 0--1/0", r); next()),
      headers, ""),
    @[auth, ("Content-Type", "application/json")] & clientHeaders, body)

proc run(i: int) =
  if i == steps.len: g_main_loop_quit(loop)
  else: steps[i](proc () = run(i + 1))
run(0)
g_main_loop_run(loop)
