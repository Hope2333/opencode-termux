SV=/data/data/com.termux/files/usr/var/service/opencode-serve
echo BEFORE: stat=$(cat $SV/supervise/stat 2>/dev/null) pid=$(cat $SV/supervise/pid 2>/dev/null) ts=$(date -u +%FT%TZ)
echo d > $SV/supervise/control
sleep 4
echo AFTER_DOWN: stat=$(cat $SV/supervise/stat 2>/dev/null) ts=$(date -u +%FT%TZ)
[ -d /proc/21558 ] && echo "21558 STILL ALIVE" || echo "21558 GONE"
for p in /proc/[0-9]*/cmdline; do c=$(tr '\0' ' ' < $p 2>/dev/null); case "$c" in *opencode\ serve*) echo "SERVE STILL: ${p}";; esac; done
echo PORT4096_AFTER: $(awk '$4=="0A" && $2 ~ /:1000$/ {print "LISTENING"}' /proc/net/tcp)
