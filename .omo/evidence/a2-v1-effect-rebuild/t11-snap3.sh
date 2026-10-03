#!/bin/bash
# t11-snap3.sh — 2.0.12 serve bundle LocationService 代码提取 + pid 复用核查 + .bun .so 归属（只读）
echo "== T11 SNAP3 $(date -u +%FT%TZ) =="
echo "--- pid reuse check: lock pids alive? ---"
for P in 21754 19205 12164; do
  if [ -d /proc/$P ]; then
    echo "pid $P ALIVE: $(tr '\0' ' ' < /proc/$P/cmdline 2>/dev/null | head -c 120)"
  else
    echo "pid $P dead"
  fi
done
echo "--- current serve + related processes ---"
for d in /proc/[0-9]*/cmdline; do c=$(tr '\0' ' ' < "$d" 2>/dev/null); case "$c" in *opencode*) echo "  ${d#/proc/}: ${c:0:140}";; esac; done
echo "--- serve runtime maps of .bun .so (who uses 6b234171) ---"
for d in /proc/[0-9]*; do
  p=${d#/proc/}
  if grep -q "6b234171fedd8d8d" "$d/maps" 2>/dev/null; then
    echo "  pid $p maps 6b234171: $(tr '\0' ' ' < $d/cmdline | head -c 100)"
  fi
done
echo "--- 2.0.12 bundle: LocationService code ---"
BIN=/data/data/com.termux/files/usr/lib/opencode/runtime/opencode
python3 - "$BIN" <<'PYEOF'
import sys, re
data = open(sys.argv[1], 'rb').read()
for needle in [b"booting location services", b"location services booted", b"LocationServiceMap"]:
    idx = data.find(needle)
    print(f"\n### needle={needle.decode()} idx={idx}")
    if idx < 0: continue
    start = max(0, idx-3500); end = min(len(data), idx+3500)
    txt = re.sub(rb'[^\x20-\x7e\n\t]', b'.', data[start:end]).decode('ascii', 'replace')
    print(txt)
PYEOF
echo "== SNAP3 END =="
