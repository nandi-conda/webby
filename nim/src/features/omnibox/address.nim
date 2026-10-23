## What the address bar loads for typed text, shared by the desktop and
## Android front ends.

import std/[sequtils, strutils, uri]

proc schemeLen(text: string): int =
  ## The length of a leading "scheme:" ([a-zA-Z][a-zA-Z0-9+.-]*:), or 0.
  if text.len == 0 or text[0] notin Letters: return 0
  for i in 1 ..< text.len:
    if text[i] == ':': return i + 1
    if text[i] notin Letters + Digits + {'+', '.', '-'}: return 0
  0

proc isTld(s: string): bool = s.len in 2 .. 63 and s.allCharsInSet(Letters)

proc looksLikeAddress(text: string): bool =
  if text.len == 0 or text.find(Whitespace) >= 0: return false
  # "https://…", "about:blank", "file:///…"; but "localhost:8080" is a host with a port, not a scheme.
  let s = schemeLen(text)
  let colon = text.find(':')
  let hostWithPort = colon > 0 and colon + 1 < text.len and text[colon + 1] in Digits
  if s > 0 and not hostWithPort:
    return "://" in text or text[0 ..< s - 1].toLowerAscii in ["about", "data", "file", "mailto", "javascript",
      "view-source"]
  var authority = text
  for i, c in text:
    if c in {'/', '?', '#'}:
      authority = text[0 ..< i]
      break
  if '@' in authority: authority = authority[authority.rfind('@') + 1 .. ^1]
  # host[:port], the host a name or an [IPv6] literal.
  var host = authority
  if authority.startsWith("["):
    let close = authority.find(']')
    if close < 0: return false
    host = authority[0 .. close]
    let rest = authority[close + 1 .. ^1]
    if not host[1 ..< ^1].allCharsInSet(HexDigits + {':', '.'}) or host.len < 3: return false
    if rest.len > 0 and not (rest[0] == ':' and rest.len in 2 .. 6 and rest[1 .. ^1].allCharsInSet(Digits)):
      return false
    return true
  let c = authority.rfind(':')
  if c >= 0:
    let port = authority[c + 1 .. ^1]
    if port.len notin 1 .. 5 or not port.allCharsInSet(Digits): return false
    host = authority[0 ..< c]
  if host.len == 0 or host.find({':', '/', '?', '#', '@'} + Whitespace) >= 0: return false
  host = host.toLowerAscii
  if host == "localhost": return true
  let parts = host.split('.')
  if parts.len == 4 and parts.allIt(it.len in 1 .. 3 and it.allCharsInSet(Digits)): return true
  # A dot-separated name ending in a letters-only TLD: "example.com", "news.ycombinator.com".
  var labels = parts
  if labels.len > 1 and labels[^1].len == 0: labels.setLen labels.len - 1   # a trailing dot
  labels.len >= 2 and isTld(labels[^1]) and
    labels[0 ..< ^1].allIt(it.len > 0 and it.allCharsInSet({'a'..'z'} + Digits + {'-'}))

proc addressToUrl*(input: string): string =
  ## What the address bar loads for `input`: the address itself when it looks like one, otherwise a Google search.
  let text = input.strip
  if looksLikeAddress(text): text else: "https://www.google.com/search?q=" & encodeUrl(text, usePlus = true)
