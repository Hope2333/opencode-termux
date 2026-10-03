BIN=/mnt/sdcard_ext4/apps/a2todo5b/beta103-press2/runtime/opencode-v1-1.18.32-beta103-press2
SB=/mnt/sdcard_ext4/apps/a2todo9/sbx-t10e1
rm -rf $SB; mkdir -p $SB/home $SB/tmp $SB/config/opencode $SB/data $SB/state $SB/cache
export HOME=$SB/home TMPDIR=$SB/tmp TERM=xterm-256color
export XDG_CONFIG_HOME=$SB/config XDG_DATA_HOME=$SB/data XDG_STATE_HOME=$SB/state XDG_CACHE_HOME=$SB/cache
echo '{"port": 41235}' > $SB/config/opencode/service.json
TS=/mnt/sdcard_ext4/apps/a2todo9/t10e1.typescript
rm -f $TS
# 5c 同法: bare runtime in 真 pty; 注入 z/XYZPROBE9; 140s 后 SIGKILL
( for i in $(seq 1 14); do echo "$(date +%s) $(wc -c < $TS 2>/dev/null || echo 0)" >> /mnt/sdcard_ext4/apps/a2todo9/t10e1.progress.log; sleep 10; done ) &
SAMPLER=$!
T0=$(date +%s)
{
  sleep 65; echo "S0 $(wc -c < $TS) $(date +%s)" >> /mnt/sdcard_ext4/apps/a2todo9/t10e1.mark
  printf 'z'; sleep 6; echo "S1 $(wc -c < $TS)" >> /mnt/sdcard_ext4/apps/a2todo9/t10e1.mark
  printf 'XYZPROBE9'; sleep 6; echo "S2 $(wc -c < $TS)" >> /mnt/sdcard_ext4/apps/a2todo9/t10e1.mark
} | script -qec "timeout 200 $BIN" "$TS" > /mnt/sdcard_ext4/apps/a2todo9/t10e1.script.out 2>&1
kill -9 $(cat /proc/*/stat 2>/dev/null; true) 2>/dev/null
kill $SAMPLER 2>/dev/null
RC=$?
T1=$(date +%s)
TOTAL=$(wc -c < $TS 2>/dev/null || echo 0)
ANSI=$(LC_ALL=C grep -ac $'\x1b\[' "$TS" 2>/dev/null || true)
echo "E1 RESULT rc=$RC elapsed=$((T1-T0))s TOTAL=$TOTAL ANSI=$ANSI"
echo "MARK: $(tr '\n' ' ' < /mnt/sdcard_ext4/apps/a2todo9/t10e1.mark 2>/dev/null)"
echo ECHO_CHECK: $(tail -c +$(( $(grep ^S0 /mnt/sdcard_ext4/apps/a2todo9/t10e1.mark | head -1 | awk "{print \$2}") + 1 )) "$TS" 2>/dev/null | LC_ALL=C sed "s/\x1b\[[0-9;?]*[a-zA-Z]//g" | grep -ac "XYZPROBE9" || true)
tail -3 $SB/data/opencode/log/opencode.log 2>/dev/null
