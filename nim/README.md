# webby-nim (experiment)

The webby browser without Flutter: a Nim program on GTK 3 that drives the same `libwebby.so` (Ladybird, see
`native/webby_ffi.h`) and draws each frame straight into a `GtkDrawingArea` with cairo. Ladybird's premultiplied
BGRA frame is cairo's ARGB32 layout, so the frame is painted in place: no copy, no swizzle, no Flutter engine.

It has the desktop Flutter app's features, sharing its profile files so either front end can open the same
profile: bookmarks (bar, manager, HTML import/export), history and omnibox suggestions, the password vault with
autofill and passkeys, end-to-end encrypted sync (compatible with Flutter devices), tabs from other devices, saved
sessions, pinned and vertical tabs, tab and page context menus, incognito windows, site permissions and settings,
file inputs, notifications, geolocation (GeoClue), dark mode, favicons, installable web apps (`--app=`), offline
mode and Summarize. The Android app stays on Flutter.

The core is `src/browser.nim` (window, tabs, input, pump, hooks); each feature is a module in `src/features/` whose
`install()` only adds hooks. Build without `-d:ssl` and don't import std/net: Nim's OpenSSL setup loads the system
libcrypto before libwebby, whose own crypto library then fails to load. Features use GIO for HTTP and the runtime's
libcrypto for cryptography.

```
nim c -d:release -o:nim/webby nim/webby.nim      # needs Nim and GTK 3 headers (pkg-config gtk+-3.0), glib-networking for HTTPS
WEBBY_LADYBIRD_PREFIX=<webby-ladybird runtime> nim/webby https://example.com
```

Keys: Ctrl+T new tab, Ctrl+W close, Ctrl+L URL bar, Ctrl+R / F5 reload, Alt+Left/Right, Ctrl+(Shift+)Tab,
middle-click a tab to close it. `WEBBY_TRACE=1` prints pump, frame, draw and wheel-latency counters every 5 s.

## Nim vs Flutter, same engine

`nim/bench.py TAG URL -- COMMAND` runs one front end on one page under X and reports CPU (% of one core, UI process
vs Ladybird's helpers), PSS, and wheel latency (wheel event sent to the next new frame, from WEBBY_TRACE).
2026-10-12, Xvfb 1920x1080 with llvmpipe (no GPU), window 1280x800, runtime webby-ladybird 2026.10.12.7, local pages,
two runs each agreeing within a few percent:

| | Flutter app | Nim shell |
|---|---|---|
| Long article, idle: UI CPU | 0.8% | 0.1% |
| Long article, wheel scrolling: UI CPU | 39-40% | 3% |
| Long article, wheel scrolling: engine CPU | 5% | 5% |
| Wheel event to new frame | 15.6-16.7 ms | 15.8-17.2 ms |
| CSS animation at 60 fps: UI CPU | 222% | 8% |
| Memory (PSS), UI process | 255 MB | 105 MB |
| Memory (PSS), UI + Ladybird | 465 MB | 286 MB |

Scroll latency is the engine's (WebContent paints the frame), so it doesn't move. The UI process's CPU and memory
do. llvmpipe makes Flutter's GPU raster unusually expensive, so on a real GPU the CPU gap is smaller; the memory gap
(the Flutter engine, Skia/Impeller, Dart heap) isn't GPU-dependent.

With every feature ported (11k lines of Nim), the same bench gives: wheel scrolling 3% UI CPU, 60 fps animation 8%,
PSS 90 MB for the UI process and 270-280 MB in total.
