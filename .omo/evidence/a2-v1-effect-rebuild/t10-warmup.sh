#!/data/data/com.termux/files/usr/bin/bash
# Warm-up: bare runtime with real-cache symlinks; run up to 50min until boot completes (render >15KB)
set -u
BIN=/mnt/sdcard_ext4/apps/a2todo5b/beta103-press2/runtime/opencode-v1-1.18.32-beta103-press2
SB=/mnt/sdcard_ext4/apps/a2todo9/sbx-t10warm
rm -rf $SB; mkdir -p $SB/home $SB/tmp $SB/config/opencode $SB/data $SB/state $SB/cache
ln -sfn /data/data/com.termux/files/home/.npm $SB/home/.npm
export HOME=$SB/home TMPDIR=$SB/tmp TERM=xterm-256color
export XDG_CONFIG_HOME=$SB/config XDG_DATA_HOME=$SB/data XDG_STATE_HOME=$SB/state XDG_CACHE_HOME=$SB/cache
echo '{"port": 41241}' > $SB/config/opencode/service.json
cd /mnt/sdcard_ext4/apps/a2todo5b
TS=/mnt/sdcard_ext4/apps/a2todo9/t10warm.typescript
rm -f $TS
T0=$(date +%s)
script -qec "timeout 3000 $BIN" "$TS" > /dev/null 2>&1 &
PROBE=$!
DONE=0
for i in $(seq 1 200); do
  SZ=$(wc -c < $TS 2>/dev/null || echo 0)
  echo "$(date +%s) bytes=$SZ elapsed=$(( $(date +%s) - T0 ))" >> /mnt/sdcard_ext4/apps/a2todo9/t10warm.progress.log
  if [ "$SZ" -gt 15360 ]; then DONE=1; echo "RENDERED at elapsed=$(( $(date +%s) - T0 )) size=$SZ" >> /mnt/sdcard_ext4/apps/a2todo9/t10warm.progress.log; break; fi
  # 进程死了也停
  ALIVE=0
  for d in /proc/[0-9]*; do e=$(readlink $d/exe 2>/dev/null); [ "$e" = "$BIN" ] && ALIVE=1 && break; done
  [ "$ALIVE" = "0" ] && echo "PROC_EXITED at elapsed=$(( $(date +%s) - T0 ))" >> /mnt/sdcard_ext4/apps/a2todo9/t10warm.progress.log && break
  sleep 15
done
for d in /proc/[0-9]*; do e=$(readlink $d/exe 2>/dev/null); [ "$e" = "$BIN" ] && kill -9 ${d#/proc/} 2>/dev/null; done
wait $PROBE 2>/dev/null
TOTAL=$(wc -c < $TS 2>/dev/null || echo 0)
ANSI=$(LC_ALL=C grep -ac $'\x1b\[' "$TS" 2>/dev/null || true)
{
echo "== WARMUP $(date -u +%FT%TZ) done=$DONE TOTAL=$TOTAL ANSI=$ANSI elapsed=$(( $(date +%s) - T0 ))s"
echo "loglines=$(wc -l < $SB/data/opencode/log/opencode.log 2>/dev/null || echo 0)"
echo "log_tail:"; tail -6 $SB/data/opencode/log/opencode.log 2>/dev/null | cut -c1-140
} > /mnt/sdcard_ext4/apps/a2todo9/t10warm.metrics.txt
echo WARMUP_DONE
