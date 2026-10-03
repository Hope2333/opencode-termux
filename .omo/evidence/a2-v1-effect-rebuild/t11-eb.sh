#!/data/data/com.termux/files/usr/bin/bash
# t11-eb.sh — E-B only: fakehome 全新环境（零 config 零缓存零链接）跑锚
set -u
BASE=/mnt/sdcard_ext4/apps/a2todo9
AK=/data/data/com.termux/files/usr/lib/opencode1
BIN=$AK/runtime/opencode
OUT=$BASE/t11
mkdir -p $OUT
LDENV="env LD_LIBRARY_PATH=$AK:$AK/pty LD_PRELOAD=$AK/libopencode-crhandler.so:$AK/libepoll-compat.so BUN_PTY_LIB=$AK/pty/librust_pty_arm64_musl_patched.so"

SB=$BASE/sbx-t11eb
rm -rf $SB; mkdir -p $SB/home $SB/tmp $SB/config/opencode $SB/data $SB/state $SB/cache
export HOME=$SB/home TMPDIR=$SB/tmp
export XDG_CONFIG_HOME=$SB/config XDG_DATA_HOME=$SB/data
export XDG_STATE_HOME=$SB/state XDG_CACHE_HOME=$SB/cache
cd /mnt/sdcard_ext4/apps/a2todo5b

TAG=t11eb
TS=$OUT/$TAG.typescript
rm -f "$TS" "$OUT/$TAG.progress.log"
echo "$TAG start=$(date -u +%FT%TZ) HOME=$HOME" >> "$OUT/summary.txt"
( for i in $(seq 1 60); do
    echo "$(date +%s) bytes=$(wc -c < "$TS" 2>/dev/null || echo 0) mem=$(awk '/MemAvailable/{print $2}' /proc/meminfo)" >> "$OUT/$TAG.progress.log"
    sleep 10
  done ) &
SAMPLER=$!
script -qec "timeout 420 $LDENV '$BIN'" "$TS" > "$OUT/$TAG.script.out" 2>&1 &
RUNNER=$!
sleep 8
BPID=""
for d in /proc/[0-9]*; do
  [ "$(readlink $d/exe 2>/dev/null)" = "$BIN" ] && BPID=${d#/proc/} && break
done
echo "$TAG binpid=$BPID" >> "$OUT/summary.txt"
wait $RUNNER; RC=$?
kill $SAMPLER 2>/dev/null
[ -n "$BPID" ] && kill -9 "$BPID" 2>/dev/null
SP=$(sed -n 's/.*"pid"[": ]*\([0-9]*\).*/\1/p' "$XDG_STATE_HOME/opencode/service.json" 2>/dev/null)
[ -n "$SP" ] && [ "$SP" != "$BPID" ] && kill -9 "$SP" 2>/dev/null
TOTAL=$(wc -c < "$TS" 2>/dev/null || echo 0)
ANSI=$(LC_ALL=C grep -ac $'\x1b\[' "$TS" 2>/dev/null || true)
LOGD=$XDG_DATA_HOME/opencode/log
echo "== $TAG $(date -u +%FT%TZ) rc=$RC TOTAL=$TOTAL ANSI=$ANSI loglines=$(wc -l < "$LOGD/opencode.log" 2>/dev/null || echo 0)" >> "$OUT/summary.txt"
echo "-- $TAG log tail:" >> "$OUT/summary.txt"
tail -5 "$LOGD/opencode.log" 2>/dev/null | cut -c1-200 >> "$OUT/summary.txt"
grep -c "location services booted" "$LOGD/opencode.log" 2>/dev/null > "$OUT/$TAG.lsvcbooted" || echo 0 > "$OUT/$TAG.lsvcbooted"
tail -c 1200 "$TS" 2>/dev/null | LC_ALL=C sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' > "$OUT/$TAG.tail-clean.txt"
echo "T11_EB_DONE rc=$RC"
