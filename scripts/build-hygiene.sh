#!/usr/bin/env bash
# build-hygiene.sh — 构建卫生后端函数库（source 使用，勿直接执行）
#
# 函数组：
#   hg_log / free_kb               — 卫生日志与 df 读数
#   df_gate                        — F1 构建前 df 门（不足先扫，仍不足非零退出）
#   sweep_intermediates            — F2 中间件即弃（KEEP_BINS=1 保留 revived bins）
#   bun_cache_gc                   — F3 bun cache LRU GC
#   sweep_trees                    — F4 源码树 LRU（保留最近 TREE_KEEP 棵）
#   write_build_state              — F6 构建状态清单（packing/build-state.json）
#   skip_if_fresh                  — F5 同 VER+variant+rel 且 pac/deb 均在 → fresh
#
# 零静默 skip 约定：所有失败路径写 HYG_LOG，df_gate 失败额外打 stderr；
# skip_if_fresh 只返回退出码，SKIP 由调用方显式 echo。
# 全部常量可用环境变量覆盖（Makefile 与 bats 测试共用同一组旋钮）。

HYG_LOG="${HYG_LOG:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/build-hygiene.log}"
BUN_CACHE="${BUN_CACHE:-$HOME/.bun/install/cache}"
BUN_CACHE_CAP_KB="${BUN_CACHE_CAP_KB:-2097152}"          # 2G
TREE_ROOT="${TREE_ROOT:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/v2src}"
TREE_KEEP="${TREE_KEEP:-2}"                              # LRU 保留棵数
DF_MIN_KB="${DF_MIN_KB:-3000000}"                        # 3G
DF_TARGET="${DF_TARGET:-/data}"
MEM_MIN_KB="${MEM_MIN_KB:-4194304}"                       # 4G
HYG_ARTIFACTS_BUILD="${HYG_ARTIFACTS_BUILD:-artifacts/build}"

hg_log() { echo "[$(date -Iseconds)] $*" >> "$HYG_LOG"; }

free_kb() { df -kP "$DF_TARGET" | tail -1 | awk '{print $4}'; }

# F2: 中间件即弃。
# 默认删 *.pre-crhandler 与 opencode-native-revived；KEEP_BINS=1 保留
# opencode-native-revived（clean-version 的 keep 校验依赖它存在，见 Makefile）。
sweep_intermediates() {
  if [ ! -d "$HYG_ARTIFACTS_BUILD" ]; then
    hg_log "sweep_intermediates: no dir $HYG_ARTIFACTS_BUILD, nothing to sweep"
    return 0
  fi
  find "$HYG_ARTIFACTS_BUILD" -name '*.pre-crhandler' -type f -delete 2>/dev/null
  if [ "${KEEP_BINS:-0}" != "1" ]; then
    find "$HYG_ARTIFACTS_BUILD" -name 'opencode-native-revived' -type f -delete 2>/dev/null
  fi
  hg_log "sweep_intermediates ok (KEEP_BINS=${KEEP_BINS:-0})"
}

# F3: bun cache LRU GC（按顶层目录 mtime 最旧优先删，直到低于上限）
# 枚举用 GNU find（-printf mtime 排序）：toybox ls 管道下会漏列最旧条目，
# 且 -t（最新优先）方向与 LRU 相反——两坑均为 2026-09-29 实测。
bun_cache_gc() {
  [ -d "$BUN_CACHE" ] || { hg_log "bun_cache_gc: no cache dir $BUN_CACHE, skip"; return 0; }
  local used; used=$(du -sk "$BUN_CACHE" 2>/dev/null | awk '{print $1}')
  [ "${used:-0}" -le "$BUN_CACHE_CAP_KB" ] && { hg_log "bun_cache_gc: cache ${used:-0}K under cap, skip"; return 0; }
  local d sz
  for d in $(find "$BUN_CACHE" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-); do
    [ "$used" -le "$BUN_CACHE_CAP_KB" ] && break
    sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
    rm -rf "$d"; used=$((used - ${sz:-0}))
    hg_log "bun_cache_gc removed $d (-${sz:-0}K)"
  done
}

# F4: 源码树 LRU（保留最近 TREE_KEEP 棵；与 PTY_VARIANT/PKGREL 无关可共享）
# 枚举同 bun_cache_gc：GNU find + mtime 排序（最新优先，跳过前 TREE_KEEP）
sweep_trees() {
  [ -d "$TREE_ROOT" ] || { hg_log "sweep_trees: no tree root $TREE_ROOT, skip"; return 0; }
  local i=0 d
  for d in $(find "$TREE_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'opencode-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-); do
    i=$((i+1)); [ "$i" -le "$TREE_KEEP" ] && continue
    rm -rf "$d"; hg_log "sweep_trees removed $d"
  done
}

# F1: df 门——低于阈值先扫后判（中间件→bun cache→树），仍不足返回 1。
# 不静默：FAIL 行同时写 HYG_LOG 与 stderr。
df_gate() {
  local min_kb="${1:-$DF_MIN_KB}" tries=0 free
  free=$(free_kb)
  while [ "$free" -lt "$min_kb" ] && [ "$tries" -lt 3 ]; do
    tries=$((tries+1))
    case $tries in
      1) sweep_intermediates ;;
      2) bun_cache_gc ;;
      3) sweep_trees ;;
    esac
    free=$(free_kb)
  done
  if [ "$free" -ge "$min_kb" ]; then
    hg_log "df_gate ok (${tries} sweeps, ${free}K free >= ${min_kb}K)"
    return 0
  fi
  hg_log "df_gate FAIL after ${tries} sweeps: ${free}K free < ${min_kb}K required on ${DF_TARGET}"
  echo "df_gate FAIL: ${free}K free < ${min_kb}K required on ${DF_TARGET}; hygiene sweeps exhausted (log: $HYG_LOG)" >&2
  return 1
}

mem_available_kb() { awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null; }

# F1b: 内存门。v2 编译期 bun 的峰值 RSS 会打到 6G 以上；本机总量 15G、基线已占 9G，
# 与 matrix-check / 打包等重活并发时会被 LMK 连同主进程一起杀掉（已发生两次）。
# 与其硬扛，不如在建前先判：低于阈值先扫中间件与 bun cache，仍不足就 loudly 退出。
mem_gate() {
  local min_kb="${1:-$MEM_MIN_KB}" tries=0 avail
  avail=$(mem_available_kb)
  while [ "${avail:-0}" -lt "$min_kb" ] && [ "$tries" -lt 2 ]; do
    tries=$((tries + 1))
    case $tries in
      1) sweep_intermediates ;;
      2) bun_cache_gc ;;
    esac
    avail=$(mem_available_kb)
  done
  if [ "${avail:-0}" -ge "$min_kb" ]; then
    hg_log "mem_gate ok (${tries} sweeps, ${avail}K avail >= ${min_kb}K)"
    return 0
  fi
  hg_log "mem_gate FAIL after ${tries} sweeps: ${avail}K < ${min_kb}K required"
  echo "mem_gate FAIL: only ${avail}K available, need ${min_kb}K — stop other heavy jobs (builds/checks) before retrying" >&2
  return 1
}

# F6: 构建状态清单（packing/build-state.json；累加式，同键覆盖）。
# 相对路径基于调用方 cwd（Makefile 里即仓根；测试里 pushd 到隔离目录）。
write_build_state() {
  local ver="$1" variant="${2:-musl}" rel="${3:-1}"
  if [ -z "$ver" ]; then
    hg_log "write_build_state: VER empty, refuse"
    echo "Error: write_build_state requires VER" >&2
    return 1
  fi
  python3 - "$ver" "$variant" "$rel" <<'PY'
import json, os, sys, time, hashlib
ver, variant, rel = sys.argv[1], sys.argv[2], sys.argv[3]
root = os.getcwd()
state_p = os.path.join(root, "packing", "build-state.json")
state = json.load(open(state_p)) if os.path.exists(state_p) else {"builds": {}}
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()
entry = {"variant": variant, "pkgrel": rel, "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
pac = f"packing/pacman/opencode-{ver}-{rel}-aarch64.pkg.tar.xz"
deb = f"packing/dpkg-native/opencode_{ver}_aarch64.deb"
binp = f"artifacts/build/{ver}/opencode-native-revived"
for k, p in (("pac", pac), ("deb", deb), ("bin", binp)):
    if os.path.exists(p):
        entry[k] = {"path": p, "sha256": sha(p)}
pty_p = f"artifacts/build/{ver}/pty-asset.sha256"
if os.path.exists(pty_p):
    entry["pty_asset_sha256"] = open(pty_p).read().strip()
state.setdefault("builds", {})[f"{ver}:{variant}:{rel}"] = entry
os.makedirs(os.path.dirname(state_p), exist_ok=True)
json.dump(state, open(state_p, "w"), indent=1, sort_keys=True)
print(f"build-state: {ver}:{variant}:{rel} recorded")
PY
}

# F5: skip-if-fresh（同 VER+variant+rel 且清单内 pac/deb 均在 → fresh=0）。
# 只判断不打印——调用方必须显式 echo SKIP（零静默 skip）。
skip_if_fresh() {
  local ver="$1" variant="${2:-musl}" rel="${3:-1}"
  [ -n "$ver" ] || return 1
  local state="packing/build-state.json"
  [ -f "$state" ] || return 1
  python3 - "$state" "$ver" "$variant" "$rel" <<'PY'
import json, os, sys
state = json.load(open(sys.argv[1]))
key = f"{sys.argv[2]}:{sys.argv[3]}:{sys.argv[4]}"
e = state.get("builds", {}).get(key)
ok = bool(e) and all(os.path.exists(a["path"]) for a in (e.get("pac"), e.get("deb")) if a)
sys.exit(0 if ok else 1)
PY
}
