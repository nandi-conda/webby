# webby

A web browser written in Nim with [Ladybird](https://ladybird.org)'s engine underneath: **LibWeb** renders pages
and **LibJS** runs their JavaScript. The same front end runs on the Linux desktop (GTK 3) and on Android.

```
Nim front end  ──C ABI──▶  libwebby.so  ──LibWebView──▶  WebContent process (LibWeb + LibJS)
  (nim/, on nimkit)          headless                      RequestServer (networking)
  tabs, URL bar, input       ViewImplementation            ImageDecoder
```

Ladybird already runs each page in a sandboxed `WebContent` helper process and talks to it through `LibWebView`.
Webby adds a new Ladybird "UI frontend" (`native/`, built as `UI/Flutter` inside the Ladybird tree, a name kept from
the first front end) whose
`ladybird` target is a shared library, `libwebby.so`, instead of the Qt app. It exposes a small C API
(`native/webby_ffi.h`): create a view, load a URL, back/forward/reload/stop, resize, mouse/wheel/key input, and
read the latest frame as BGRA pixels plus the page's URL, title, loading state and cursor.

The front end (`nim/`) pumps Ladybird's event loop, draws each new frame into its page canvas and forwards pointer,
touch and keyboard events. Its UI is built on nimkit (`framework/`), which turns one Nim widget tree into GTK widgets
on the desktop and Android views on phones.

## Requirements

Linux x86_64 with **glibc 2.35 or newer** (Ubuntu 22.04, Debian 12, Fedora 36 or later; the Ladybird runtime is built
on Ubuntu 22.04) and a CPU that supports
**x86-64-v3** (AVX2; roughly Intel Haswell / AMD Excavator or later). [pixi](https://pixi.sh) installs everything else.

## Quick start

From a checkout:

```sh
just                                    # or: pixi run webby
just open https://example.com           # or: pixi run webby https://example.com
```

`pixi run webby` builds and runs the Nim front end (`nim/`, see its README). `just` is optional; it only wraps pixi.
The first run installs, into `.pixi/`:

- `webby-ladybird` from [prefix.dev/nandi-testing](https://prefix.dev/channels/nandi-testing): `libwebby.so`,
  LibWeb/LibJS and the other Ladybird libraries, the helper processes (`WebContent`, `RequestServer`, …) and
  `share/Lagom`. Its activation script sets `WEBBY_LADYBIRD_PREFIX` to it.
- Nim, clang, lld and GTK 3 from conda-forge.

Then it builds and runs the app. Later runs skip the installs, and rebuild only when `nim/`, `framework/` or `icons/`
changed.

## Install the app

To just use the browser, install the `webby` package globally and run it:

```sh
pixi global install -c https://prefix.dev/nandi-testing webby
webby https://example.com
```

`webby` is a release build of the Nim front end (recipe `conda/webby`) that depends on `webby-ladybird`; its launcher points
`WEBBY_LADYBIRD_PREFIX` at that package unless you've set it yourself.

`webby --incognito [url]` (or Ctrl+Shift+N, or "New incognito window" in the ⋮ menu) opens an incognito
window: its own Ladybird with a temporary profile, no SQL database and no HTTP disk cache, so cookies, site storage,
cache and permission decisions are gone when it closes. It doesn't save passwords or bookmarks, sync, or share its
tabs with other devices.

## Layout

| Path | What |
| --- | --- |
| `native/` | C++ shim: `Webby::Application`, `Webby::View` (a `HeadlessWebView` that copies presented frames) and the C ABI |
| `patches/` | Ladybird patches: `0001` adds the `LADYBIRD_UI_FLUTTER` option to `UI/CMakeLists.txt`, `0002` adds Web Authentication (passkeys) to LibWeb |
| `LADYBIRD_COMMIT` | The Ladybird commit this is built against |
| `nim/` | The front end: `src/browser.nim` (window, tabs, input), `src/features/` (one module per feature), `src/scripts/` (page scripts), `android-kit/` (the Android app) |
| `framework/` | nimkit: the cross-platform widget toolkit the front end is built on (GTK, Android and web backends) |
| `pixi.toml`, `scripts/pixi_nim.sh`, `justfile` | `pixi run webby` / `just`: `webby-ladybird`, a conda-forge toolchain, then the Nim front end |
| `conda/webby-ladybird`, `conda/webby` | rattler-build recipes for the Ladybird runtime and the app |
| `scripts/publish_conda.sh` | Builds a recipe and uploads it to prefix.dev (`scripts/publish_conda.sh [webby-ladybird\|webby]`, needs `PREFIX_API_KEY`) |
| `scripts/build_ladybird.sh` | Clones Ladybird, applies the patches, links `native/` in, builds `libwebby.so` and the helper processes |
| `scripts/fly_build.sh`, `scripts/modal_build.sh` | The source build on a remote build machine |
| `.github/workflows/publish.yml` | CI: on every push to `main`, publishes `webby` (and `webby-ladybird` when its recipe changes) to prefix.dev |
| `.github/workflows/nim-android-apk.yml` | CI: on every push to `main` that touches the front end, builds the Android APK and publishes it as a `webby-nim-android-<version>` GitHub Release |
| `.github/workflows/prebuilt-release.yml` | Publishes a prebuilt Ladybird tarball as the `webby-prebuilt-<version>` GitHub Release that `webby-ladybird` packages |

## Building Ladybird from source (advanced)

You only need this to change `native/` or move to a different Ladybird commit; otherwise `webby-ladybird` already
has the build. Ladybird's own
[build prerequisites](https://github.com/LadybirdBrowser/ladybird/blob/master/Documentation/BuildInstructionsLadybird.md)
apply (clang ≥ 19 or gcc ≥ 14, CMake ≥ 3.30, Rust, ninja, nasm, autoconf…), minus Qt. Then:

```sh
scripts/build_ladybird.sh   # first run builds vcpkg deps (Skia, ICU, ANGLE, ffmpeg…) and takes a while
WEBBY_LADYBIRD_PREFIX=$PWD/third_party/ladybird/Build/release pixi run webby https://example.com
```

`WEBBY_LADYBIRD_PREFIX` points at a Ladybird prefix containing `lib/libwebby.so`, `libexec/WebContent` (and the
other helpers) and `share/Lagom`. Setting it also overrides `webby-ladybird` under `pixi run webby`.

Two things to know:

- **x86-64-v3.** Ladybird defaults to `-march=native`, which produces binaries that crash with SIGILL on any CPU
  other than the build host's. `build_ladybird.sh` turns on `ENABLE_CI_BASELINE_CPU`, which targets x86-64-v3 like
  Ladybird's own CI, so the result runs on any AVX2-era machine. Keep it on for anything you publish.
- **glibc.** The binaries need at least the glibc of the machine that built them. The published `webby-ladybird`
  is built on Ubuntu 22.04 by `scripts/portable_build.sh` (clang 21 and libstdc++ 14 from their apt repositories),
  hence glibc 2.35; the newer libstdc++ comes from conda-forge at run time. `scripts/pack_prebuilt.sh` packs the
  build and prints the glibc it needs; keep the `__glibc` run requirement in `conda/webby-ladybird/recipe.yaml` and
  the `glibc` in `pixi.toml` in step with it.

To publish a new runtime, bump the version or build number in `conda/webby-ladybird/recipe.yaml` and run
`scripts/publish_conda.sh`.

## Android

An APK for arm64 phones on Android 11 or newer ("Webby", `dev.webby.nim`) is attached to the
`webby-nim-android-*` GitHub Releases: download it on the phone, allow installs from your browser or file manager,
and open it. It runs the same Nim front end as the desktop under nimkit's Android host (`nim/android-kit`); the
platform services (the password vault's key in the Android Keystore, location, notifications, downloads, home
screen shortcuts for web apps) come from its Java host.

CI builds the APK from a prebuilt native part (Ladybird's libraries, helpers and resources) named in
`scripts/android/native.env`. To rebuild that part (on a Linux x86-64 host with ~150 GB free):

```sh
scripts/android/setup_toolchain.sh             # Android SDK + NDK and Rust's Android target (in /build/android-tools)
LADYBIRD_DIR=/path/to/ladybird scripts/android/build_ladybird.sh   # cross-compiles Ladybird and libwebby.so
LADYBIRD_DIR=/path/to/ladybird scripts/android/pack_native.sh native.tar.zst
nim/android-kit/build.sh native.tar.zst        # the APK, in nim/android-kit/build/
GH_TOKEN=... scripts/android/release_native.sh <version> native.tar.zst   # then update native.env
```

The helper processes (WebContent, RequestServer, ...) are plain executables shipped as `lib<Name>.so` in the APK and
run from the app's native library directory; `LadybirdRuntime.java` unpacks Ladybird's resources and points it at
them. Patches 0005 to 0009 make Ladybird's Android build work.

## Status

Tabs (pinned, vertical, saved sessions, restored at start), the address bar with suggestions, history, bookmarks,
passwords and passkeys, end-to-end encrypted sync, find in page, site permissions, notifications, location,
downloads, web apps, incognito windows, an ad blocker and page summaries. Frames are copied through the CPU
(Ladybird's CPU painting mode).

Passwords and passkeys share one encrypted vault per profile (`$WEBBY_PROFILE`, default `default`):
`${XDG_DATA_HOME:-~/.local/share}/webby/profiles/<profile>/vault.json`, AES-256-GCM with a random key kept in the
desktop keyring (Secret Service via libsecret: GNOME Keyring, KWallet, KeePassXC). With no keyring the key goes in
`vault.key` next to the vault (mode 0600) and the vault screen says so; `WEBBY_VAULT_KEYRING=0` forces that. The key
button in the toolbar opens the vault screen: search, show/copy, add, edit and delete passwords, delete passkeys, and
re-allow sites marked "never save".

Passwords: a small script in each page (`nim/src/scripts/passwords.js`) reports logins to the app through
`prompt()` calls the view swallows (`webby_view_set_message_prefix`). After a form submit, Enter or a click on a sign-in
button, a bar offers Save / Not now / Never for this site (or Update when the password changed). On a page with a
login form, one saved account is filled in straight away; with several, the bar offers a choice. Passwords are only
offered on the exact origin they were saved on, and only in the top-level page (not iframes).

Passkeys: `navigator.credentials.create()` / `.get()` with `publicKey` work against a software authenticator in
the shim (`native/Authenticator.cpp`): ES256 keys, "none" attestation. They live in the vault: at startup the app
hands them to libwebby (`webby_passkeys_use_vault`) and saves new ones as soon as they're created. An older
plaintext `${XDG_DATA_HOME:-~/.local/share}/webby/passkeys.json` (or `WEBBY_PASSKEYS_FILE`) is moved into the vault
and deleted; on a runtime without vault support passkeys stay in that file. Every ceremony is confirmed in a
dialog. The keys are not hardware-backed, the dialog click is the only user verification even though the
authenticator reports UV, and conditional (autofill) mediation is not supported yet.

Bookmarks: the star in the address bar or Ctrl+D bookmarks the page (onto the bookmarks bar, with a dialog to rename
it or pick a folder); on a bookmarked page it edits or removes the bookmark. The bar under the toolbar opens links and
folder menus, middle-click opens a link in a new tab, right-click offers open in new tab (open all for a folder), edit and
delete, and Ctrl+Shift+B shows or hides it. The bookmark manager (Ctrl+Shift+O, or
the bookmarks button in the toolbar) has a folder tree, search, edit/move/delete, drag to reorder, new folders,
and import/export of the `bookmarks.html` format other browsers use. They are stored per profile in
`${XDG_DATA_HOME:-~/.local/share}/webby/profiles/<profile>/bookmarks.json` (or `WEBBY_BOOKMARKS_FILE`); the code is in
`nim/src/features/bookmarks/`.

Web apps (PWAs): when a page links a web app manifest (`<link rel="manifest">`), an install button shows in the
address bar. Installing saves the app under `${XDG_DATA_HOME:-~/.local/share}/webby/apps/<app>/` (its icon converted
to PNG, or kept as SVG) and writes a `dev.webby.WebApp-<app>.desktop` launcher to `${XDG_DATA_HOME}/applications/`,
so it shows in the desktop's app menu. The launcher sets `WEBBY_APP_ID`, `WEBBY_APP_NAME` and `WEBBY_APP_ICON`, which
the front end (`nim/src/features/pwa.nim`) turns into the window's application id (Wayland app id and X11 WM_CLASS),
title and icon, so the app gets its own name, icon and dock entry. The launcher runs `webby --app=<start_url>`: a window with just the page, no
toolbar; pages outside the manifest's `scope` get a thin strip with their host and an "Open in Webby" button. On an
installed app's page the button opens the app or uninstalls it. Code: `nim/src/features/pwa/`. On Android installing
pins a home screen shortcut.
Service workers don't run: Ladybird (at `LADYBIRD_COMMIT`) accepts `navigator.serviceWorker.register()` but never
starts the worker (`ServiceWorker/Job.cpp`: "FIXME: Actually create service worker"), so there are no install,
activate or fetch events, and `caches` (CacheStorage) is in memory only. In their place webby has an offline mode
(`nim/src/features/pwa.nim`, `patches/0003-offline-disk-cache.patch`): when the machine has no default route,
RequestServer answers every fetch from Ladybird's HTTP disk cache only, expired copies included, so pages and apps
opened before still load (as they were last time; anything not cached fails at once). A cloud icon in the address
bar, or a strip in an app window, shows it. `WEBBY_OFFLINE=1` forces it on, `WEBBY_OFFLINE=0` off. Site logic in a
worker (custom offline pages, background sync, push) doesn't run. Apps' localStorage/IndexedDB is shared with the
browser profile.
