#!/usr/bin/env bash
# Multi-process webby in wasm (patches/0018): webby-headless is LibWebView's browser process, and it starts
# WebContent, Compositor, RequestServer and ImageDecoder as it does natively. Each is its own .wasm, run by compat's
# posix_spawn as a latha:proc child instance of the same latha-run, talking over latha:proc channels, with page
# bitmaps and other AnonymousBuffers in latha:proc shared memory (latha-gui >= 0.4).
# It screenshots a local page twice, as a file: URL and from a local HTTP server (style sheet, PNG and fetch() all
# through RequestServer, and the navigation response handed from one RequestServer to another and on to WebContent),
# and checks pixels. With HTTPS=1 (or URL=...) it also screenshots a real https page (default https://example.com/).
#   tests/multiprocess.sh BUILD_DIR LADYBIRD_SRC OUT_DIR
#     BUILD_DIR/bin has webby-headless, WebContent, Compositor, RequestServer and ImageDecoder; LADYBIRD_SRC has Base/res
# env: WASM_TOOLS, WEBBY_WASI_ADAPTER (wasi_snapshot_preview1.command.wasm), LATHA_RUN (latha-gui >= 0.4)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); bin=$(cd "$1/bin" && pwd); res=$(cd "$2/Base/res" && pwd)
mkdir -p "$3"; out=$(cd "$3" && pwd); site=$out/site; mkdir -p "$site" "$out/home"
pixel() { python3 "$here/png-pixel.py" "$@"; }

# The background is in style.css, the red square is box.png, and the green bar only shows once fetch() has read
# data.txt.
cat > "$site/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><link rel="stylesheet" href="style.css"></head>
<body><img src="box.png" width="100" height="100"><div id="bar"></div>
<script>
fetch("data.txt").then(r => r.text()).then(t => { if (t.trim() === "ok") document.getElementById("bar").className = "shown"; });
</script></body></html>
HTML
cat > "$site/style.css" <<'CSS'
html, body { margin: 0; background: #3366cc; }
img { display: block; }
#bar { position: absolute; left: 200px; top: 0; width: 100px; height: 100px; background: #3366cc; }
#bar.shown { background: #00ff00; }
CSS
echo ok > "$site/data.txt"
pixel --make 100 100 ff0000 "$site/box.png"

port=$((20000 + RANDOM % 20000))
(cd "$site" && exec python3 -m http.server "$port" --bind 127.0.0.1 > "$out/http.log" 2>&1) & server=$!
trap 'kill $server 2>/dev/null' EXIT
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done

for p in webby-headless WebContent Compositor RequestServer ImageDecoder; do
  "${WASM_TOOLS:-wasm-tools}" component new "$bin/$p" --adapt "wasi_snapshot_preview1=${WEBBY_WASI_ADAPTER:?}" -o "$out/$p.wasm"
done

# The helpers are found next to webby-headless.wasm (the instance's "."). Profile, cache and runtime directories go
# under /home. The first run compiles each module (tens of seconds, cached after), so the screenshot waits a while.
shot() {
  local png=$1; shift
  rm -f "$out/$png"
  (cd "$out" && HOME=/home XDG_RUNTIME_DIR=/home/run XDG_CONFIG_HOME=/home/config XDG_DATA_HOME=/home/data \
    XDG_CACHE_HOME=/home/cache XDG_DATA_DIRS=/usr/share timeout "${TIMEOUT:-600}" "${LATHA_RUN:-latha-run}" \
    --dir /usr/share/fonts --dir "$res::/res" --dir "$site::/site" --dir "$out/home::/home" --dir /etc/ssl --dir "$out::/out" \
    webby-headless.wasm --headless=screenshot --screenshot-path "/out/$png" --screenshot-delay "${DELAY:-5}" "$@")
  [ -s "$out/$png" ]
}
# fetch() of a file: URL fails (cors mode needs http(s)), so the bar is only checked over HTTP.
check() {
  local img bar bg
  { read -r img; read -r bar; read -r bg; } < <(pixel "$out/$1" 50 50 250 50 600 400)
  echo "  image $img, fetch() bar $bar, background $bg"
  [ "$img" = ff0000 ] && [ "$bar" = "$2" ] && [ "$bg" = 3366cc ]
}

echo "== file: page"
shot file.png file:///site/index.html
check file.png 3366cc
echo "== http page"
shot http.png "http://127.0.0.1:$port/index.html"
check http.png 00ff00

https=${URL:-}; if [ -z "$https" ] && [ "${HTTPS:-0}" = 1 ]; then https=https://example.com/; fi
if [ -n "$https" ]; then
  echo "== $https"
  shot https.png -C /etc/ssl/certs/ca-certificates.crt "$https"
  [ "$(stat -c %s "$out/https.png")" -gt 5000 ]
fi
echo "multiprocess: ok"
