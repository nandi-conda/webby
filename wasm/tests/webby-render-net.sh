#!/usr/bin/env bash
# webby-render loading a page over the network (patches/0010): a page on a local HTTP server whose style sheet, image
# and fetch() all come through RequestServer, rendered to a PNG and checked pixel by pixel. First with RequestServer in
# the same module, then with RequestServer.wasm in a latha:proc child instance (latha-run). With
# HTTPS=1 (or URL=...) it also renders a real https page (default https://example.com/) both ways.
#   tests/webby-render-net.sh BUILD_DIR LADYBIRD_SRC OUT_DIR
#     BUILD_DIR/bin has webby-render, webby-render-latha and RequestServer; LADYBIRD_SRC has Base/res
# env: WASM_TOOLS, WEBBY_WASI_ADAPTER (wasi_snapshot_preview1.command.wasm), LATHA_RUN, and what tools/wasi-run.py needs
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); bin=$(cd "$1/bin" && pwd); res=$(cd "$2/Base/res" && pwd)
mkdir -p "$3"; out=$(cd "$3" && pwd); site=$out/site; mkdir -p "$site"
pixel() { python3 "$here/png-pixel.py" "$@"; }

# The page: the background is in style.css, a red square is box.png, and the green bar only shows once fetch() has
# read data.txt. Nothing here is a file: URL; it all has to come from RequestServer.
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
url=http://127.0.0.1:$port/index.html

check() {
  local png=$1
  read -r img bar bg < <(pixel "$png" 50 50 250 50 600 400 | tr '\n' ' ')
  echo "  image $img, fetch() bar $bar, background $bg"
  [ "$img" = ff0000 ] && [ "$bar" = 00ff00 ] && [ "$bg" = 3366cc ]
}
https=${URL:-}; if [ -z "$https" ] && [ "${HTTPS:-0}" = 1 ]; then https=https://example.com/; fi
ca=/etc/ssl/certs/ca-certificates.crt

# Both run under latha-run: its wasmtime has wasm exceptions (setjmp/longjmp) and sockets on, and runs latha:proc
# children. (wasmtime 36's CLI rejects the exception instructions; wasmtime-py has no TCP for components.)
for p in RequestServer webby-render webby-render-latha; do
  "${WASM_TOOLS:-wasm-tools}" component new "$bin/$p" --adapt "wasi_snapshot_preview1=${WEBBY_WASI_ADAPTER:?}" -o "$out/$p.wasm"
done
latha() { (cd "$out" && XDG_DATA_DIRS=/usr/share "${LATHA_RUN:-latha-run}" --dir /usr/share/fonts --dir "$res::/res" --dir /etc/ssl "$@"); }
for mode in one two; do
  if [ $mode = one ]; then echo "== RequestServer in the same module"; run=(webby-render.wasm)
  else echo "== RequestServer.wasm in a child instance"; run=(webby-render-latha.wasm --spawn RequestServer.wasm); fi
  latha "${run[@]}" --theme /res/themes/Default.ini -o $mode.png "$url"
  check "$out/$mode.png"
  if [ -n "$https" ]; then
    latha "${run[@]}" --theme /res/themes/Default.ini -C "$ca" -o https-$mode.png "$https"
    [ "$(stat -c %s "$out/https-$mode.png")" -gt 5000 ]
  fi
done
echo "webby-render-net: ok"
