## GL drivers: WebGL runs in Ladybird's Compositor on ANGLE over EGL, through the env's libglvnd. glvnd reads the
## system's vendor files (/usr/share/glvnd/egl_vendor.d/50_mesa.json and the like), which name the driver library by
## its bare name, and the library loader then finds the env's own copy first. Since the PDF viewer's MuPDF came in,
## the env has one: conda-forge's Mesa, software rendering only, which also can't start in the Compositor's sandbox
## (built without memfd, it wants a file in $XDG_RUNTIME_DIR, which Landlock refuses), so every page got "Error
## creating WebGL context" (autosapien.com, 2026-10-26).
##
## So before the engine starts, this writes copies of the system's vendor files with each library's whole path into
## the cache and points glvnd at them (__EGL_VENDOR_LIBRARY_DIRS, which the Compositor's sandbox also allows). The
## system's drivers (Mesa for the GPU, NVIDIA's) come first; vendor directories set already (the AppImage's own Mesa)
## stay after them as a fallback. __EGL_VENDOR_LIBRARY_FILENAMES set by the user wins over all of it.

import std/[json, os, osproc, strutils]

const systemVendorDirs = ["/etc/glvnd/egl_vendor.d", "/usr/share/glvnd/egl_vendor.d", "/usr/local/share/glvnd/egl_vendor.d"]

proc ldconfigLibraries(): seq[(string, string)] =
  ## (soname, path) for this machine's architecture from the system's library cache.
  let arch = when defined(amd64): "x86-64" elif defined(arm64): "AArch64" else: ""
  for ldconfig in ["/sbin/ldconfig", "/usr/sbin/ldconfig", "/usr/bin/ldconfig"]:
    if not fileExists(ldconfig): continue
    let (output, code) = try: execCmdEx(ldconfig & " -p") except CatchableError: ("", 1)
    if code != 0: continue
    for line in output.splitLines:
      # "	libEGL_mesa.so.0 (libc6,x86-64) => /usr/lib/libEGL_mesa.so.0"
      let arrow = line.find(" => ")
      let paren = line.find(" (")
      if arrow < 0 or paren < 0 or paren > arrow: continue
      if arch.len > 0 and arch notin line[paren ..< arrow]: continue
      result.add (line[0 ..< paren].strip, line[arrow + 4 .. ^1].strip)
    return

proc systemLibrary(name: string, cache: var seq[(string, string)], cacheRead: var bool): string =
  if '/' in name: return (if fileExists(name): name else: "")
  if not cacheRead:
    cache = ldconfigLibraries()
    cacheRead = true
  for (soname, path) in cache:
    if soname == name and fileExists(path): return path
  for dir in ["/usr/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu", "/usr/lib64", "/usr/lib", "/lib64", "/lib"]:
    if fileExists(dir / name): return dir / name

proc install*() =
  if getEnv("__EGL_VENDOR_LIBRARY_FILENAMES").len > 0: return
  let dir = getCacheDir() / "webby" / "egl_vendor.d"
  var written: seq[string]
  var libraries: seq[(string, string)]
  var librariesRead = false
  try:
    createDir(dir)
    for systemDir in systemVendorDirs:
      for file in walkFiles(systemDir / "*.json"):
        let name = file.extractFilename
        if name in written: continue   # /etc overrides /usr/share, as in glvnd
        var manifest: JsonNode
        try: manifest = parseFile(file) except CatchableError: continue
        let icd = manifest{"ICD"}
        if icd == nil or icd.kind != JObject: continue
        let library = systemLibrary(icd{"library_path"}.getStr, libraries, librariesRead)
        if library.len == 0: continue
        icd["library_path"] = %library
        writeFile(dir / name, $manifest)
        written.add name
    for file in walkFiles(dir / "*.json"):
      if file.extractFilename notin written: removeFile(file)
  except CatchableError as e:
    stderr.writeLine "webby: GL drivers: " & e.msg
    return
  if written.len == 0: return   # no system drivers: leave glvnd as it was
  var dirs = @[dir]
  for d in getEnv("__EGL_VENDOR_LIBRARY_DIRS").split(':'):   # an incognito or app window inherits ours
    if d.len > 0 and d notin dirs: dirs.add d
  putEnv("__EGL_VENDOR_LIBRARY_DIRS", dirs.join(":"))
