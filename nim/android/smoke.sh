#!/usr/bin/env bash
# Smoke test for webby-nim on Android, on a running emulator or device (adb): installs the APK, opens pages, scrolls,
# types, long-presses, and saves screenshots plus logcat in <out dir>. Prints a summary; exits non-zero if the app
# died or never drew a page. Needs an arm64 phone: x86_64 emulators' ARM translation can't run Ladybird's libraries
# (they use LSE atomics). Needs python3 with Pillow for the blank-page check.
#
# Usage: nim/android/smoke.sh <apk> <out dir>
set -uo pipefail
APK="$1"
OUT="$2"
mkdir -p "$OUT"
PKG=dev.webby.nim
shot() { adb exec-out screencap -p > "$OUT/$1.png"; echo "screenshot $1"; }
alive() { adb shell pidof "$PKG" > /dev/null; }

adb shell getprop ro.product.cpu.abilist
# A phone-sized screen (the emulator's default skin is tiny).
adb shell wm size 1080x2280
adb shell wm density 420
adb install -r "$APK" || exit 1
adb logcat -c
adb shell am start -W -a android.intent.action.VIEW -d "https://example.com/" -n "$PKG/.MainActivity"
# First start unpacks Ladybird's resources and starts its helpers under ARM translation: give it time.
for i in $(seq 1 60); do
    sleep 2
    adb logcat -d -s webby-nim | grep -q "Ladybird started" && break
done
sleep 25
shot 1-example
adb shell ps -A -o PID,RSS,NAME | grep -iE "webby|WebContent|RequestServer|ImageDecoder|Compositor" | tee "$OUT/processes.txt"

SIZE=$(adb shell wm size | grep -oE '[0-9]+x[0-9]+' | tail -1)
W=${SIZE%x*}
H=${SIZE#*x}
adb shell "am start -a android.intent.action.VIEW -d 'https://en.wikipedia.org/wiki/Nim_(programming_language)' -n $PKG/.MainActivity"
sleep 40
shot 2-wikipedia
for i in 1 2 3; do adb shell input swipe $((W / 2)) $((H * 3 / 4)) $((W / 2)) $((H / 4)) 200; sleep 2; done
sleep 5
shot 3-scrolled
# Long-press in the middle of the page (a link if one is there): the context menu.
adb shell input swipe $((W / 2)) $((H / 2)) $((W / 2)) $((H / 2)) 1200
sleep 4
shot 4-longpress
adb shell input keyevent 4   # dismiss
sleep 1
# The URL field (top bar, middle): type an address.
adb shell input tap $((W / 2)) $((H * 6 / 100))
sleep 2
adb shell input text "example.org"
adb shell input keyevent 66
sleep 20
shot 5-typed-url
adb logcat -d > "$OUT/logcat.txt"
adb logcat -d -b crash > "$OUT/crash.txt"

echo "---- webby-nim log"
grep -E " webby-nim" "$OUT/logcat.txt" | tail -60
echo "---- app, linker and translation messages"
grep -iE "dev\.webby\.nim|libwebby|UnsatisfiedLink|linker|ndk_translation|houdini|FATAL|Fatal signal|has died|WebContent|RequestServer" "$OUT/logcat.txt" | tail -120
echo "---- crashes"
tail -60 "$OUT/crash.txt"
grep -E "F DEBUG|AndroidRuntime" "$OUT/logcat.txt" | tail -60
if ! alive; then echo "FAIL: $PKG is not running"; exit 1; fi
python3 - "$OUT" <<'EOF'
import os, sys
from PIL import Image
# How much of each screenshot's page area (below the toolbar) isn't its most common colour: a blank page is ~0.
bad = False
for name in sorted(os.listdir(sys.argv[1])):
    if not name.endswith(".png"): continue
    im = Image.open(os.path.join(sys.argv[1], name)).convert("RGB")
    w, h = im.size
    area = im.crop((0, h * 15 // 100, w, h * 90 // 100)).resize((w // 8, h * 75 // 800))
    colors = area.getcolors(1 << 20)
    total = sum(c for c, _ in colors)
    varied = 1 - max(c for c, _ in colors) / total
    print(f"{name}: {w}x{h}, page area {varied:.0%} not the background colour, {len(colors)} colours")
    if name.startswith(("1-", "2-")) and varied < 0.02: bad = True
if bad:
    print("FAIL: a page looks blank"); sys.exit(1)
EOF
