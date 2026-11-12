#!/usr/bin/env python3
"""png-pixel.py FILE.png X Y [X Y]...: prints the RGBA (hex) of each pixel; or png-pixel.py --make W H RRGGBB OUT.png
makes a solid PNG; or png-pixel.py --count FILE.png RRGGBB TOLERANCE
prints how many pixels are within TOLERANCE of RRGGBB in every channel. Standard library only: 8-bit RGB/RGBA, non-interlaced PNGs (what LibGfx's PNGWriter writes)."""
import struct, sys, zlib


def chunks(data):
    pos = 8
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        yield kind, data[pos + 8:pos + 8 + length]
        pos += 12 + length


def read(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    idat = b""
    for kind, body in chunks(data):
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and color in (2, 6) and interlace == 0, "unsupported PNG"
        elif kind == b"IDAT":
            idat += body
    bpp = 4 if color == 6 else 3
    raw = zlib.decompress(idat)
    stride = width * bpp
    rows, prev = [], bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return width, height, bpp, rows


def make(width, height, rgb, out):
    r, g, b = bytes.fromhex(rgb)
    raw = b"".join(b"\0" + bytes([r, g, b]) * width for _ in range(height))
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    open(out, "wb").write(png)


if sys.argv[1] == "--make":
    make(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5])
elif sys.argv[1] == "--count":
    width, height, bpp, rows = read(sys.argv[2])
    want, tolerance = bytes.fromhex(sys.argv[3]), int(sys.argv[4])
    print(sum(1 for line in rows for x in range(width)
              if all(abs(line[x * bpp + i] - want[i]) <= tolerance for i in range(3))))
else:
    width, height, bpp, rows = read(sys.argv[1])
    coords = list(map(int, sys.argv[2:]))
    for x, y in zip(coords[::2], coords[1::2]):
        px = rows[y][x * bpp:(x + 1) * bpp]
        print(px[:3].hex())
