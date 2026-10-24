#!/usr/bin/env bash
# Builds webby-x86_64.AppImage (+ .zsync) from the conda packages already published to prefix.dev/nandi-testing,
# so the AppImage is exactly the `pixi global install webby` of the same version: webby (Nim front end) and
# webby-ladybird (the engine, built on Ubuntu 22.04, so glibc 2.35 or newer is needed).
#
#   scripts/build_appimage.sh VERSION [OUT_DIR]     e.g. scripts/build_appimage.sh 2026.10.24.483 dist
#
# Needs pixi and curl. The conda env goes in AppDir/usr as is, minus what a browser never uses (headers, static
# libs, Python, OCR data); AppRun points the env's libraries at their files inside the mount (conda bakes the
# install path into them). The update information makes the AppImage self-updating with zsync from the rolling
# `appimage` GitHub release: webby itself (nim/src/features/update.nim, with the zsync2 bundled here) and tools
# like AppImageUpdate or Gear Lever read it.
set -euo pipefail

version="${1:?usage: build_appimage.sh VERSION [OUT_DIR]}"
out="$(mkdir -p "${2:-dist}" && cd "${2:-dist}" && pwd)"
here="$(cd "$(dirname "$0")/.." && pwd)"
channel="${CHANNEL:-nandi-testing}"
update_info="gh-releases-zsync|nandi-conda|webby|appimage|webby-x86_64.AppImage.zsync"
work="${WORK_DIR:-$(mktemp -d)}"
tools="$work/tools"
mkdir -p "$tools"

# appimagetool (also writes the .zsync) and AppImageUpdate's zsync2, which webby runs to update itself.
fetch() { [ -s "$2" ] || curl -fsSL --retry 4 -o "$2" "$1"; chmod +x "$2"; }
fetch https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage \
  "$tools/appimagetool"
fetch https://github.com/AppImage/AppImageUpdate/releases/download/continuous/appimageupdatetool-x86_64.AppImage \
  "$tools/appimageupdatetool"
export APPIMAGE_EXTRACT_AND_RUN=1   # no FUSE in CI containers

# The env, solved and installed by pixi like `pixi global install` does.
mkdir -p "$work/env"
cat > "$work/env/pixi.toml" <<EOF
[workspace]
name = "webby-appimage"
channels = ["https://prefix.dev/$channel"]
platforms = ["linux-64"]

[system-requirements]
libc = "2.35"

[dependencies]
webby = "==$version"
EOF
(cd "$work/env" && pixi install)
envdir="$work/env/.pixi/envs/default"

app="$work/AppDir"
rm -rf "$app"
mkdir -p "$app"
cp -a "$envdir" "$app/usr"
usr="$app/usr"
# Only webby's own records: ⋮ > About reads webby-ladybird's version from them.
find "$usr/conda-meta" -type f ! -name 'webby-*.json' -delete
rm -rf "$usr"/include "$usr"/share/{doc,man,info,gtk-doc,gir-1.0,tessdata,bash-completion,zsh} \
  "$usr"/lib/python3* "$usr"/lib/{tcl,tk,itcl,tdbc}* "$usr"/lib/pkgconfig "$usr"/share/pkgconfig "$usr"/lib/cmake \
  "$usr"/etc/conda "$usr"/bin/python* "$usr"/bin/pydoc* "$usr"/bin/idle* "$usr"/bin/2to3*
find "$usr/lib" -name '*.a' -delete

# Fonts: the env's fonts.conf names the install path, so the AppImage has its own with paths relative to itself.
# It lives where webby.sh's file does (share/Lagom/fonts), the one place Ladybird's sandboxed helpers may read.
fonts_conf="$usr/lib/webby-ladybird/share/Lagom/fonts/webby-appimage-fonts.conf"
cat > "$fonts_conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- The AppImage's fontconfig file (AppRun sets FONTCONFIG_FILE). The relative dirs are from this file's folder,
     usr/lib/webby-ladybird/share/Lagom/fonts, so they hold wherever the AppImage is mounted; the relative include
     is looked up in FONTCONFIG_PATH (AppRun: usr/etc/fonts), as <include> has no prefix="relative". -->
<fontconfig>
  <dir>/usr/share/fonts</dir>
  <dir>/usr/local/share/fonts</dir>
  <dir prefix="xdg">fonts</dir>
  <dir>~/.fonts</dir>
  <dir prefix="relative">../../../../../fonts</dir>
  <dir prefix="relative">../../../../../share/fonts</dir>
  <include ignore_missing="yes">conf.d</include>
  <cachedir prefix="xdg">fontconfig</cachedir>
</fontconfig>
EOF

# zsync2 and the libraries it doesn't find on every system, with its $ORIGIN/../lib RUNPATH.
(cd "$work" && rm -rf squashfs-root && for f in usr/bin/zsync2 "usr/lib/*"; do
  "$tools/appimageupdatetool" --appimage-extract "$f" > /dev/null; done)
mkdir -p "$usr/lib/webby/zsync2/bin" "$usr/lib/webby/zsync2/lib"
cp "$work/squashfs-root/usr/bin/zsync2" "$usr/lib/webby/zsync2/bin/"
cp -L "$work"/squashfs-root/usr/lib/lib{ssl,crypto,gcrypt}.so.* "$usr/lib/webby/zsync2/lib/"
cp -L "$usr"/lib/libgpg-error.so.0 "$usr/lib/webby/zsync2/lib/"
rm -rf "$work/squashfs-root"

install -m 755 "$here/conda/webby/AppRun" "$app/AppRun"
cat > "$app/dev.webby.webby.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Webby
GenericName=Web Browser
Comment=Web browser on Ladybird's LibWeb and LibJS
Exec=webby %u
Icon=dev.webby.webby
Terminal=false
Categories=Network;WebBrowser;
Keywords=web;browser;internet;ladybird;
MimeType=text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
StartupWMClass=dev.webby.webby
X-AppImage-Version=VERSION
EOF
sed -i "s/^X-AppImage-Version=.*/X-AppImage-Version=$version/" "$app/dev.webby.webby.desktop"
cp "$usr/share/icons/hicolor/256x256/apps/dev.webby.webby.png" "$app/dev.webby.webby.png"
ln -sf dev.webby.webby.png "$app/.DirIcon"

# appimagetool names the .zsync after the AppImage and writes it next to it.
(cd "$out" && rm -f webby-x86_64.AppImage webby-x86_64.AppImage.zsync &&
  ARCH=x86_64 VERSION="$version" "$tools/appimagetool" --no-appstream -u "$update_info" "$app" webby-x86_64.AppImage)
ls -la "$out"/webby-x86_64.AppImage*
