## Markdown for the summary panel (app/lib/src/markdown_view.dart): the same block parser, which copes with
## half-written text so a streaming answer can be shown as it comes, and inline markup as Pango markup on GtkLabels.

import std/strutils
from std/unicode import validateUtf8
import ../../browser

type
  MdKind* = enum mdHeading, mdParagraph, mdListItem, mdQuote, mdCode, mdRule
  MdBlock* = object
    kind*: MdKind
    text*: string
    level*: int       ## heading level
    marker*: string   ## list item: "•" or "3."
    depth*: int       ## list item indent levels

proc leadingSpace(line: string): int =
  while result < line.len and line[result] in Whitespace: inc result

proc depthOf(indent: string): int = clamp(indent.replace("\t", "    ").len div 2, 0, 4)

proc parseHeading(trimmed: string, level: var int, text: var string): bool =
  var n = 0
  while n < trimmed.len and trimmed[n] == '#': inc n
  if n notin 1 .. 6 or n >= trimmed.len or trimmed[n] notin Whitespace: return false
  level = n
  text = trimmed[n .. ^1].strip.strip(leading = false, chars = {'#'}).strip
  true

proc isRule(line: string): bool =
  let s = line.strip
  if s.len == 0 or s[0] notin {'-', '*', '_'}: return false
  var count = 0
  for c in s:
    if c == s[0]: inc count
    elif c notin Whitespace: return false
  count >= 3

proc parseBullet(line: string, indent, text: var string): bool =
  let i = leadingSpace(line)
  var j: int
  if line.continuesWith("•", i): j = i + "•".len
  elif i < line.len and line[i] in {'-', '*', '+'}: j = i + 1
  else: return false
  if j >= line.len or line[j] notin Whitespace: return false
  indent = line[0 ..< i]
  text = line[j .. ^1].strip(trailing = false)
  true

proc parseNumbered(line: string, indent, number, text: var string): bool =
  let i = leadingSpace(line)
  var j = i
  while j < line.len and line[j] in Digits: inc j
  if j - i notin 1 .. 3 or j >= line.len or line[j] notin {'.', ')'}: return false
  if j + 1 >= line.len or line[j + 1] notin Whitespace: return false
  indent = line[0 ..< i]
  number = line[i ..< j]
  text = line[j + 1 .. ^1].strip(trailing = false)
  true

proc parseMarkdown*(source: string): seq[MdBlock] =
  ## Splits `source` into blocks. An unclosed code fence runs to the end; unclosed inline markers stay as they are.
  var paragraph, quote: seq[string]
  template flush() =
    if paragraph.len > 0: result.add MdBlock(kind: mdParagraph, text: paragraph.join(" "))
    if quote.len > 0: result.add MdBlock(kind: mdQuote, text: quote.join(" "))
    paragraph.setLen 0
    quote.setLen 0
  let lines = source.replace("\r\n", "\n").split('\n')
  var i = 0
  while i < lines.len:
    let line = lines[i]
    let trimmed = line.strip
    var level, depth: int
    var text, indent, number: string
    if trimmed.startsWith("```"):
      flush()
      var code: seq[string]
      inc i
      while i < lines.len and not lines[i].strip.startsWith("```"):
        code.add lines[i]
        inc i
      result.add MdBlock(kind: mdCode, text: code.join("\n").strip(leading = false))
    elif trimmed.len == 0:
      flush()
    elif parseHeading(trimmed, level, text):
      flush()
      result.add MdBlock(kind: mdHeading, level: level, text: text)
    elif isRule(line):
      flush()
      result.add MdBlock(kind: mdRule)
    elif parseBullet(line, indent, text):
      flush()
      result.add MdBlock(kind: mdListItem, marker: "•", text: text, depth: depthOf(indent))
    elif parseNumbered(line, indent, number, text):
      flush()
      result.add MdBlock(kind: mdListItem, marker: number & ".", text: text, depth: depthOf(indent))
    elif trimmed.startsWith(">"):
      if paragraph.len > 0: flush()
      var q = trimmed[1 .. ^1]
      if q.startsWith(" "): q = q[1 .. ^1]
      quote.add q
    elif paragraph.len == 0 and quote.len == 0 and result.len > 0 and result[^1].kind == mdListItem and
        line[0] in Whitespace:
      # A plain line right after a list item continues that item.
      result[^1].text.add " " & trimmed
    else:
      if quote.len > 0: flush()
      paragraph.add trimmed
    inc i
  flush()

# ---------------------------------------------------------------------------------------------------------------
# Inline markup: **bold**, __bold__, `code`, *italic*, _italic_, ~~strike~~, [text](url). The same rules as the Dart
# regex, matched by hand (leftmost match, alternatives in order).

proc isWord(c: char): bool = c in IdentChars

proc emphasisEnd(text: string, start: int, mark: char): int =
  ## Where a single-`mark` emphasis opened at `start` closes, or -1.
  if start > 0 and (text[start - 1].isWord or text[start - 1] == mark): return -1
  if start + 1 >= text.len or text[start + 1] in Whitespace: return -1
  var j = start + 2
  while j < text.len:
    if text[j] == mark and text[j - 1] notin Whitespace and (j + 1 >= text.len or not text[j + 1].isWord):
      return j
    inc j
  -1

const anchorPrefix* = "webby-anchor:"  ## the href an anchor link gets in a label; the rest is the page words

proc anchorWords*(target: string): string =
  ## The page words an anchor link (`[§](#words)`) points at, with URL escapes and stray quotes undone.
  var i = 0
  while i < target.len:
    if target[i] == '%':
      # A run of %XX escapes, decoded together (multi-byte UTF-8); kept as it is if it isn't valid UTF-8.
      var j = i
      var bytes = ""
      while j + 2 < target.len and target[j] == '%' and target[j + 1] in HexDigits and target[j + 2] in HexDigits:
        bytes.add chr(parseHexInt(target[j + 1 .. j + 2]))
        j += 3
      if bytes.len > 0 and validateUtf8(bytes) < 0:
        result.add bytes
        i = j
        continue
      if bytes.len > 0:
        result.add target[i ..< j]
        i = j
        continue
    result.add target[i]
    inc i
  const quotes = ["\"", "“", "”", "‘", "’"]
  var changed = true
  while changed:
    changed = false
    result = result.strip
    for q in quotes:
      if result.startsWith(q): (result = result[q.len .. ^1]; changed = true)
      if result.endsWith(q): (result = result[0 ..< result.len - q.len]; changed = true)
  result = result.splitWhitespace.join(" ")

const codeSpan = "<span font_family=\"monospace\" background=\"#808080\" bgalpha=\"22%\">"

proc inlineMarkup*(text: string): string =
  ## `text` with its inline markdown as Pango markup (escaped otherwise).
  var plain = ""
  template emit(s: string) =
    if plain.len > 0:
      result.add escapeMarkup(plain)
      plain.setLen 0
    result.add s
  var i = 0
  while i < text.len:
    let c = text[i]
    if (c == '*' or c == '_') and i + 1 < text.len and text[i + 1] == c:
      let close = text.find(text[i .. i + 1], i + 3)
      if close >= 0:
        emit "<b>" & inlineMarkup(text[i + 2 ..< close]) & "</b>"
        i = close + 2
        continue
    if c == '`':
      let close = text.find('`', i + 1)
      if close > i + 1:
        emit codeSpan & escapeMarkup(text[i + 1 ..< close]) & "</span>"
        i = close + 1
        continue
    if c == '*' or c == '_':
      let close = emphasisEnd(text, i, c)
      if close >= 0:
        emit "<i>" & inlineMarkup(text[i + 1 ..< close]) & "</i>"
        i = close + 1
        continue
    if c == '~' and text.continuesWith("~~", i):
      let close = text.find("~~", i + 3)
      if close >= 0:
        emit "<s>" & escapeMarkup(text[i + 2 ..< close]) & "</s>"
        i = close + 2
        continue
    if c == '[':
      let mid = text.find("](", i + 1)
      if mid > i + 1 and ']' notin text[i + 1 ..< mid]:
        var j = mid + 2
        while j < text.len and text[j] notin {')', '\n'}: inc j
        if j < text.len and text[j] == ')' and j > mid + 2:
          let target = text[mid + 2 ..< j].strip
          let label = escapeMarkup(text[i + 1 ..< mid])
          if not target.startsWith("#"):
            emit "<a href=\"" & escapeMarkup(target) & "\">" & label & "</a>"
          else:
            # An anchor into the page: [§](#words) jumps to the words (see anchorPrefix).
            let words = anchorWords(target[1 .. ^1])
            if words.len == 0: emit "<u>" & label & "</u>"
            else: emit "<a href=\"" & escapeMarkup(anchorPrefix & words) & "\" title=\"" &
              escapeMarkup("Go to “" & words & "”") & "\">" & label & "</a>"
          i = j + 1
          continue
    plain.add c
    inc i
  emit ""

# ---------------------------------------------------------------------------------------------------------------
# Widgets

proc gtk_label_set_line_wrap_mode(l: Widget, mode: cint) {.importc, cdecl.}
const PANGO_WRAP_WORD_CHAR = 2.cint

const markdownCss* = """
.webby-md-code { background-color: alpha(currentColor, 0.08); border-radius: 6px; padding: 8px; }
.webby-md-quote { border-left: 3px solid alpha(currentColor, 0.25); padding-left: 10px; }
.webby-md-dim { opacity: 0.65; }
"""

var linkHandler*: proc (url: string)  ## a link clicked in rendered markdown; nil = GTK's default

proc onLink(label: Widget, uri: cstring, data: pointer): gboolean {.cdecl.} =
  if linkHandler == nil: return 0
  linkHandler($uri)
  1

proc markupLabel*(markup: string, selectable = true): Widget =
  ## A wrapping, left-aligned label showing Pango `markup`.
  result = gtk_label_new("")
  gtk_label_set_markup(result, markup.cstring)
  gtk_label_set_xalign(result, 0)
  gtk_label_set_line_wrap(result, 1)
  gtk_label_set_line_wrap_mode(result, PANGO_WRAP_WORD_CHAR)
  gtk_label_set_max_width_chars(result, 1)   # wrap to the panel instead of asking for a wide one
  gtk_widget_set_hexpand(result, 1)
  if selectable:
    gtk_label_set_selectable(result, 1)
    gtk_widget_set_can_focus(result, 0)
  connect(result, "activate-link", onLink)

proc markdownView*(source: string): Widget =
  ## A box of labels rendering `source`.
  result = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  var previous = -1
  for b in parseMarkdown(source):
    let gap =
      if previous < 0: 0
      elif previous == ord(mdListItem) and b.kind == mdListItem: 3
      elif b.kind == mdHeading: 14
      else: 8
    previous = ord(b.kind)
    var w: Widget
    case b.kind
    of mdHeading:
      let size = case b.level
        of 1: "x-large"
        of 2: "large"
        else: "medium"
      w = markupLabel("<span size=\"" & size & "\" weight=\"bold\">" & inlineMarkup(b.text) & "</span>")
    of mdParagraph:
      w = markupLabel(inlineMarkup(b.text))
    of mdListItem:
      w = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
      gtk_widget_set_margin_start(w, cint(4 + b.depth * 16))
      let marker = gtk_label_new(b.marker.cstring)
      addClass(marker, "webby-md-dim")
      gtk_label_set_xalign(marker, 0)
      gtk_widget_set_valign(marker, GTK_ALIGN_START)
      gtk_widget_set_size_request(marker, (if b.marker == "•": 14 else: 22), -1)
      gtk_box_pack_start(w, marker, 0, 0, 0)
      gtk_box_pack_start(w, markupLabel(inlineMarkup(b.text)), 1, 1, 0)
    of mdQuote:
      w = markupLabel(inlineMarkup(b.text))
      addClass(w, "webby-md-quote")
      addClass(w, "webby-md-dim")
    of mdCode:
      let label = markupLabel("<span font_family=\"monospace\">" & escapeMarkup(b.text) & "</span>")
      gtk_label_set_line_wrap(label, 0)
      let scroller = gtk_scrolled_window_new(nil, nil)
      gtk_scrolled_window_set_policy(scroller, GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
      gtk_container_add(scroller, label)
      addClass(scroller, "webby-md-code")
      w = scroller
    of mdRule:
      w = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)
    gtk_widget_set_margin_top(w, gap.cint)
    gtk_box_pack_start(result, w, 0, 0, 0)
