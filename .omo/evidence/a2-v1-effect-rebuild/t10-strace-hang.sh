ST=/data/data/com.termux/files/data/data/com.termux/files/usr/bin/strace
SLIB=/data/data/com.termux/files/data/data/com.termux/files/usr/lib
P=10338
echo THREADS $(ls /proc/$P/task | wc -l) STATE $(awk '{print $3}' /proc/$P/stat)
echo FDS:
ls -l /proc/$P/fd 2>/dev/null | awk '{print $NF}' | sort | uniq -c | sort -rn
echo STRACE_12S_ALLTHREADS:
LD_LIBRARY_PATH=$SLIB timeout 12 $ST -f -p $P -tt -T -s 40 \
  -e trace=epoll_pwait,epoll_wait,epoll_ctl,futex,read,write,sendto,recvfrom,timerfd_create,timerfd_settime,signalfd,clock_nanosleep,nanosleep,rt_sigtimedwait,getrandom,openat,statx \
  2>&1 | grep -vE "FUTEX_WAIT_PRIVATE, 1, NULL|resumed\)" | head -50
