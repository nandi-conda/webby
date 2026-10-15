# nimkit (prototype)

One Nim source for a Linux desktop app (GTK 3), an Android app and a web page, grown out of webby's two Nim
front ends (`nim/` on GTK, `nim/android` with a Java shell). The app builds a tree of plain Nim widgets; a backend
picked at compile time turns it into native widgets: GtkWidgets, Android Views, or DOM elements.

```nim
import nimkit

let hello = label("Hello")
run("Demo", column(hello, button("Click", proc () = hello.text = "Clicked")))
```

`demo/demo.nim` shows the rest: a counter, an entry kept between runs (`load`/`store`), a 1 s timer (`every`), an
HTTP fetch (`request`) and a canvas you can draw on with the mouse or fingers.

## What's in it

| | GTK desktop | Android | Web |
|---|---|---|---|
| column, row, scroll | GtkBox, GtkScrolledWindow | LinearLayout, ScrollView | flexbox `<div>`s |
| label, button, entry, check | GtkLabel, GtkButton, GtkEntry, GtkCheckButton | TextView, Button, EditText, CheckBox | `<div>`, `<button>`, `<input>` |
| canvas (pixel buffer + pointer events) | GtkDrawingArea, cairo paints the buffer in place | SurfaceView, ANativeWindow blit | `<canvas>`, ImageData |
| `after` / `every` timers | GLib sources | Handler.postDelayed | setTimeout |
| `load` / `store` | files in `$XDG_DATA_HOME/<appName>/` | files in the app's files dir | localStorage |
| `request` (HTTP) | GIO sockets (webby's client) | HttpURLConnection on a thread | fetch() (CORS applies) |

Canvas pixels are premultiplied `0xAARRGGBB`, the layout of cairo's ARGB32 and of Ladybird's frames, so the desktop
paints them with no copy. `pixelRatio` is canvas pixels per logical pixel (the screen density on Android, 1
elsewhere).

Layout is deliberately small: columns and rows stretch their children across, and `expand` (or `w.expanded = true`)
gives a child the spare room along. Everything runs on the UI thread.

## Building

Desktop (needs Nim 2 and GTK 3 headers; never `-d:ssl` or std/net, see `nim/README.md`):

```
nim c -d:release --path:framework/src -o:nimkit-demo framework/demo/demo.nim && ./nimkit-demo
```

Web (static files to serve from any web server):

```
framework/web/build.sh framework/demo/demo.nim out/   # out/index.html + out/app.js
```

Android (the same SDK, NDK and Nim as `nim/android/build.sh`; arm64 and x86_64 in one APK):

```
ANDROID_HOME=... framework/android/build.sh framework/demo/demo.nim dev.nimkit.demo "nimkit demo"
```

The Android app is a generic Java Activity (`android/java/dev/nimkit/Host.java`) that makes the views the Nim side
asks for and sends their events back through `android/glue.c`. Apps never write Java.

## Layout

```
src/nimkit.nim               the module apps import; picks the backend
src/nimkit/core.nim          widgets, tree, canvas pixels; the backend hooks
src/nimkit/services.nim      timers, storage, HTTP, log
src/nimkit/backend/gtk.nim   (+ gtkapi.nim, gio_http.nim)
src/nimkit/backend/web.nim
src/nimkit/backend/android.nim
android/                     glue.c, the Java host, manifest template, build.sh
web/                         index.html, build.sh
demo/demo.nim
```

The design note (how webby would sit on it and what comes next) is `/mnt/project-files/nim-framework/design.md` in the
project files.
