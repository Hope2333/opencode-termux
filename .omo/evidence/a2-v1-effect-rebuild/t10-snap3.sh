echo RUN_SCRIPT:
cat /data/data/com.termux/files/usr/var/service/opencode-serve/run
echo P21558_FD_DETAIL:
ls -l /proc/21558/fd 2>/dev/null | grep socket
for f in /proc/21558/fd/*; do t=$(readlink $f); case "$t" in socket*) ino=${t#socket:[}; ino=${ino%]}; grep " $ino " /proc/net/tcp /proc/net/tcp6 /proc/net/unix 2>/dev/null | head -2;; esac; done
echo P21558_CHILDREN: $(cat /proc/21558/task/21558/children 2>/dev/null)
echo PORT4096_OWNER: 1716=kdeconnect? check inode owners
awk 'NR>1 {print $2, $4, $10}' /proc/net/tcp 2>/dev/null | head -20
echo LOCKS_HOME:
ls -la /data/data/com.termux/files/home/.local/share/opencode/ 2>/dev/null | head -20
echo TMP_LOCKS:
ls -la /data/data/com.termux/files/usr/tmp/ 2>/dev/null | grep -iE "opencode|lock|sock" | head
echo SERVE_LOGISH:
ls -la /data/data/com.termux/files/usr/var/service/opencode-serve/supervise/ 2>/dev/null
echo SERVE_STATE: $(cat /data/data/com.termux/files/usr/var/service/opencode-serve/supervise/stat 2>/dev/null | od -c | head -1)
