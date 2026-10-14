#!/usr/bin/env python3
"""Writes Android vector drawables (res/drawable/ic_<name>.xml) for the Material icons the shell uses, from the
glyph outlines the desktop Nim front end compiles in (nim/src/icondata.nim), so both look the same.

Usage: gen_icons.py <icondata.nim> <res dir> name..."""
import os
import re
import sys

source, res, names = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(source).read()
em = int(re.search(r"const iconEm\* = (\d+)", text).group(1))
paths = dict(re.findall(r'^\s*"([a-z0-9_]+)": "([^"]*)"', text, re.M))
os.makedirs(os.path.join(res, "drawable"), exist_ok=True)
for name in names:
    with open(os.path.join(res, "drawable", f"ic_{name}.xml"), "w") as f:
        f.write(f'''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp" android:viewportWidth="{em}" android:viewportHeight="{em}">
    <path android:fillColor="#FF000000" android:pathData="{paths[name]}"/>
</vector>
''')
