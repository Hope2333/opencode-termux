#!/bin/bash
# t11-snap4.sh — beta103-press2 未压缩段 location services 代码提取 + $PREFIX/tmp/opencode 共享态 + .npm 残留（只读）
echo "== T11 SNAP4 $(date -u +%FT%TZ) =="
echo "--- \$PREFIX/tmp/opencode dir (shared cross-home state, created 10:25Z by serve) ---"
find /data/data/com.termux/files/usr/tmp/opencode -maxdepth 3 -exec ls -lad {} \; 2>/dev/null | head -30
echo "--- contents of small files there ---"
find /data/data/com.termux/files/usr/tmp/opencode -type f -size -8k 2>/dev/null | while read f; do echo "== $f =="; head -c 600 "$f"; echo; done
echo "--- real ~/.npm files1 residue (targeted, count only) ---"
N=/data/data/com.termux/files/home/.npm
[ -d "$N" ] && { du -s "$N" 2>/dev/null; grep -rl "files1" "$N" 2>/dev/null | head -5; echo "npm_grep_done"; } || echo "no ~/.npm"
echo "--- ~/.bun residue ---"
B=/data/data/com.termux/files/home/.bun
[ -d "$B" ] && { du -s "$B" 2>/dev/null; grep -rl "files1" "$B" 2>/dev/null | head -5; echo "bun_grep_done"; } || echo "no ~/.bun"
echo "--- opencode.db strings: files1 / files path refs ---"
python3 - <<'PYEOF'
import re
db = open('/data/data/com.termux/files/home/.local/share/opencode/opencode.db','rb').read()
for pat in [b'files1', b'/data/data/com.termux/files/']:
    hits = [m.start() for m in re.finditer(re.escape(pat), db)]
    print(f"pat={pat.decode()} hits={len(hits)}")
    for h in hits[:3]:
        s = re.sub(rb'[^\x20-\x7e]', b'.', db[max(0,h-120):h+180]).decode('ascii','replace')
        print("  ctx:", s)
PYEOF
echo "--- beta103-press2: code around 'booting location services' (wide window) ---"
BIN=/mnt/sdcard_ext4/apps/a2todo5b/beta103-press2/runtime/opencode-v1-1.18.32-beta103-press2
python3 - "$BIN" <<'PYEOF'
import sys, re
data = open(sys.argv[1], 'rb').read()
idx = data.find(b"booting location services")
print(f"idx={idx}")
if idx >= 0:
    start = max(0, idx-6000); end = min(len(data), idx+3000)
    txt = re.sub(rb'[^\x20-\x7e\n\t]', b'.', data[start:end]).decode('ascii', 'replace')
    print(txt)
PYEOF
echo "== SNAP4 END =="
