## Decoding downloaded images (PNG, ICO, JPEG, GIF, BMP, SVG, WebP: whatever gdk-pixbuf has loaders for).

{.push cdecl, importc.}
proc gdk_pixbuf_loader_new(): pointer
proc gdk_pixbuf_loader_write(l: pointer, buf: pointer, count: csize_t, err: ptr pointer): cint
proc gdk_pixbuf_loader_close(l: pointer, err: ptr pointer): cint
proc gdk_pixbuf_loader_get_pixbuf(l: pointer): pointer
proc gdk_pixbuf_get_width(p: pointer): cint
proc gdk_pixbuf_get_height(p: pointer): cint
proc gdk_pixbuf_scale_simple(p: pointer, w, h: cint, interp: cint): pointer
proc gdk_pixbuf_save_to_buffer(p: pointer, buf: ptr pointer, size: ptr csize_t, kind: cstring, err: ptr pointer): cint {.varargs.}
proc g_object_ref(p: pointer): pointer
proc g_object_unref(p: pointer)
proc g_error_free(e: pointer)
proc g_free(p: pointer)
{.pop.}

const interpBilinear = 2.cint

proc decodeImage*(bytes: string): pointer =
  ## A GdkPixbuf (unref when done), or nil when the bytes aren't an image.
  if bytes.len == 0: return nil
  let loader = gdk_pixbuf_loader_new()
  var err: pointer
  let wrote = gdk_pixbuf_loader_write(loader, unsafeAddr bytes[0], bytes.len.csize_t, addr err)
  if err != nil: (g_error_free(err); err = nil)
  let closed = gdk_pixbuf_loader_close(loader, addr err)
  if err != nil: g_error_free(err)
  let p = gdk_pixbuf_loader_get_pixbuf(loader)
  if wrote != 0 and closed != 0 and p != nil: result = g_object_ref(p)
  g_object_unref(loader)

proc scaled*(pixbuf: pointer, size: int): pointer =
  ## `pixbuf` scaled down to fit `size` x `size` (a new reference either way).
  let w = gdk_pixbuf_get_width(pixbuf).int
  let h = gdk_pixbuf_get_height(pixbuf).int
  if max(w, h) <= size: return g_object_ref(pixbuf)
  let f = size / max(w, h)
  gdk_pixbuf_scale_simple(pixbuf, max(1, int(w.float * f + 0.5)).cint, max(1, int(h.float * f + 0.5)).cint,
    interpBilinear)

proc toPng*(bytes: string, maxSize = 512): string =
  ## Re-encodes an image as PNG, at most `maxSize` px; "" when it can't be decoded.
  let p = decodeImage(bytes)
  if p == nil: return ""
  let small = scaled(p, maxSize)
  var buf: pointer
  var size: csize_t
  var err: pointer
  if gdk_pixbuf_save_to_buffer(small, addr buf, addr size, "png", addr err, nil) != 0:
    result = newString(size.int)
    if size > 0: copyMem(addr result[0], buf, size.int)
    g_free(buf)
  elif err != nil: g_error_free(err)
  g_object_unref(small)
  g_object_unref(p)
