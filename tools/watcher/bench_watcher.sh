#!/usr/bin/env bash
#
# bench_watcher.sh — watcher 事件延迟基准脚本
#
# 用途:
#   - 量化 watcher (inotify daemon) 事件延迟: 事件产生(touch)→watcher stdout 收到
#   - 支持 --runs / --debounce-ms / --root / --watcher 参数
#
# 用法:
#   tools/watcher/bench_watcher.sh [--runs N] [--debounce-ms N] [--root DIR] \
#                                  [--watcher PATH] [--label NAME]
#
# 环境变量:
#   WATCHER_BENCH_RUNS         可选: 覆盖迭代次数（默认 5）
#   WATCHER_BENCH_DEBOUNCE_MS  可选: 覆盖去抖窗口 ms（默认 50）
#   WATCHER_BENCH_WATCHER      可选: 覆盖 watcher 二进制路径
#
# 事件格式 (watcher.c): {"t":"create|modify|delete|rename","p":"<rel path>"}
#
# 输出:
#   stdout: 人类可读摘要（含中位数 <100ms 断言）
#   $TMPDIR/watcher-bench-<label>.json: 结构化延迟数据 {runs, debounce_ms,
#     latency_ms:{min,median,avg,max,all}, events}
#
# 约定: strict mode, 大写 env knob, 输出到 TMPDIR（Termux 无 /tmp 写权限）

set -euo pipefail

# ── 默认值 ──────────────────────────────────────────────────────────────────
RUNS="${WATCHER_BENCH_RUNS:-5}"
DEBOUNCE_MS="${WATCHER_BENCH_DEBOUNCE_MS:-50}"
LABEL="${WATCHER_BENCH_LABEL:-$(date +%Y%m%d-%H%M%S)}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TMPDIR="${TMPDIR:-$PREFIX/tmp}"
READ_TIMEOUT=2000   # 单事件读取超时 ms（去抖 50ms 下应远小于此）
WARMUP_MS=300       # watcher 启动后等待 inotify watch 建立
TARGET_MEDIAN_MS=100

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 参数解析 ────────────────────────────────────────────────────────────────
WATCHER="${WATCHER_BENCH_WATCHER:-}"
ROOT=""            # 空 = 用 mktemp 创建（脚本负责清理）
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --debounce-ms) DEBOUNCE_MS="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    --watcher) WATCHER="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; echo "用法: $0 [--runs N] [--debounce-ms N] [--root DIR] [--watcher PATH] [--label NAME]" >&2; exit 2 ;;
  esac
done

[[ "$RUNS" =~ ^[0-9]+$ ]] && [[ "$RUNS" -gt 0 ]] || { echo "无效 --runs: $RUNS（需正整数）" >&2; exit 2; }
[[ "$DEBOUNCE_MS" =~ ^[0-9]+$ ]] || { echo "无效 --debounce-ms: $DEBOUNCE_MS（需非负整数）" >&2; exit 2; }

OUT="$TMPDIR/watcher-bench-$LABEL.json"

# ── 工具检查 ────────────────────────────────────────────────────────────────
for t in date touch seq; do
  command -v "$t" >/dev/null || { echo "缺少 $t" >&2; exit 1; }
done

# watcher 二进制探测: 显式指定 > $PREFIX/bin/watcher > tools/watcher/watcher
if [[ -z "$WATCHER" ]]; then
  if [[ -x "$PREFIX/bin/watcher" ]]; then
    WATCHER="$PREFIX/bin/watcher"
  elif [[ -x "$SCRIPT_DIR/watcher" ]]; then
    WATCHER="$SCRIPT_DIR/watcher"
  else
    echo "watcher 二进制不存在: 检查 \$PREFIX/bin/watcher 或 tools/watcher/watcher" >&2
    exit 1
  fi
fi
[[ -x "$WATCHER" ]] || { echo "watcher 不存在或不可执行: $WATCHER" >&2; exit 1; }

# ── 临时资源 ────────────────────────────────────────────────────────────────
ROOT_OWNED=0
if [[ -z "$ROOT" ]]; then
  ROOT="$(mktemp -d "${TMPDIR}/watcher-bench-root.XXXXXX")"
  ROOT_OWNED=1
fi
[[ -d "$ROOT" ]] || { echo "root 目录不存在: $ROOT" >&2; exit 1; }

FIFO="${TMPDIR}/watcher-bench-${LABEL}.fifo"
rm -f "$FIFO" || true
mkfifo "$FIFO"
LOG="$TMPDIR/watcher-bench-$LABEL.log"
: > "$LOG"

WATCHER_PID=""
cleanup() {
  local rc=$?
  # 关闭 FIFO 读端, 再杀 watcher (写端), 避免挂起
  exec 3>&- 2>/dev/null || true
  [[ -n "$WATCHER_PID" ]] && kill "$WATCHER_PID" 2>/dev/null || true
  [[ -n "$WATCHER_PID" ]] && wait "$WATCHER_PID" 2>/dev/null || true
  rm -f "$FIFO" 2>/dev/null || true
  # 仅清理脚本自己创建的临时 root
  if [[ "$ROOT_OWNED" -eq 1 ]]; then
    rm -rf "$ROOT" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT

# ── 测量原语 ────────────────────────────────────────────────────────────────
now_ms() {  # 输出 epoch 毫秒整数
  date +%s%3N
}

# ── 采集 ────────────────────────────────────────────────────────────────────
echo "基准: label=$LABEL runs=$RUNS debounce_ms=$DEBOUNCE_MS" | tee -a "$LOG"
echo "watcher: $WATCHER" | tee -a "$LOG"
echo "root: $ROOT" | tee -a "$LOG"

# 启动 watcher, stdout → FIFO（setvbuf _IONBF, 事件即时到达）
"$WATCHER" "$ROOT" --debounce-ms "$DEBOUNCE_MS" >"$FIFO" 2>>"$LOG" &
WATCHER_PID=$!
exec 3<>"$FIFO"   # 同时持有读+写端, 避免 open-for-read 阻塞

# 确认 watcher 存活并完成启动
sleep 0.1
if ! kill -0 "$WATCHER_PID" 2>/dev/null; then
  echo "watcher 启动失败, 日志: $LOG" >&2
  cat "$LOG" >&2
  exit 1
fi
sleep $(( WARMUP_MS / 1000 ))

latencies=()
events_received=0
timeouts=0
echo "采集: 每轮 touch → 等待事件行" | tee -a "$LOG"
for i in $(seq 1 "$RUNS"); do
  f="$ROOT/bench-$i.tmp"
  t0=$(now_ms)
  touch "$f"
  # touch 新文件会触发 create+modify 两个事件; 读到匹配本文件的事件才算到达
  line=""
  matched=0
  while (( matched == 0 )); do
    if IFS= read -r -t "$(( READ_TIMEOUT / 1000 ))" -u 3 line; then
      [[ "$line" == *"bench-$i.tmp"* ]] && matched=1
    else
      break   # 读取超时
    fi
  done
  if (( matched == 1 )); then
    t1=$(now_ms)
    latencies+=("$(( t1 - t0 ))")
    events_received=$(( events_received + 1 ))
    echo "  run=$i event='${line}' latency=$(( t1 - t0 ))ms" | tee -a "$LOG"
  else
    timeouts=$(( timeouts + 1 ))
    echo "  run=$i 读取事件超时 (${READ_TIMEOUT}ms)" | tee -a "$LOG"
  fi
done

[[ "$events_received" -gt 0 ]] || {
  echo "未收到任何 watcher 事件（timeouts=${timeouts}/${RUNS}）" >&2
  echo "watcher 日志尾部:" >&2
  tail -20 "$LOG" >&2
  exit 1
}

# ── 统计: min/median/avg/max ────────────────────────────────────────────────
sorted=($(printf '%s\n' "${latencies[@]}" | sort -n))
min=${sorted[0]}
max=${sorted[$(( events_received - 1 ))]}
med=${sorted[$(( events_received / 2 ))]}
sum=0
for t in "${latencies[@]}"; do (( sum += t )); done
avg=$(( sum / events_received ))

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo
echo "═══ watcher 事件延迟基准 ═════════════════════════════════"
echo "watcher: $WATCHER"
echo "事件延迟 (${events_received} 事件, debounce=${DEBOUNCE_MS}ms): min=${min}ms  median=${med}ms  avg=${avg}ms  max=${max}ms"
if (( med < TARGET_MEDIAN_MS )); then
  echo "断言: PASS (median=${med}ms < ${TARGET_MEDIAN_MS}ms)"
else
  echo "断言: FAIL (median=${med}ms >= ${TARGET_MEDIAN_MS}ms)"
fi
[[ "$timeouts" -gt 0 ]] && echo "超时: ${timeouts}/${RUNS} 轮未收到事件"
echo "═══ END ═════════════════════════════════════════════════"

# ── JSON 落盘 ───────────────────────────────────────────────────────────────
{
  printf '{\n'
  printf '  "label": "%s",\n' "$LABEL"
  printf '  "watcher_path": "%s",\n' "$WATCHER"
  printf '  "root": "%s",\n' "$ROOT"
  printf '  "runs": %d,\n' "$RUNS"
  printf '  "events": %d,\n' "$events_received"
  printf '  "timeouts": %d,\n' "$timeouts"
  printf '  "debounce_ms": %d,\n' "$DEBOUNCE_MS"
  printf '  "latency_ms": { "min": %d, "median": %d, "avg": %d, "max": %d, "all": [%s] },\n' \
    "$min" "$med" "$avg" "$max" "$(IFS=,; echo "${latencies[*]}")"
  printf '  "generated_at": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '}\n'
} > "$OUT"

echo
echo "基准数据已写入: $OUT"

# 断言失败时以非 0 退出（供 CI/流程门禁消费）
(( med < TARGET_MEDIAN_MS ))
