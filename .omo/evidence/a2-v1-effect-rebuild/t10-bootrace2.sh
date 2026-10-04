#!/data/data/com.termux/files/usr/bin/bash
set -u
ST=/data/data/com.termux/files/data/data/com.termux/files/usr/bin/strace
SLIB=/data/data/com.termux/files/data/data/com.termux/files/usr/lib
BIN=/mnt/sdcard_ext4/apps/a2todo5b/beta103-press2/runtime/opencode-v1-1.18.32-beta103-press2
SB=/mnt/sdcard_ext4/apps/a2todo9/sbx-t10br2
rm -rf $SB; mkdir -p $SB/home $SB/tmp $SB/config/opencode $SB/data $SB/state $SB/cache
export HOME=$SB/home TMPDIR=$SB/tmp TERM=xterm-256color
export XDG_CONFIG_HOME=$SB/config XDG_DATA_HOME=$SB/data XDG_STATE_HOME=$SB/state XDG_CACHE_HOME=$SB/cache
echo '{"port": 41237}' > $SB/config/opencode/service.json
cd /mnt/sdcard_ext4/apps/a2todo5b
TS=/mnt/sdcard_ext4/apps/a2todo9/t10br2.typescript
TRC=/mnt/sdcard_ext4/apps/a2todo9/t10br2.strace
rm -f $TS $TRC
script -qec "timeout 150 $BIN" "$TS" > /dev/null 2>&1 &
PROBE=$!
sleep 6
# attach strace -f to the runtime (exe match)
BPID=""
for d in /proc/[0-9]*; do e=$(readlink $d/exe 2>/dev/null); [ "$e" = "$BIN" ] && BPID=${d#/proc/} && break; done
echo "BPID=$BPID $(date +%s)"
[ -n "$BPID" ] && LD_LIBRARY_PATH=$SLIB timeout 100 $ST -f -p $BPID -tt -T -s 48 \
  -e trace=clone,clone3,fork,vfork,execve,wait4,waitid,socket,connect,bind,listen,openat,read,ioctl,kill,tgkill \
  -o $TRC 2>/mnt/sdcard_ext4/apps/a2todo9/t10br2.strace.err &
STPID=$!
sleep 110
cat /proc/$BPID/limits 2>/dev/null | grep -E "processes|files"
kill $STPID 2>/dev/null
for d in /proc/[0-9]*; do e=$(readlink $d/exe 2>/dev/null); [ "$e" = "$BIN" ] && kill -9 ${d#/proc/} 2>/dev/null; done
wait $PROBE 2>/dev/null
echo "BR2 total=$(wc -c < $TS 2>/dev/null || echo 0)"
wc -l $TRC
echo CLONE_EVENTS:
grep -E "clone|execve|socket|connect" $TRC 2>/dev/null | grep -v EAGAIN | head -20
echo LAST_LINES:
tail -5 $TRC 2>/dev/null | cut -c1-150
echo T10BR2_DONE
