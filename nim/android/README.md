# webby-nim for Android

The Nim front end on Android. GTK doesn't run there, so the split is:

- `src/webby_android.nim` + `src/glue.c` → `libwebbynim.so` (~220 KB): Ladybird (`libwebby.so`, the same native
  runtime as the Flutter APK), tabs, the pump (a timerfd on the main thread's looper, 4 → 100 ms like the desktop),
  touch gestures (tap, drag-scroll, fling, long-press → right-click), the on-screen keyboard, page dialogs, the page
  shims and right-click script (read from the Flutter app's Dart sources at compile time), saved tabs.
- `java/dev/webby/nim/` → the shell: one Activity with Android widgets (back, URL field, tab switcher, reload, menu),
  a `SurfaceView` for the page, AlertDialogs for page dialogs and the long-press menu. It only forwards input and
  draws what the Nim side reports (JSON through `MainActivity.on*`).

Frames go from Ladybird's buffer straight into the Surface (`ANativeWindow_lock`, BGRA as is), with no Flutter
engine, texture upload or Dart heap in the UI process.

It installs as "Webby Nim" (`dev.webby.nim`), next to the Flutter app (`dev.webby.webby`); profiles are separate.

## Build

```
ANDROID_HOME=<sdk with ndk;29.0.14206865, platforms;android-36, build-tools;36.0.0> NIM=<nim 2.x> \
  nim/android/build.sh webby-android-native-arm64.tar.zst [version-name] [version-code]
```

The native tarball is the Release named in `scripts/android/native.env`. No Gradle: aapt2, javac, d8, zipalign,
apksigner. CI (`.github/workflows/nim-android-apk.yml`) builds and publishes `webby-nim-android-<version>` on pushes to
main that touch `nim/`.

Not on Android yet (the desktop Nim front end has them): bookmarks, history and omnibox suggestions, passwords and
passkeys, sync, site permissions (requests are declined), file inputs, notifications, downloads.
