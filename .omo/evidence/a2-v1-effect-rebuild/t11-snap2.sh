#!/bin/bash
# t11-snap2.sh — 深挖: locks 内容 + bun tmp 产物 + 锚 bundle LocationService 代码段（只读）
echo "== T11 SNAP2 $(date -u +%FT%TZ) =="
H=/data/data/com.termux/files/home
echo "--- locks dir deep ---"
find "$H/.local/state/opencode/locks" -maxdepth 3 -exec ls -la {} \; 2>/dev/null | head -30
echo "--- locks file contents (small files) ---"
find "$H/.local/state/opencode/locks" -type f -size -4k 2>/dev/null | while read f; do echo "== $f =="; cat "$f"; echo; done
echo "--- other container locks (files1/home) ---"
find /data/data/com.termux/files1/home/.local/state/opencode/locks -maxdepth 3 -exec ls -la {} \; 2>/dev/null | head -20
echo "--- latest/ dir (state machine?) ---"
find "$H/.local/state/opencode/latest" -maxdepth 3 2>/dev/null | head -20
echo "--- PREFIX/tmp full listing ---"
ls -la /data/data/com.termux/files/usr/tmp/ | head -25
echo "--- bun-termux-cache ---"
find /data/data/com.termux/files/usr/tmp/bun-termux-cache -maxdepth 2 2>/dev/null | head -15
echo "--- which binary wrote the bun .so: check serve runtime (2.0.12) vs anchor ---"
sha256sum /data/data/com.termux/files/usr/lib/opencode/runtime/opencode 2>/dev/null | cut -c1-16
echo "--- anchor bundle: code around 'booting location services' ---"
BIN=/data/data/com.termux/files/usr/lib/opencode1/runtime/opencode
python3 - "$BIN" <<'PYEOF'
import sys, re
data = open(sys.argv[1], 'rb').read()
for needle in [b"booting location services", b"location services booted", b"LocationServiceMap"]:
    idx = data.find(needle)
    print(f"### needle={needle.decode()} idx={idx}")
    if idx < 0: continue
    start = max(0, idx-2500); end = min(len(data), idx+2500)
    chunk = data[start:end]
    txt = re.sub(rb'[^\x20-\x7e\n\t]', b'.', chunk).decode('ascii', 'replace')
    print(txt)
    print()
PYEOF
echo "== SNAP2 END =="
