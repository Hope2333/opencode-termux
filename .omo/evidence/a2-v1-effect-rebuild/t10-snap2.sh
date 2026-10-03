echo P21558_SOCKETS: $(ls -l /proc/21558/fd 2>/dev/null | grep -c socket)
echo LISTEN_PORTS:
cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk '$4=="0A" {print $2}' | while read a; do pt=${a#*:}; echo "  port=$((16#$pt))"; done | sort -u
echo P21557_PPID: $(awk '{print $4}' /proc/21557/stat)
echo RUNSV_CWD: $(ls -l /proc/21557/cwd 2>/dev/null | sed 's/.*-> //')
echo SERVICE_DIR:
ls -la /proc/21557/cwd/ 2>/dev/null
echo SV_BIN: $(which sv runsv runsvdir 2>/dev/null | tr '\n' ' ')
echo P21558_START: $(stat -c %y /proc/21558 2>/dev/null)
echo P21558_UPTIME_TICKS: $(awk '{print $22}' /proc/21558/stat 2>/dev/null)
