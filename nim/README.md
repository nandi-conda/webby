# webby's front end

A Nim program that drives `libwebby.so` (Ladybird, see `native/webby_ffi.h`), with its UI on nimkit
(`framework/`): GTK 3 on the desktop, where each frame is drawn straight into the page canvas with cairo (Ladybird's
premultiplied BGRA frame is cairo's ARGB32 layout, so no copy and no swizzle), and Android views on phones.

Features: bookmarks (bar, manager, HTML import/export), history and omnibox suggestions, the password vault with
autofill and passkeys, end-to-end encrypted sync, tabs from other devices, saved
sessions, pinned and vertical tabs, tab and page context menus, incognito windows, site permissions and settings,
file inputs, notifications, geolocation (GeoClue), dark mode, favicons, installable web apps (`--app=`), offline
mode and Summarize. On Android, `nim/android-kit` runs this same front end on nimkit's Android host
(`nim/android-kit/build.sh`, installed as "Webby Nim", dev.webby.nim); platform services come from its Java host
through `hostCall` (`src/features/android.nim`).

The core is `src/browser.nim` (window, tabs, input, pump, hooks); each feature is a module in `src/features/` whose
`install()` only adds hooks. Build without `-d:ssl` and don't import std/net: Nim's OpenSSL setup loads the system
libcrypto before libwebby, whose own crypto library then fails to load. Features use GIO for HTTP and the runtime's
libcrypto for cryptography.

Icons are Material Icons (compiled in from `src/icondata.nim`, drawn in the theme's text colour)
rather than the desktop icon theme's: `icon("arrow_back")` / `setIcon(image, name)` in `src/icons.nim`, with
`scripts/material_icons.py <flutter-sdk>` adding more names (the Flutter SDK ships the font). The window icon is `icons/webby*.svg`, also compiled in.

`pixi run webby [url]` (also `webby-nim`) builds it with the pixi env's Nim and GTK (again only when the sources change) and runs it
against the webby-ladybird package. By hand:

```
nim c -d:release -o:nim/webby nim/webby.nim      # needs Nim and GTK 3 headers (pkg-config gtk+-3.0), glib-networking for HTTPS
WEBBY_LADYBIRD_PREFIX=<webby-ladybird runtime> nim/webby https://example.com
```

Keys: Ctrl+T new tab, Ctrl+W close, Ctrl+L URL bar, Ctrl+R / F5 reload, Alt+Left/Right, Ctrl+(Shift+)Tab,
middle-click a tab to close it. `WEBBY_TRACE=1` prints pump, frame, draw and wheel-latency counters every 5 s, plus a `webby-cpu` line with each webby
process's (and its busiest threads') CPU, as % of one core.

## Nim vs the old Flutter front end, same engine

webby's first front end was a Flutter app (removed 2026-10-15). `nim/bench.py TAG URL -- COMMAND` runs one front end on one page under X and reports CPU (% of one core, UI process
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
