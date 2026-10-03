#!/data/data/com.termux/files/usr/bin/bash
# diag9.sh v3 — press3 oscar 挂死定性: arg0 精确匹配 + 全进程树快照(双点 CPU) + 对真 runtime 挂 strace
# 用法: bash diag9.sh <TAG> <BIN> <ARG0_PAT>
set -u
BASE=/mnt/sdcard_ext4/apps/a2todo9
TAG=${1:?TAG}; BIN=${2:?BIN}; PAT=${3:?ARG0_PAT}
CASE=files
SRCCFG=/data/data/com.termux/$CASE/home/.config/opencode
SRCOC=/data/data/com.termux/$CASE/home/.opencode
ST=/data/data/com.termux/files/data/data/com.termux/files/usr/bin/strace
SLIB=/data/data/com.termux/files/data/data/com.termux/files/usr/lib

BIN_ABS=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")
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

TS=$BASE/$TAG-diag.typescript
rm -f "$TS"
script -qec "timeout 120 '$BIN_ABS'" "$TS" > /dev/null 2>&1 &
GPID=$!
sleep 55   # 越过 t+30 挂死点

# arg0 精确匹配(排除自身)
PID=""
SELF=$$
for d in /proc/[0-9]*; do
  p=${d#/proc/}
  [ "$p" = "$SELF" ] && continue
  a0=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -1)
  case "$a0" in *"$PAT"*) PID=$p; break;; esac
done

tree_snapshot() {
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    cm=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null | head -c 90)
    case "$cm" in *a2todo9*|*opencode*|*timeout*|*script*) ;;
      *) continue;; esac
    read st pp ut stt <<< "$(awk '{print $3, $4, $14, $15}' "$d/stat" 2>/dev/null)"
    wc=$(cat "$d/wchan" 2>/dev/null)
    echo "  pid=$p ppid=$pp state=$st utime=$ut stime=$stt wchan=$wc cmd=$cm"
  done
}

{
echo "== diag9 $TAG $(date -u +%FT%TZ) target_pid=$PID =="
echo "--- tree snapshot r1 ($(date +%s)) ---"; tree_snapshot
sleep 8
echo "--- tree snapshot r2 ($(date +%s)) utime/stime 增量=活性 ---"; tree_snapshot
if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
  echo "threads=$(awk '{print $20}' /proc/$PID/stat)"
  if [ -x "$ST" ]; then
    LD_LIBRARY_PATH=$SLIB "$ST" -f -p "$PID" -e trace=read,write,poll,ppoll,epoll_wait,epoll_pwait,ioctl,futex \
      -o "$BASE/$TAG-diag.strace" 2>"$BASE/$TAG-diag.strace.err" &
    STP=$!
    sleep 15
    kill "$STP" 2>/dev/null
    echo "diag_strace_lines=$(wc -l < "$BASE/$TAG-diag.strace" 2>/dev/null || echo MISSING)"
    echo "--- diag strace head ---"
    head -10 "$BASE/$TAG-diag.strace" 2>/dev/null
  fi
else
  echo "TARGET_NOT_FOUND"
fi
} | tee "$BASE/$TAG-diag.report.txt"
wait "$GPID" 2>/dev/null
echo "DIAG9_${TAG}_DONE"
