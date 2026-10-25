## QR codes for pairing links: byte mode, error correction level M, the smallest version that fits, the mask with
## the lowest penalty. After Project Nayuki's QR Code generator (MIT).

type QrCode* = seq[seq[bool]]   ## modules[y][x], true = dark; no quiet zone

const
  eccPerBlock = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28,
                 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28]
  eccBlocks = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26,
               28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49]

proc rawModules(ver: int): int =
  result = (16 * ver + 128) * ver + 64
  if ver >= 2:
    let n = ver div 7 + 2
    result -= (25 * n - 10) * n - 55
    if ver >= 7: result -= 36

proc dataCodewords(ver: int): int = rawModules(ver) div 8 - eccPerBlock[ver] * eccBlocks[ver]

proc gfMul(x, y: int): int =
  for i in countdown(7, 0):
    result = (result shl 1) xor ((result shr 7) * 0x11D)
    result = result xor (((y shr i) and 1) * x)

proc rsDivisor(degree: int): seq[int] =
  result = newSeq[int](degree)
  result[^1] = 1
  var root = 1
  for _ in 0 ..< degree:
    for j in 0 ..< degree:
      result[j] = gfMul(result[j], root)
      if j + 1 < degree: result[j] = result[j] xor result[j + 1]
    root = gfMul(root, 2)

proc rsRemainder(data, divisor: seq[int]): seq[int] =
  result = newSeq[int](divisor.len)
  for b in data:
    let factor = b xor result[0]
    result.delete(0)
    result.add 0
    for i in 0 ..< divisor.len: result[i] = result[i] xor gfMul(divisor[i], factor)

proc alignmentPositions(ver: int): seq[int] =
  if ver == 1: return
  let n = ver div 7 + 2
  let step = (ver * 8 + n * 3 + 5) div (n * 4 - 4) * 2
  result = newSeq[int](n)
  var pos = ver * 4 + 17 - 7
  for i in countdown(n - 1, 1):
    result[i] = pos
    pos -= step
  result[0] = 6

proc qrEncode*(text: string): QrCode =
  ## Raises ValueError when `text` is too long for any version (over 2331 bytes).
  var ver = 1
  while true:
    if ver > 40: raise newException(ValueError, "too long for a QR code")
    let bits = 4 + (if ver < 10: 8 else: 16) + 8 * text.len
    if bits <= dataCodewords(ver) * 8: break
    inc ver
  let capacity = dataCodewords(ver)

  # The data: mode, length, bytes, terminator, padding.
  var bits: seq[bool]
  proc put(v, n: int) =
    for i in countdown(n - 1, 0): bits.add ((v shr i) and 1) == 1
  put(4, 4)
  put(text.len, if ver < 10: 8 else: 16)
  for c in text: put(ord(c), 8)
  put(0, min(4, capacity * 8 - bits.len))
  put(0, (8 - bits.len mod 8) mod 8)
  var data: seq[int]
  for i in countup(0, bits.len - 1, 8):
    var b = 0
    for j in 0 ..< 8: b = (b shl 1) or ord(bits[i + j])
    data.add b
  var pad = 0xEC
  while data.len < capacity:
    data.add pad
    pad = pad xor (0xEC xor 0x11)

  # Error correction, interleaved.
  let numBlocks = eccBlocks[ver]
  let eccLen = eccPerBlock[ver]
  let raw = rawModules(ver) div 8
  let numShort = numBlocks - raw mod numBlocks
  let shortLen = raw div numBlocks
  let divisor = rsDivisor(eccLen)
  var blocks: seq[seq[int]]
  var k = 0
  for i in 0 ..< numBlocks:
    let n = shortLen - eccLen + (if i < numShort: 0 else: 1)
    var dat = data[k ..< k + n]
    k += n
    let ecc = rsRemainder(dat, divisor)
    if i < numShort: dat.add 0
    blocks.add dat & ecc
  var codewords: seq[int]
  for i in 0 ..< blocks[0].len:
    for j, blk in blocks:
      if i != shortLen - eccLen or j >= numShort: codewords.add blk[i]

  # Function patterns.
  let size = ver * 4 + 17
  var modules = newSeq[seq[bool]](size)
  var isFn = newSeq[seq[bool]](size)
  for y in 0 ..< size:
    modules[y] = newSeq[bool](size)
    isFn[y] = newSeq[bool](size)
  proc fn(x, y: int, dark: bool) =
    modules[y][x] = dark
    isFn[y][x] = true
  for i in 0 ..< size:
    fn(6, i, i mod 2 == 0)
    fn(i, 6, i mod 2 == 0)
  for (cx, cy) in [(3, 3), (size - 4, 3), (3, size - 4)]:
    for dy in -4 .. 4:
      for dx in -4 .. 4:
        let x = cx + dx
        let y = cy + dy
        if x in 0 ..< size and y in 0 ..< size:
          let d = max(abs(dx), abs(dy))
          fn(x, y, d != 2 and d != 4)
  let align = alignmentPositions(ver)
  for i, ax in align:
    for j, ay in align:
      if (i == 0 and j == 0) or (i == 0 and j == align.len - 1) or (i == align.len - 1 and j == 0): continue
      for dy in -2 .. 2:
        for dx in -2 .. 2: fn(ax + dx, ay + dy, max(abs(dx), abs(dy)) != 1)
  proc drawFormat(mask: int) =
    let d = mask   # level M is 0b00
    var rem = d
    for _ in 0 ..< 10: rem = (rem shl 1) xor ((rem shr 9) * 0x537)
    let f = ((d shl 10) or rem) xor 0x5412
    proc bit(i: int): bool = ((f shr i) and 1) == 1
    for i in 0 .. 5: fn(8, i, bit(i))
    fn(8, 7, bit(6))
    fn(8, 8, bit(7))
    fn(7, 8, bit(8))
    for i in 9 .. 14: fn(14 - i, 8, bit(i))
    for i in 0 .. 7: fn(size - 1 - i, 8, bit(i))
    for i in 8 .. 14: fn(8, size - 15 + i, bit(i))
    fn(8, size - 8, true)
  drawFormat(0)   # reserves the format areas
  if ver >= 7:
    var rem = ver
    for _ in 0 ..< 12: rem = (rem shl 1) xor ((rem shr 11) * 0x1F25)
    let v = (ver shl 12) or rem
    for i in 0 .. 17:
      let dark = ((v shr i) and 1) == 1
      let a = size - 11 + i mod 3
      let b = i div 3
      fn(a, b, dark)
      fn(b, a, dark)

  # The codewords, in the zigzag.
  var i = 0
  var right = size - 1
  while right >= 1:
    if right == 6: right = 5
    for vert in 0 ..< size:
      for j in 0 .. 1:
        let x = right - j
        let y = if ((right + 1) and 2) == 0: size - 1 - vert else: vert
        if not isFn[y][x] and i < codewords.len * 8:
          modules[y][x] = ((codewords[i shr 3] shr (7 - (i and 7))) and 1) == 1
          inc i
    right -= 2

  proc applyMask(mask: int) =
    for y in 0 ..< size:
      for x in 0 ..< size:
        if isFn[y][x]: continue
        let invert = case mask
          of 0: (x + y) mod 2 == 0
          of 1: y mod 2 == 0
          of 2: x mod 3 == 0
          of 3: (x + y) mod 3 == 0
          of 4: (x div 3 + y div 2) mod 2 == 0
          of 5: x * y mod 2 + x * y mod 3 == 0
          of 6: (x * y mod 2 + x * y mod 3) mod 2 == 0
          else: ((x + y) mod 2 + x * y mod 3) mod 2 == 0
        if invert: modules[y][x] = not modules[y][x]

  proc penalty(): int =
    proc at(x, y: int, horizontal: bool): bool = (if horizontal: modules[y][x] else: modules[x][y])
    for horizontal in [true, false]:
      for a in 0 ..< size:
        var run = 1
        for b in 1 ..< size:
          if at(b, a, horizontal) == at(b - 1, a, horizontal):
            inc run
            if run == 5: result += 3
            elif run > 5: inc result
          else: run = 1
        # finder-like 1:1:3:1:1 with four light modules on one side
        for b in 0 .. size - 7:
          let p = [true, false, true, true, true, false, true]
          var hit = true
          for t in 0 ..< 7:
            if at(b + t, a, horizontal) != p[t]: (hit = false; break)
          if not hit: continue
          var before, after = true
          for t in 1 .. 4:
            if b - t >= 0 and at(b - t, a, horizontal): before = false
            if b + 6 + t < size and at(b + 6 + t, a, horizontal): after = false
          if before or after: result += 40
    for y in 0 ..< size - 1:
      for x in 0 ..< size - 1:
        let c = modules[y][x]
        if c == modules[y][x + 1] and c == modules[y + 1][x] and c == modules[y + 1][x + 1]: result += 3
    var dark = 0
    for row in modules:
      for m in row:
        if m: inc dark
    let total = size * size
    result += (abs(dark * 20 - total * 10) + total - 1) div total * 10 - 10

  var best = 0
  var bestPenalty = high(int)
  for mask in 0 .. 7:
    applyMask(mask)
    drawFormat(mask)
    let p = penalty()
    if p < bestPenalty: (best = mask; bestPenalty = p)
    applyMask(mask)   # undo
  applyMask(best)
  drawFormat(best)
  modules
