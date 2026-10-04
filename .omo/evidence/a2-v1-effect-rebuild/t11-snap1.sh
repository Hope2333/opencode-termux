#!/bin/bash
# t11-snap1.sh — 现状快照: 核身 + 两槽锚实存 + 真实 HOME files1 残留 + 锁/socket/tmp 清单（只读）
echo "== T11 SNAP1 $(date -u +%FT%TZ) =="
echo "--- identity ---"
uname -r; getprop ro.product.model 2>/dev/null || true; id
echo "--- slots: opencode1 anchor presence ---"
for C in files files1; do
  B=/data/data/com.termux/$C/usr/lib/opencode1/runtime/opencode
  if [ -x "$B" ]; then
    V=$("$B" --version 2>&1 | head -1)
    SHA=$(sha256sum "$B" 2>/dev/null | cut -c1-8)
    echo "slot=$C PRESENT sha=$SHA ver=$V"
  else
    echo "slot=$C ABSENT ($B)"
  fi
done
echo "--- files1 slot top-level (content identity of the other container) ---"
ls /data/data/com.termux/files1/ 2>/dev/null | head -20
echo "--- real HOME opencode data dirs: files1 residue grep ---"
H=/data/data/com.termux/files/home
for d in "$H/.local/share/opencode" "$H/.local/state/opencode" "$H/.config/opencode" "$H/.opencode" "$H/.cache/opencode"; do
  if [ -e "$d" ]; then
    echo "== $d =="
    grep -rl "files1" "$d" 2>/dev/null | head -20
  else
    echo "== $d = (absent)"
  fi
done
echo "--- lock/socket/state file listing ---"
for d in "$H/.local/share/opencode" "$H/.local/state/opencode" "$H/.opencode" "$H/.cache/opencode"; do
  [ -d "$d" ] && { echo "== $d =="; ls -la "$d" 2>/dev/null | head -25; find "$d" -maxdepth 2 -type s 2>/dev/null; }
done
echo "--- service.json (pid/port registration) ---"
for f in "$H/.local/state/opencode/service.json" "$H/.cache/opencode/service.json"; do
  [ -f "$f" ] && { echo "== $f =="; cat "$f"; echo; }
done
echo "--- \$PREFIX/tmp residue (bun .so / opentui extraction) ---"
ls -la /data/data/com.termux/files/usr/tmp/ 2>/dev/null | grep -iE "so|opentui|bun|lock" | head -20
echo "--- files1/home opencode data dirs (other container's home, read-only peek) ---"
for d in /data/data/com.termux/files1/home/.local/share/opencode /data/data/com.termux/files1/home/.local/state/opencode; do
  [ -d "$d" ] && { echo "== $d =="; ls -la "$d" 2>/dev/null | head -12; grep -rl "files1" "$d" 2>/dev/null | head -10; }
done
echo "--- config dir of current live container home (5c-era config source) ---"
ls -la "$H/.config/opencode" 2>/dev/null | head -15
grep -n "files1" "$H/.config/opencode/"*.json 2>/dev/null | head -10
echo "== SNAP1 END =="
