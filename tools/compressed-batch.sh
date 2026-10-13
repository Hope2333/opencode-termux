#!/data/data/com.termux/files/usr/bin/bash
# compressed-batch.sh — 多版 compressed 串行批驱动（收编自 ops remaining.sh，Push261005 批实战验证）
#
# 用法:
#   compressed-batch.sh <ver> [<ver>...]            # 实跑（走 tools/compressed-one.sh）
#   VERS="2.0.23 2.0.24" compressed-batch.sh        # 或环境变量给版本列表
#   compressed-batch.sh --dry-run <ver>...          # 只判定不构建（不触网上传，只查远端）
# 环境变量:
#   TAG=<批次 tag>          源与上传目标 release（默认 Push261013）
#   WORKROOT=<目录>         缓存根（与 compressed-one.sh 共享，默认 ~/tmp/compressed-one）
#   OCOMP_FAMILY=opencode   家族（v1 用 opencode1）
#   UPLOAD=1                透传 compressed-one（默认 1；--dry-run 忽略）
#   MAX_FAILS=2             连续失败熔断阈值（默认 2）
#
# 语义（吸收 R3 P0/P1 与 P2 半成品场景）:
#   - flock 防双实例（setsid 脱离后误重启会双写共享缓存）
#   - 连续 MAX_FAILS 版失败即熔断停下（attempt1 的「10 版 2 秒全烧」根因修复）
#   - 远端跳过按**双命名逐件判**：pacman 前缀 <family>-compressed-<v>- 与 deb 前缀
#     <family>-compressed_<v> 各自判在架；任一缺失 → 该版进构建（compressed-one.sh
#     内部还有逐件 size 比对跳过，避免「deb 已传 pacman 未传」时误删好件重传）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAMILY="${OCOMP_FAMILY:-opencode}"
TAG="${TAG:-Push261013}"
REPO="Hope2333/opencode-termux"
WORKROOT="${WORKROOT:-$HOME/tmp/compressed-one}"
MAX_FAILS="${MAX_FAILS:-2}"
STATE="$WORKROOT/batch-state"
mkdir -p "$STATE"

DRY_RUN=0
VERS=()
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && { DRY_RUN=1; continue; }
  VERS+=("$arg")
done
[[ ${#VERS[@]} -eq 0 && -n "${VERS:-}" ]] && read -ra VERS <<<"$VERS"
[[ ${#VERS[@]} -gt 0 ]] || { echo "usage: compressed-batch.sh [--dry-run] <ver>..." >&2; exit 1; }

# flock 防双实例
exec 9>"$STATE/.lock"
flock -n 9 || { echo "another batch instance running, exit" >>"$STATE/progress.log"; exit 0; }

echo "=== batch start $(date +%T) tag=$TAG family=$FAMILY dry=$DRY_RUN vers=${VERS[*]} ===" >>"$STATE/progress.log"
fails=0
for ver in "${VERS[@]}"; do
  # 双命名逐件判在架（前缀匹配；压缩包名带 rel 段，deb 不带）
  pac_n=$(gh api "repos/$REPO/releases/tags/$TAG" --jq "[.assets[].name | select(startswith(\"${FAMILY}-compressed-${ver}-\"))] | length" 2>/dev/null || echo 0)
  deb_n=$(gh api "repos/$REPO/releases/tags/$TAG" --jq "[.assets[].name | select(startswith(\"${FAMILY}-compressed_${ver}\"))] | length" 2>/dev/null || echo 0)
  if [[ "${pac_n:-0}" -ge 1 && "${deb_n:-0}" -ge 1 ]]; then
    echo "SKIP $ver (pacman x${pac_n} + deb x${deb_n} already on $TAG) $(date +%H:%M:%S)" >>"$STATE/progress.log"
    continue
  fi
  echo "START $ver $(date +%H:%M:%S) (pacman=${pac_n:-?} deb=${deb_n:-?})" >>"$STATE/progress.log"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN $ver would build $(date +%H:%M:%S)" >>"$STATE/progress.log"
    continue
  fi
  bash "$REPO_ROOT/tools/compressed-one.sh" "$ver" upload >>"$STATE/build-$ver.log" 2>&1
  rc=$?
  echo "DONE $ver rc=$rc $(date +%H:%M:%S)" >>"$STATE/progress.log"
  if [[ "$rc" -ne 0 ]]; then
    fails=$((fails+1))
    if [[ "$fails" -ge "$MAX_FAILS" ]]; then
      echo "CIRCUIT_BREAK after $fails consecutive failures $(date +%H:%M:%S)" >>"$STATE/progress.log"
      break
    fi
  else
    fails=0
  fi
done
echo "=== batch end $(date +%T) ===" >>"$STATE/progress.log"
