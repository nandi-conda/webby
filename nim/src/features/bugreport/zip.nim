## A plain zip archive writer for bug reports: every file stored as is (no compression; the video and screenshot
## are compressed already and the JSON is small), so it needs nothing beyond the standard library. Any unzip,
## file manager or OS opens it.

import std/[os, strutils, times]

var crcTable: array[256, uint32]
for i in 0 .. 255:
  var c = i.uint32
  for _ in 0 ..< 8:
    c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
  crcTable[i] = c

proc crc32*(data: string): uint32 =
  result = 0xFFFFFFFF'u32
  for ch in data:
    result = crcTable[(result xor ch.uint32) and 0xFF] xor (result shr 8)
  result = result xor 0xFFFFFFFF'u32

proc le(s: var string, v: uint32, bytes: int) =
  for i in 0 ..< bytes: s.add char((v shr (8 * i)) and 0xFF)

proc dosTime(t: DateTime): (uint32, uint32) =
  ## Zip keeps local times in MS-DOS form: 2-second resolution, years from 1980.
  let time = (t.hour shl 11) or (t.minute shl 5) or (t.second div 2)
  let date = ((max(t.year, 1980) - 1980) shl 9) or (ord(t.month) shl 5) or t.monthday
  (time.uint32, date.uint32)

proc writeZip*(path: string, files: seq[tuple[name, data: string]]) =
  ## Writes `files` (names may hold "/" for folders) to the zip at `path`, through a temporary file so a reader
  ## never sees half an archive. Each file must be under 4 GiB (no zip64).
  let (time, date) = dosTime(now())
  var central = ""
  var offset = 0'u32
  let tmp = path & ".part"
  let f = open(tmp, fmWrite)
  try:
    for file in files:
      if file.data.len.int64 >= 0xFFFFFFFF'i64: raise newException(IOError, file.name & " is too big for a zip")
      let crc = crc32(file.data)
      let size = file.data.len.uint32
      var header = ""
      header.le(0x04034b50'u32, 4)   # local file header
      header.le(20, 2)               # version needed: 2.0
      header.le(0x0800, 2)           # flags: names are UTF-8
      header.le(0, 2)                # method: stored
      header.le(time, 2); header.le(date, 2)
      header.le(crc, 4); header.le(size, 4); header.le(size, 4)
      header.le(file.name.len.uint32, 2); header.le(0, 2)
      header.add file.name
      f.write header
      f.write file.data
      central.le(0x02014b50'u32, 4)  # central directory entry
      central.le(0x031E, 2)          # made by: Unix, 3.0
      central.le(20, 2); central.le(0x0800, 2); central.le(0, 2)
      central.le(time, 2); central.le(date, 2)
      central.le(crc, 4); central.le(size, 4); central.le(size, 4)
      central.le(file.name.len.uint32, 2)
      central.le(0, 2); central.le(0, 2); central.le(0, 2); central.le(0, 2)  # extra, comment, disk, internal attrs
      central.le(0o100644'u32 shl 16, 4)   # external attrs: a regular file, rw-r--r--
      central.le(offset, 4)
      central.add file.name
      offset += (header.len + file.data.len).uint32
    var tail = ""
    tail.le(0x06054b50'u32, 4)       # end of central directory
    tail.le(0, 2); tail.le(0, 2)
    tail.le(files.len.uint32, 2); tail.le(files.len.uint32, 2)
    tail.le(central.len.uint32, 4); tail.le(offset, 4)
    tail.le(0, 2)
    f.write central
    f.write tail
  finally:
    f.close()
  moveFile(tmp, path)

proc zipFolder*(folder, path: string) =
  ## Zips every file in `folder` under one top folder named like it, so unzipping gives the folder back.
  var files: seq[tuple[name, data: string]]
  let top = folder.lastPathPart
  for rel in walkDirRec(folder, relative = true):
    files.add (top & "/" & rel.replace(DirSep, '/'), readFile(folder / rel))
  writeZip(path, files)
