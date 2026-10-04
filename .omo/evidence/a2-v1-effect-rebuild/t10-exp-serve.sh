ST=/data/data/com.termux/files/data/data/com.termux/files/usr/bin/strace
SLIB=/data/data/com.termux/files/data/data/com.termux/files/usr/lib
BIN=/mnt/sdcard_ext4/apps/a2todo5b/beta103-press2/runtime/opencode-v1-1.18.32-beta103-press2
SB=/mnt/sdcard_ext4/apps/a2todo9/sbx-t10serve
rm -rf $SB; mkdir -p $SB/home $SB/tmp $SB/config/opencode $SB/data $SB/state $SB/cache
export HOME=$SB/home TMPDIR=$SB/tmp TERM=xterm-256color
export XDG_CONFIG_HOME=$SB/config XDG_DATA_HOME=$SB/data XDG_STATE_HOME=$SB/state XDG_CACHE_HOME=$SB/cache
echo '{"port": 41234}' > $SB/config/opencode/service.json
cd /mnt/sdcard_ext4/apps/a2todo9
( LD_LIBRARY_PATH=$SLIB timeout 50 $ST -f -tt -T -s 64 -e trace=connect,bind,listen,openat,futex,write -o $SB/serve.strace $BIN serve --port 41234 --hostname 127.0.0.1 > $SB/serve.out 2>&1 & echo SERVE_PID=$! > $SB/serve.pid ) 
sleep 55
echo SERVE_OUT:; cat $SB/serve.out 2>/dev/null | head -5
echo SERVE_LOG:; tail -6 $SB/data/opencode/log/opencode.log 2>/dev/null
echo LISTEN_CHECK:; awk '$4=="0A" && $2 ~ /:A112$/ {print "LISTENING 41234"}' /proc/net/tcp
echo STRACE_TAIL:; tail -25 $SB/serve.strace 2>/dev/null | cut -c1-160
