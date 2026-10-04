#!/data/data/com.termux/files/usr/bin/bash
# probe9.sh — A2 todo9: press3/锚-7 oscar 输入判据(typescript 实读回显) + strace 断层定位
# 用法: bash probe9.sh <TAG> <BIN> [launcher|anchor] [PAT] [noplug]
#   noplug: 沙箱 config 剥离 "plugin" 数组(绕开 bun install 插件挂死, 测真实输入轴)
set -u
BASE=/mnt/sdcard_ext4/apps/a2todo9
TAG=${1:?TAG}; BIN=${2:?BIN}; MODE=${3:-launcher}; PAT=${4:-$(basename "$2")}; NOPLUG=${5:-}
CASE=files   # 当前锚槽(本轮实测; 若容器再切需重新探测)
AK=/data/data/com.termux/$CASE/usr/lib/opencode1
SRCCFG=/data/data/com.termux/$CASE/home/.config/opencode
SRCOC=/data/data/com.termux/$CASE/home/.opencode
ST=/data/data/com.termux/files/data/data/com.termux/files/usr/bin/strace
SLIB=/data/data/com.termux/files/data/data/com.termux/files/usr/lib

BIN_ABS=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")
[ -x "$BIN_ABS" ] || { echo "$TAG BINARY_MISSING"; exit 2; }

W=$BASE/sbx-$TAG
export W
rm -rf "$W"
mkdir -p "$W/home" "$W/tmp" "$W/config/opencode" "$W/data" "$W/state" "$W/cache"
cp -a "$SRCCFG/." "$W/config/opencode/" 2>/dev/null
[ -d "$SRCOC" ] && cp -a "$SRCOC" "$W/home/.opencode" 2>/dev/null
if [ "$NOPLUG" = "noplug" ]; then
  python3 - <<'PYEOF'
import json, os
for f in ["config/opencode/opencode.json", "home/.opencode/opencode.json"]:
    p = os.path.join(os.environ["W"], f)
    try:
        d = json.load(open(p))
    except Exception:
        continue
    n = 0
    for obj in [d] + [v for v in d.values() if isinstance(v, dict)]:
        if isinstance(obj, dict) and "plugin" in obj:
            n += len(obj.pop("plugin"))
    json.dump(d, open(p, "w"), indent=2)
    print(f"stripped {n} plugins from {f}")
PYEOF
fi

PORT=$((25000 + RANDOM % 20000))
printf '{"port": %d}\n' "$PORT" > "$W/config/opencode/service.json"
export HOME="$W/home" TMPDIR="$W/tmp" TERM=xterm-256color
export XDG_CONFIG_HOME="$W/config" XDG_DATA_HOME="$W/data"
export XDG_STATE_HOME="$W/state" XDG_CACHE_HOME="$W/cache"

TS=$BASE/$TAG.typescript
MARK=$BASE/$TAG.mark
TRC=$BASE/$TAG.strace.log
rm -f "$TS" "$MARK" "$TRC"

if [ "$MODE" = anchor ]; then
  RUN="env LD_LIBRARY_PATH=$AK:$AK/pty LD_PRELOAD=$AK/libopencode-crhandler.so:$AK/libepoll-compat.so BUN_PTY_LIB=$AK/pty/librust_pty_arm64_musl_patched.so '$BIN_ABS'"
else
  RUN="'$BIN_ABS'"
fi

( for i in $(seq 1 45); do
    echo "$(date +%s) $(wc -c < "$TS" 2>/dev/null || echo 0)" >> "$BASE/$TAG.progress.log"
    sleep 10
  done ) &
SAMPLER=$!

STPID=""
T0=$(date +%s)
{
  sleep 120; echo "S0 $(wc -c < "$TS" 2>/dev/null || echo 0) $(date +%s)" >> "$MARK"
  # strace attach 窗口(覆盖 S1-S4 全部注入); PAT 为 arg0 证据串
  PID=""
  SELF=$$
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ "$p" = "$SELF" ] && continue
    a0=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -1)
    case "$a0" in *"$PAT"*) PID=$p; break;; esac
  done
  echo "ATTACH pid=$PID $(date +%s)" >> "$MARK"
  if [ -n "${PID:-}" ] && [ -x "$ST" ]; then
    ls -l /proc/$PID/fd > "$BASE/$TAG.fdlife.txt" 2>&1
    LD_LIBRARY_PATH=$SLIB "$ST" -f -p "$PID" -tt -T -s 64 \
      -e trace=read,poll,ppoll,epoll_wait,epoll_pwait,epoll_ctl,ioctl,connect,accept,accept4 \
      -o "$TRC" 2>>"$BASE/$TAG.strace.err" &
    STPID=$!
    sleep 3
  fi
  echo "S0b $(wc -c < "$TS" 2>/dev/null || echo 0) $(date +%s)" >> "$MARK"
  printf 'z';            sleep 8;  echo "S1 $(wc -c < "$TS" 2>/dev/null || echo 0) $(date +%s)" >> "$MARK"
  printf 'XYZPROBE9';    sleep 8;  echo "S2 $(wc -c < "$TS" 2>/dev/null || echo 0) $(date +%s)" >> "$MARK"
  printf '\r';           sleep 90; echo "S3 $(wc -c < "$TS" 2>/dev/null || echo 0) $(date +%s)" >> "$MARK"
  printf '\033[C';       sleep 8;  echo "S4 $(wc -c < "$TS" 2>/dev/null || echo 0) $(date +%s)" >> "$MARK"
  [ -n "$STPID" ] && kill "$STPID" 2>/dev/null
  printf '\003';         sleep 2;  echo "C1 $(date +%s)" >> "$MARK"
  printf '\003';         sleep 12
} | script -qec "timeout 400 $RUN" "$TS" > "$BASE/$TAG.script.out" 2>&1
RC=$?
T1=$(date +%s)
kill "$SAMPLER" 2>/dev/null

# 服务幸存者清理
REG="$W/state/opencode/service.json"
[ -f "$REG" ] && SPID=$(sed -n 's/.*"pid"[": ]*\([0-9]*\).*/\1/p' "$REG") && \
  { [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null; }

TOTAL=$(wc -c < "$TS" 2>/dev/null || echo 0)
ANSI=$(LC_ALL=C grep -ac $'\x1b\[' "$TS" 2>/dev/null || true)
CRASH=$(LC_ALL=C grep -aci 'bun\.report\|SIGSEGV\|Segmentation' "$TS" 2>/dev/null || true)
E500=$(LC_ALL=C grep -ac 'Internal Server Error\|HTTP 500\|status 500\| 500 ' "$TS" 2>/dev/null || true)
S0V=$(grep '^S0 ' "$MARK" 2>/dev/null | awk '{print $2}')
S1V=$(grep '^S1 ' "$MARK" | awk '{print $2}'); S2V=$(grep '^S2 ' "$MARK" | awk '{print $2}')
S3V=$(grep '^S3 ' "$MARK" | awk '{print $2}'); S4V=$(grep '^S4 ' "$MARK" | awk '{print $2}')
ATTV=$(grep '^ATTACH' "$MARK" | head -1)
# 回显判据: S0 之后区域实读
AFTER0_SIZE=$(( ${S4V:-0} - ${S0V:-0} ))
ECHO_RAW=$(tail -c +"$(( ${S0V:-0} + 1 ))" "$TS" 2>/dev/null | LC_ALL=C grep -ac 'XYZPROBE9' || true)
ECHO_CLEAN=$(tail -c +"$(( ${S0V:-0} + 1 ))" "$TS" 2>/dev/null | LC_ALL=C sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][0-9A-B]//g; s/\x1b[=><]//g' | grep -ac 'XYZPROBE9' || true)
ECHO_Z=$(tail -c +"$(( ${S1V:-0} + 1 ))" "$TS" 2>/dev/null | LC_ALL=C sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -ac 'z' || true)
# 会话存档判据
SES_FILES=$(find "$W/home/.local/share/opencode" -type f 2>/dev/null | wc -l)
SES_DIRS=$(find "$W/home/.local/share/opencode" -maxdepth 3 -type d 2>/dev/null | head -8 | tr '\n' ' ')
SES_SAMPLE=$(find "$W/home/.local/share/opencode" -type f 2>/dev/null | head -5 | tr '\n' ' ')
STRACE_LINES=$(wc -l < "$TRC" 2>/dev/null || echo 0)
STRACE_ERR=$(head -2 "$BASE/$TAG.strace.err" 2>/dev/null | tr '\n' ' ')

{
echo "== probe9 $TAG $(date -u +%FT%TZ) host=$(uname -r) =="
echo "bin=$BIN_ABS mode=$MODE port=$PORT rc=$RC elapsed=$((T1-T0))s"
echo "render: TOTAL=$TOTAL ANSI=$ANSI crash_kw=$CRASH err500=$E500"
echo "attach: $ATTV strace_lines=$STRACE_LINES strace_err=$STRACE_ERR"
echo "echo:   AFTER0_delta=$AFTER0_SIZE marker_raw=$ECHO_RAW marker_clean=$ECHO_CLEAN z_clean=$ECHO_Z"
echo "session: files=$SES_FILES dirs=$SES_DIRS"
echo "session_sample: $SES_SAMPLE"
echo "mark: $(tr '\n' ' ' < "$MARK" 2>/dev/null)"
} | tee "$BASE/$TAG.metrics.txt"
# 供人工实读的净化尾段(编辑器行上屏形态)
tail -c +"$(( ${S0V:-0} + 1 ))" "$TS" 2>/dev/null | LC_ALL=C sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tail -c 3000 > "$BASE/$TAG.tail-clean.txt"
gzip -c "$TS" > "$BASE/$TAG.typescript.gz" 2>/dev/null
[ -f "$TRC" ] && gzip -c "$TRC" > "$BASE/$TAG.strace.log.gz" 2>/dev/null && rm -f "$TRC"
echo "PROBE9_${TAG}_DONE rc=$RC"
