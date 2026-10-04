#!/data/data/com.termux/files/usr/bin/bash
# E1r: bare runtime TUI, 5c-identical invocation; precise exe-based kill only
set -u
BIN=/mnt/sdcard_ext4/apps/a2todo5b/beta103-press2/runtime/opencode-v1-1.18.32-beta103-press2
SB=/mnt/sdcard_ext4/apps/a2todo9/sbx-t10e1r
rm -rf $SB; mkdir -p $SB/home $SB/tmp $SB/config/opencode $SB/data $SB/state $SB/cache
export HOME=$SB/home TMPDIR=$SB/tmp TERM=xterm-256color
export XDG_CONFIG_HOME=$SB/config XDG_DATA_HOME=$SB/data XDG_STATE_HOME=$SB/state XDG_CACHE_HOME=$SB/cache
echo '{"port": 41236}' > $SB/config/opencode/service.json
cd /mnt/sdcard_ext4/apps/a2todo5b
TS=/mnt/sdcard_ext4/apps/a2todo9/t10e1r.typescript
MK=/mnt/sdcard_ext4/apps/a2todo9/t10e1r.mark
rm -f $TS $MK
( for i in $(seq 1 16); do echo "$(date +%s) $(wc -c < $TS 2>/dev/null || echo 0)" >> /mnt/sdcard_ext4/apps/a2todo9/t10e1r.progress.log; sleep 10; done ) &
SAMPLER=$!
T0=$(date +%s)
{
  sleep 70; echo "S0 $(wc -c < $TS 2>/dev/null || echo 0) $(date +%s)" >> $MK
  printf 'z'; sleep 7; echo "S1 $(wc -c < $TS 2>/dev/null || echo 0)" >> $MK
  printf 'XYZPROBE9'; sleep 8; echo "S2 $(wc -c < $TS 2>/dev/null || echo 0)" >> $MK
  printf '\033[C'; sleep 7; echo "S3 $(wc -c < $TS 2>/dev/null || echo 0)" >> $MK
  sleep 20; echo "S4 $(wc -c < $TS 2>/dev/null || echo 0)" >> $MK
} | script -qec "timeout 160 $BIN" "$TS" > /mnt/sdcard_ext4/apps/a2todo9/t10e1r.script.out 2>&1 &
PROBE=$!
sleep 118
# precise kill: only processes whose exe == BIN
for d in /proc/[0-9]*; do
  e=$(readlink $d/exe 2>/dev/null)
  [ "$e" = "$BIN" ] && kill -9 ${d#/proc/} 2>/dev/null && echo "KILLED ${d#/proc/}" >> $MK
done
wait $PROBE
RC=$?
kill $SAMPLER 2>/dev/null
T1=$(date +%s)
TOTAL=$(wc -c < $TS 2>/dev/null || echo 0)
ANSI=$(LC_ALL=C grep -ac $'\x1b\[' "$TS" 2>/dev/null || true)
S0V=$(grep '^S0 ' $MK | head -1 | awk '{print $2}')
ECHO=$(tail -c +"$(( ${S0V:-0} + 1 ))" "$TS" 2>/dev/null | LC_ALL=C sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -ac 'XYZPROBE9' || true)
{
echo "== E1r $(date -u +%FT%TZ) bare_runtime_5c_identical"
echo "rc=$RC elapsed=$((T1-T0))s TOTAL=$TOTAL ANSI=$ANSI echo_XYZPROBE9=$ECHO"
echo "mark: $(tr '\n' ' ' < $MK)"
echo "log_tail: $(tail -2 $SB/data/opencode/log/opencode.log 2>/dev/null | cut -c1-130)"
} > /mnt/sdcard_ext4/apps/a2todo9/t10e1r.metrics.txt
cat /mnt/sdcard_ext4/apps/a2todo9/t10e1r.metrics.txt
echo E1R_DONE
