#!/usr/bin/env bash
#
# bench-opencode.sh — OpenCode 启动性能基线基准脚本
#
# 用途:
#   - 量化 opencode 启动时间（warm）+ 内存驻留（RSS/HWM）+ 可执行文件尺寸
#   - 支持对比测试: wrapper 路线 vs 原生 android Bun 路线
#   - 设备分级: 旗舰-UFS / 中端-eMMC / 低端（预留 DEVICE_CLASS 参数）
#
# 用法:
#   scripts/bench/bench-opencode.sh [--runs N] [--runtime PATH] [--label NAME] [--device-class ufs|emmc|low]
#
# 环境变量:
#   OPENCODE_BENCH_RUNTIME   可选: 覆盖被测二进制路径（默认探测 $PREFIX/lib/opencode/runtime/opencode）
#   OPENCODE_BENCH_BUN      可选: 对照原生 Bun 路径（如 bun-android-probe 的 bun），启用对照对比
#
# 输出:
#   stdout: 人类可读摘要
#   $TMPDIR/opencode-bench-<label>.json: 结构化基线数据（可被后续流程消费）
#
# 约定: strict mode, 大写 env knob, 输出到 TMPDIR（Termux 无 /tmp 写权限）

set -euo pipefail

# ── 默认值 ──────────────────────────────────────────────────────────────────
RUNS="${OPENCODE_BENCH_RUNS:-5}"
LABEL="${OPENCODE_BENCH_LABEL:-$(date +%Y%m%d-%H%M%S)}"
DEVICE_CLASS="${OPENCODE_BENCH_DEVICE_CLASS:-ufs}"   # ufs | emmc | low
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TMPDIR="${TMPDIR:-$PREFIX/tmp}"

# 被测 runtime: 探测包装二进制
RUNTIME="${OPENCODE_BENCH_RUNTIME:-$PREFIX/lib/opencode/runtime/opencode}"
# 可选对照: 原生 android Bun
BUN="${OPENCODE_BENCH_BUN:-}"

# 参数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --device-class) DEVICE_CLASS="$2"; shift 2 ;;
    --bun) BUN="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

OUT="$TMPDIR/opencode-bench-$LABEL.json"
LOG="$TMPDIR/opencode-bench-$LABEL.log"

# ── 工具检查 ────────────────────────────────────────────────────────────────
for t in stat date find; do command -v "$t" >/dev/null || { echo "缺少 $t" >&2; exit 1; }; done
[[ -x "$RUNTIME" ]] || { echo "runtime 不存在或不可执行: $RUNTIME" >&2; exit 1; }
[[ -z "$BUN" || -x "$BUN" ]] || { echo "对照 bun 不存在: $BUN" >&2; exit 1; }

# ── 测量原语 ────────────────────────────────────────────────────────────────
# ms 级计时: bash TIMEFORMAT 捕获 real 秒, 乘 1000
time_ms() {  # $1=cmd... 输出毫秒整数到 stdout
  local t
  t=$( { TIMEFORMAT='%R'; time "$@" >/dev/null 2>&1; } 2>&1 )
  awk -v x="$t" 'BEGIN{ printf "%d", x*1000 }'
}

# RSS 采样: 后台启动, sleep $1 秒后读 /proc/PID/status, 输出 "VmRSS VmHWM VmPeak" (kB)
rss_at() {  # $1=seconds, $2+=cmd...
  local sec="$1"; shift
  local pid out
  "$@" >"$LOG" 2>&1 &
  pid=$!
  sleep "$sec"
  if [[ -r "/proc/$pid/status" ]]; then
    rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null); rss=${rss:-0}
    hwm=$(awk '/^VmHWM:/{print $2}' "/proc/$pid/status" 2>/dev/null); hwm=${hwm:-0}
    peak=$(awk '/^VmPeak:/{print $2}' "/proc/$pid/status" 2>/dev/null); peak=${peak:-0}
    echo "$rss $hwm $peak"
  else
    echo "0 0 0"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# ── 采集 ────────────────────────────────────────────────────────────────────
echo "基准: label=$LABEL device_class=$DEVICE_CLASS runs=$RUNS" | tee -a "$LOG"
[[ -n "$BUN" ]] && echo "对照 Bun: $BUN" | tee -a "$LOG"

# 1. 二进制统计
BIN_SIZE=$(stat -c %s "$RUNTIME" 2>/dev/null || echo 0)
[[ -n "$BUN" ]] && BUN_SIZE=$(stat -c %s "$BUN" 2>/dev/null || echo 0) || BUN_SIZE=0
ARCH=$(uname -m)
ANDROID_API=$(getprop ro.build.version.sdk 2>/dev/null || echo "?")

# 2. 启动时间: first(可能冷) + warm min/median/avg
start_times=()
for _ in $(seq 1 "$RUNS"); do
  start_times+=("$(time_ms "$RUNTIME" --version)")
done
first_t=${start_times[0]}
min_t=999999999; sum_t=0
for t in "${start_times[@]}"; do
  (( t < min_t )) && min_t=$t
  (( sum_t += t ))
done
avg_t=$(( sum_t / RUNS ))
sorted_t=($(printf '%s\n' "${start_times[@]}" | sort -n))
med_t=${sorted_t[$(( RUNS / 2 ))]}

# 3. 对照 Bun 启动 (若提供)
bun_times=()
if [[ -n "$BUN" ]]; then
  for _ in $(seq 1 "$RUNS"); do
    bun_times+=("$(time_ms "$BUN" --version)")
  done
  bun_min=999999999; bun_sum=0
  for t in "${bun_times[@]}"; do
    (( t < bun_min )) && bun_min=$t
    (( bun_sum += t ))
  done
  bun_avg=$(( bun_sum / RUNS ))
else
  bun_min=0; bun_avg=0
fi

# 4. 内存 (启动 3s 爆发 / 8s 稳定)
rss3=($(rss_at 3 "$RUNTIME" serve))
rss8=($(rss_at 8 "$RUNTIME" serve))
rss3_kb="${rss3[0]:-0}"; hwm3_kb="${rss3[1]:-0}"
rss8_kb="${rss8[0]:-0}"; hwm8_kb="${rss8[1]:-0}"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo
echo "═══ OpenCode 启动基线 ═══════════════════════════════════"
echo "设备: $ARCH / API $ANDROID_API / storage_class=$DEVICE_CLASS"
echo "runtime: $RUNTIME ($BIN_SIZE bytes)"
echo "启动时间 (${RUNS}次): first=${first_t}ms  min=${min_t}ms  median=${med_t}ms  avg=${avg_t}ms"
[[ -n "$BUN" ]] && echo "对照 android Bun (warm): min=${bun_min}ms  avg=${bun_avg}ms  (${BUN_SIZE} bytes)"
echo "内存 3s(启动爆发): RSS=${rss3_kb}kB  HWM=${hwm3_kb}kB"
echo "内存 8s(稳定):     RSS=${rss8_kb}kB  HWM=${hwm8_kb}kB"
echo "═══ END ═════════════════════════════════════════════════"

# ── JSON 落盘 ───────────────────────────────────────────────────────────────
cat > "$OUT" <<EOF
{
  "label": "$LABEL",
  "device_class": "$DEVICE_CLASS",
  "arch": "$ARCH",
  "android_api": "$ANDROID_API",
  "runtime_path": "$RUNTIME",
  "runtime_size_bytes": "$BIN_SIZE",
  "runs": $RUNS,
  "startup_ms": { "first": $first_t, "min": $min_t, "median": $med_t, "avg": $avg_t, "all": [$(IFS=,; echo "${start_times[*]}")] },
  "bun_ms": { "min": $bun_min, "avg": $bun_avg, "all": [$(IFS=,; echo "${bun_times[*]}")] },
  "rss_kb": { "at3s": $rss3_kb, "hwm3s": $hwm3_kb, "at8s": $rss8_kb, "hwm8s": $hwm8_kb },
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
echo
echo "基线数据已写入: $OUT"