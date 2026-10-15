## Icon outlines (core.registerIcons) parsed into drawing commands, for backends that draw them with move/line/
## curve calls (cairo on GTK). Paths are SVG path data of absolute M, L, H, V, C and Z commands, as fontTools'
## SVGPathPen writes them (webby's icondata.nim, from the Material Icons font).

import std/[strutils, tables]
import core

type
  GlyphOp* = enum goMove, goLine, goCurve, goClose
  Glyph* = ref object
    ops*: seq[(GlyphOp, array[6, float])]

proc parseGlyph*(d: string): Glyph =
  result = Glyph()
  var nums: seq[float]
  var cmd = ' '
  var x, y: float
  proc flush(g: Glyph, cmd: char, nums: var seq[float], x, y: var float) =
    var i = 0
    case cmd
    of 'M', 'L':
      while i + 1 < nums.len:
        x = nums[i]; y = nums[i + 1]
        g.ops.add ((if cmd == 'M' and i == 0: goMove else: goLine), [x, y, 0, 0, 0, 0])
        i += 2
    of 'H':
      for n in nums: x = n; g.ops.add (goLine, [x, y, 0, 0, 0, 0])
    of 'V':
      for n in nums: y = n; g.ops.add (goLine, [x, y, 0, 0, 0, 0])
    of 'C':
      while i + 5 < nums.len:
        g.ops.add (goCurve, [nums[i], nums[i+1], nums[i+2], nums[i+3], nums[i+4], nums[i+5]])
        x = nums[i+4]; y = nums[i+5]
        i += 6
    of 'Z': g.ops.add (goClose, [0.0, 0, 0, 0, 0, 0])
    else: discard
    nums.setLen 0
  var token = ""
  for c in d & " ":
    if c in {'0'..'9', '.', '-'} and not (c == '-' and token.len > 0):
      token.add c
      continue
    if token.len > 0:
      nums.add parseFloat(token)
      token = ""
    if c == '-': token.add c
    elif c.isAlphaAscii:
      result.flush(cmd, nums, x, y)
      cmd = c
  result.flush(cmd, nums, x, y)

var cache: Table[string, Glyph]

proc glyph*(name: string): Glyph =
  ## The parsed outline of icon `name`, or nil if no such icon is registered.
  result = cache.getOrDefault(name)
  if result == nil and name in iconPaths:
    result = parseGlyph(iconPaths[name])
    cache[name] = result
