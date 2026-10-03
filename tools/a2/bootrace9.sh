#!/data/data/com.termux/files/usr/bin/bash
# bootrace9.sh — 从启动挂 strace 全量跟踪 press3 前 70s, 抓 8KB spinner 后的最后 syscall
# 用法: bash bootrace9.sh <TAG>
set -u
BASE=/mnt/sdcard_ext4/apps/a2todo9
TAG=${1:?TAG}
CASE=files
SRCCFG=/data/data/com.termux/$CASE/home/.config/opencode
SRCOC=/data/data/com.termux/$CASE/home/.opencode
KIT=$BASE/kit
ST=/data/data/com.termux/files/data/data/com.termux/files/usr/bin/strace
SLIB=/data/data/com.termux/files/data/data/com.termux/files/usr/lib

W=$BASE/sbx-$TAG
rm -rf "$W"
mkdir -p "$W/home" "$W/tmp" "$W/config/opencode" "$W/data" "$W/state" "$W/cache"
cp -a "$SRCCFG/." "$W/config/opencode/" 2>/dev/null
[ -d "$SRCOC" ] && cp -a "$SRCOC" "$W/home/.opencode" 2>/dev/null
PORT=$((25000 + RANDOM % 20000))
printf '{"port": %d}\n' "$PORT" > "$W/config/opencode/service.json"
export HOME="$W/home" TMPDIR="$W/tmp" TERM=xterm-256color
export XDG_CONFIG_HOME="$W/config" XDG_DATA_HOME="$W/data"
export XDG_STATE_HOME="$W/state" XDG_CACHE_HOME="$W/cache"

TS=$BASE/$TAG.typescript
TRC=$BASE/$TAG.bootrace
rm -f "$TS" "$TRC"

script -qec "timeout 70 env LD_LIBRARY_PATH=$KIT/pty:$KIT/epoll LD_PRELOAD=$KIT/epoll/libepoll-compat.so BUN_PTY_LIB=$KIT/pty/librust_pty_arm64_musl_patched.so LD_LIBRARY_PATH=$SLIB:\$LD_LIBRARY_PATH '$ST' -f -tt -e trace=openat,open,connect,sendto,recvfrom,recvmsg,sendmsg,read,write,poll,ppoll,epoll_wait,epoll_pwait,epoll_ctl,ioctl,fcntl,futex,access,statfs -s 48 -o '$TRC' '$KIT/runtime/opencode-v1-1.18.32-beta103-press3'" "$TS" >/dev/null 2>&1

{
echo "== bootrace9 $TAG $(date -u +%FT%TZ) =="
echo "typescript_bytes=$(wc -c < "$TS")"
echo "trace_lines=$(wc -l < "$TRC" 2>/dev/null || echo MISSING)"
echo "-- last 40 lines before silence --"
tail -40 "$TRC" 2>/dev/null
echo "-- write distribution (ts 停笔点) --"
grep -E 'write\(1,' "$TRC" 2>/dev/null | tail -5
} | tee "$BASE/$TAG.bootreport.txt"
gzip -c "$TRC" > "$BASE/$TAG.bootrace.gz" 2>/dev/null
echo "BOOTRACE_${TAG}_DONE"
