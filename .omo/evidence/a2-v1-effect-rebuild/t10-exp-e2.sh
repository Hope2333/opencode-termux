#!/data/data/com.termux/files/usr/bin/bash
# E2: bare runtime TUI with warm-cache symlinks (recovery validation)
set -u
BIN=/mnt/sdcard_ext4/apps/a2todo5b/beta103-press2/runtime/opencode-v1-1.18.32-beta103-press2
SB=/mnt/sdcard_ext4/apps/a2todo9/sbx-t10e2
rm -rf $SB; mkdir -p $SB/home $SB/tmp $SB/config/opencode $SB/data $SB/state $SB/cache
ln -sfn /data/data/com.termux/files/home/.npm $SB/home/.npm
mkdir -p $SB/cache/opencode
[ -d /data/data/com.termux/files/home/.cache/opencode/packages ] && ln -sfn /data/data/com.termux/files/home/.cache/opencode/packages $SB/cache/opencode/packages
export HOME=$SB/home TMPDIR=$SB/tmp TERM=xterm-256color
export XDG_CONFIG_HOME=$SB/config XDG_DATA_HOME=$SB/data XDG_STATE_HOME=$SB/state XDG_CACHE_HOME=$SB/cache
echo '{"port": 41239}' > $SB/config/opencode/service.json
cd /mnt/sdcard_ext4/apps/a2todo5b
TS=/mnt/sdcard_ext4/apps/a2todo9/t10e2.typescript
MK=/mnt/sdcard_ext4/apps/a2todo9/t10e2.mark
rm -f $TS $MK
T0=$(date +%s)
( for i in $(seq 1 12); do echo "$(date +%s) $(wc -c < $TS 2>/dev/null || echo 0)" >> /mnt/sdcard_ext4/apps/a2todo9/t10e2.progress.log; sleep 10; done ) &
SAMPLER=$!
{
  sleep 75; echo "S0 $(wc -c < $TS 2>/dev/null || echo 0) $(date +%s)" >> $MK
  printf 'z'; sleep 7; echo "S1 $(wc -c < $TS 2>/dev/null || echo 0)" >> $MK
  printf 'XYZPROBE9'; sleep 8; echo "S2 $(wc -c < $TS 2>/dev/null || echo 0)" >> $MK
  printf '\033[C'; sleep 7; echo "S3 $(wc -c < $TS 2>/dev/null || echo 0)" >> $MK
} | script -qec "timeout 130 $BIN" "$TS" > /dev/null 2>&1 &
PROBE=$!
sleep 112
for d in /proc/[0-9]*; do e=$(readlink $d/exe 2>/dev/null); [ "$e" = "$BIN" ] && kill -9 ${d#/proc/} 2>/dev/null; done
wait $PROBE 2>/dev/null
kill $SAMPLER 2>/dev/null
T1=$(date +%s)
TOTAL=$(wc -c < $TS 2>/dev/null || echo 0)
ANSI=$(LC_ALL=C grep -ac $'\x1b\[' "$TS" 2>/dev/null || true)
S0V=$(grep '^S0 ' $MK | head -1 | awk '{print $2}')
ECHO=$(tail -c +"$(( ${S0V:-0} + 1 ))" "$TS" 2>/dev/null | LC_ALL=C sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -ac 'XYZPROBE9' || true)
SES=$(find $SB/home/.local/share/opencode -type f 2>/dev/null | wc -l)
{
echo "== E2 $(date -u +%FT%TZ) warm_cache_symlink TOTAL=$TOTAL ANSI=$ANSI echo=$ECHO session_files=$SES elapsed=$((T1-T0))s"
echo "mark: $(tr '\n' ' ' < $MK)"
echo "log_tail: $(tail -3 $SB/data/opencode/log/opencode.log 2>/dev/null | cut -c1-130)"
} > /mnt/sdcard_ext4/apps/a2todo9/t10e2.metrics.txt
cat /mnt/sdcard_ext4/apps/a2todo9/t10e2.metrics.txt
echo E2_DONE
