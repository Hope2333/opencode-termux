#!/data/data/com.termux/files/usr/bin/bash
set -u
ST=/data/data/com.termux/files/data/data/com.termux/files/usr/bin/strace
SLIB=/data/data/com.termux/files/data/data/com.termux/files/usr/lib
# kill warmup specimen precisely
BIN=/mnt/sdcard_ext4/apps/a2todo5b/beta103-press2/runtime/opencode-v1-1.18.32-beta103-press2
for d in /proc/[0-9]*; do e=$(readlink $d/exe 2>/dev/null); [ "$e" = "$BIN" ] && kill -9 ${d#/proc/} 2>/dev/null; done
SB=/mnt/sdcard_ext4/apps/a2todo9/sbx-t10e4
rm -rf $SB; mkdir -p $SB/home $SB/tmp $SB/config/opencode $SB/data $SB/state $SB/cache
ln -sfn /data/data/com.termux/files/home/.npm $SB/home/.npm
export HOME=$SB/home TMPDIR=$SB/tmp TERM=xterm-256color
export XDG_CONFIG_HOME=$SB/config XDG_DATA_HOME=$SB/data XDG_STATE_HOME=$SB/state XDG_CACHE_HOME=$SB/cache
echo '{"port": 41242}' > $SB/config/opencode/service.json
cd /mnt/sdcard_ext4/apps/a2todo5b
TRC=/mnt/sdcard_ext4/apps/a2todo9/t10e4.strace
rm -f $TRC
# full trace (no filter) 45s from boot
( LD_LIBRARY_PATH=$SLIB timeout 45 $ST -f -qq -tt -T -s 32 -o $TRC $BIN > /dev/null 2>&1 & )
sleep 50
for d in /proc/[0-9]*; do e=$(readlink $d/exe 2>/dev/null); [ "$e" = "$BIN" ] && kill -9 ${d#/proc/} 2>/dev/null; done
sleep 2
{
echo "== E4 $(date -u +%FT%TZ) fulltrace_lines=$(wc -l < $TRC 2>/dev/null || echo 0)"
echo "FAILING_SYSCALLS:"
grep -oE "[a-z0-9_]+\([^\)]*\) *= *-1 (EPERM|ENOSYS|EINVAL|EACCES)" $TRC 2>/dev/null | sed "s/(.*//;s/^[0-9: .]*//" | sort | uniq -c | sort -rn | head -20
echo "PIDFD_RSEQ_IOURING:"
grep -cE "pidfd_open|rseq|io_uring" $TRC 2>/dev/null
echo "LAST_40_SYSCALLS_BEFORE_SILENCE:"
tail -800 $TRC 2>/dev/null | tail -40 | cut -c1-130
} > /mnt/sdcard_ext4/apps/a2todo9/t10e4.report.txt
cat /mnt/sdcard_ext4/apps/a2todo9/t10e4.report.txt
gzip -f $TRC 2>/dev/null
echo E4_DONE
