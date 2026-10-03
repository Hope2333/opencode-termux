BIN=/mnt/sdcard_ext4/apps/a2todo5b/beta103-press2/runtime/opencode-v1-1.18.32-beta103-press2
OFF=$(grep -aob "booting location services" "$BIN" 2>/dev/null | head -1 | cut -d: -f1)
echo OFFSET=$OFF
if [ -n "$OFF" ]; then
  START=$((OFF-1500)); dd if="$BIN" bs=1 skip=$START count=3000 2>/dev/null | LC_ALL=C tr -c '[:print:]' '.' | fold -w 160
fi
echo PRESS2A_METRICS_NOW:
cat /mnt/sdcard_ext4/apps/a2todo9/press2a.metrics.txt 2>/dev/null || echo "not yet"
echo PRESS2A_ALIVE:
for p in /proc/[0-9]*/cmdline; do c=$(tr '\0' ' ' < $p 2>/dev/null); case "$c" in *beta103-press2*) echo "  alive ${p#/proc/}";; esac; done
