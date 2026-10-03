#!/data/data/com.termux/files/usr/bin/bash
# oscar-gate.sh — A2 todo5: kernel 3.18 终验判据（在 oscar 本机 Termux bash 执行）
#
# 判据（task-4-press.txt task-5 交接段）:
#   1. boot 过 ready: TUI 渲染 TOTAL≥5KB（真 PTY=script）
#   2. 键入 DELTA>0（键入窗字节增量）
#   3. LLM 往返（会话内 prompt → 回复上屏，token 用量尾栏为证）
#   观察项: ①5min 冻结窗（窗后方向键 ANSI 重绘>0=存活）②退出延迟
#           ③BUN_PTY_LIB environ 实证 ④epoll-compat 生效（无 4.4s SIGSEGV）
#
# 公平性: 双件同 harness 同判据。beta83-baseline 直跑件手动补
#   LD_PRELOAD=libepoll-compat + BUN_PTY_LIB（与 kit launcher 注入对齐），
#   双 run 唯一差异 = effect 版本（+UPX press，B2/task-4 已证正交）。
#
# 用法: bash oscar-gate.sh <TAG> <BIN> [launcher|raw] <PROBE_PAT>
set -u
BASE=/mnt/sdcard_ext4/apps/a2todo5
KIT=$BASE/beta103-press
PTYLIB=$KIT/pty/librust_pty_arm64_musl_patched.so
EPOLL=$KIT/epoll/libepoll-compat.so

TAG=${1:?TAG}; BIN=${2:?BIN}; MODE=${3:-raw}; PAT=${4:?PROBE_PAT}
BIN_ABS=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")
[ -x "$BIN_ABS" ] || { echo "$TAG BINARY_MISSING"; exit 2; }

W=$BASE/sbx-$TAG
rm -rf "$W"
mkdir -p "$W/home" "$W/tmp" "$W/config/opencode" "$W/data" "$W/state" "$W/cache"
PORT=$((25000 + RANDOM % 20000))
printf '{"port": %d}\n' "$PORT" > "$W/config/opencode/service.json"
export HOME="$W/home" TMPDIR="$W/tmp" TERM=xterm-256color
export XDG_CONFIG_HOME="$W/config" XDG_DATA_HOME="$W/data"
export XDG_STATE_HOME="$W/state" XDG_CACHE_HOME="$W/cache"

TS=$BASE/$TAG.typescript
MARK=$BASE/$TAG.mark
PROG=$BASE/$TAG.progress.log
rm -f "$TS" "$MARK" "$PROG"

if [ "$MODE" = launcher ]; then
  RUN="'$BIN_ABS'"
else
  RUN="env LD_LIBRARY_PATH=$(dirname "$BIN_ABS"):$KIT/pty LD_PRELOAD=$EPOLL BUN_PTY_LIB=$PTYLIB '$BIN_ABS'"
fi

# 每 10s 采样: 时间 ts_bytes MemAvailable（冻结曲线）
( for i in $(seq 1 80); do
    echo "$(date +%s) $(wc -c < "$TS" 2>/dev/null || echo 0) $(awk '/MemAvailable/{print $2}' /proc/meminfo)" >> "$PROG"
    sleep 10
  done ) &
SAMPLER=$!

# 观察③: t+165 探 /proc/<pid>/environ 的 BUN_PTY_LIB/LD_PRELOAD
( sleep 165
  : > "$BASE/$TAG.environ.txt"
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    if tr '\0' '\n' < "$d/cmdline" 2>/dev/null | grep -q "$PAT"; then
      echo "--- pid=$p cmd=$(tr '\0' ' ' < "$d/cmdline")" >> "$BASE/$TAG.environ.txt"
      tr '\0' '\n' < "$d/environ" 2>/dev/null | grep -a 'BUN_PTY_LIB\|LD_PRELOAD' | sed "s/^/pid=$p /" >> "$BASE/$TAG.environ.txt"
    fi
  done ) &
PROBER=$!

T0=$(date +%s)
{
  sleep 150;                                   echo "S0 $(wc -c < "$TS" 2>/dev/null || echo 0) $(date +%s)" >> "$MARK"
  printf 'z';              sleep 5;            echo "S1 $(wc -c < "$TS" 2>/dev/null || echo 0) $(date +%s)" >> "$MARK"
  printf 'reply with exactly: ok\r'; sleep 150; echo "S2 $(wc -c < "$TS" 2>/dev/null || echo 0) $(date +%s)" >> "$MARK"
  sleep 300;                                   echo "S3 $(wc -c < "$TS" 2>/dev/null || echo 0) $(date +%s)" >> "$MARK"
  printf '\033[C';         sleep 8;            echo "S4 $(wc -c < "$TS" 2>/dev/null || echo 0) $(date +%s)" >> "$MARK"
  printf '\003';           sleep 2;            echo "C1 $(date +%s)" >> "$MARK"
  printf '\003';           sleep 12
} | script -qec "timeout 1100 $RUN" "$TS" > "$BASE/$TAG.script.out" 2>&1
RC=$?
T1=$(date +%s)
kill "$SAMPLER" "$PROBER" 2>/dev/null

# 服务幸存者清理（注册文件带 pid）
REG="$W/state/opencode/service.json"
[ -f "$REG" ] && SPID=$(sed -n 's/.*"pid"[": ]*\([0-9]*\).*/\1/p' "$REG") && \
  { [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null; }

TOTAL=$(wc -c < "$TS" 2>/dev/null || echo 0)
ANSI=$(LC_ALL=C grep -c $'\x1b\[' "$TS" 2>/dev/null || true)
CRASH=$(LC_ALL=C grep -ci 'bun\.report\|SIGSEGV\|Segmentation' "$TS" 2>/dev/null || true)
S0V=$(grep '^S0' "$MARK" 2>/dev/null | awk '{print $2}')
S1V=$(grep '^S1' "$MARK" | awk '{print $2}'); S2V=$(grep '^S2' "$MARK" | awk '{print $2}')
S3V=$(grep '^S3' "$MARK" | awk '{print $2}'); S4V=$(grep '^S4' "$MARK" | awk '{print $2}')
T3=$(grep '^S3' "$MARK" | awk '{print $3}')
DELTA1=$(( ${S1V:-0} - ${S0V:-0} ))
DELTA2=$(( ${S2V:-0} - ${S1V:-0} ))
DELTA3=$(( ${S4V:-0} - ${S3V:-0} ))
# 冻结窗后方向键窗内 ANSI 重绘增量（真活性的强判据）
ANSI3=$(tail -c +"$(( ${S3V:-0} + 1 ))" "$TS" 2>/dev/null | LC_ALL=C grep -c $'\x1b\[' || true)
# LLM 往返窗 token 用量尾栏（assistant 回复上屏的形态学证据）
TOK=$(tail -c +"$(( ${S1V:-0} + 1 ))" "$TS" 2>/dev/null | LC_ALL=C grep -c '\.K ([0-9]\+%)' || true)
# feeder 在 S3 后 +8+2+12s 结束；若子进程早已干净退出，script 收尾即在此后 ~0s
[ -z "$T3" ] || EXIT_DELAY=$(( T1 - T3 - 22 ))

{
echo "== oscar-gate $TAG $(date -u +%FT%TZ) host=$(uname -r) =="
echo "bin=$BIN_ABS mode=$MODE port=$PORT rc=$RC elapsed=$((T1-T0))s exit_delay_after_ctrlC=${EXIT_DELAY-unmeasured}s"
echo "render: TOTAL=$TOTAL ANSI=$ANSI crash_kw=$CRASH"
echo "keys:   DELTA_z=$DELTA1 DELTA_llm_window=$DELTA2"
echo "freeze: idle300s_then_arrow DELTA_arrow=$DELTA3 ANSI_redraw_in_window=$ANSI3"
echo "llm:    token_footer_hits=$TOK"
echo "mark:   $(tr '\n' ' ' < "$MARK" 2>/dev/null)"
echo "environ_probe: $(wc -l < "$BASE/$TAG.environ.txt" 2>/dev/null || echo 0) lines"
} | tee "$BASE/$TAG.metrics.txt"
gzip -c "$TS" > "$BASE/$TAG.typescript.gz" 2>/dev/null
echo "GATE_${TAG}_DONE rc=$RC"
