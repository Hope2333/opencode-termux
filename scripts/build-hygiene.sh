#!/usr/bin/env bash
# build-hygiene.sh — 构建卫生后端（source 使用，勿直接执行）
# 函数：hg_log / df_gate / sweep_intermediates / bun_cache_gc / sweep_trees
HYG_LOG="${HYG_LOG:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/build-hygiene.log}"
BUN_CACHE="$HOME/.bun/install/cache"
BUN_CACHE_CAP_KB="${BUN_CACHE_CAP_KB:-2097152}"
TREE_ROOT="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/v2src"
TREE_KEEP="${TREE_KEEP:-2}"
DF_MIN_KB="${DF_MIN_KB:-3000000}"

hg_log() { echo "[$(date -Iseconds)] $*" >> "$HYG_LOG"; }

free_kb() { df -k /data | tail -1 | awk '{print $4}'; }

# F2: 中间件即弃（KEEP_BINS=1 保留 revived bins）
sweep_intermediates() {
  find artifacts/build -name '*.pre-crhandler' -delete 2>/dev/null
  if [ "${KEEP_BINS:-0}" != "1" ]; then
    find artifacts/build -name 'opencode-native-revived' -delete 2>/dev/null
  fi
  hg_log "sweep_intermediates ok"
}

# F3: bun cache LRU GC（按顶层目录 mtime 最旧优先删，直到低于上限）
# 枚举用 GNU find（-printf mtime 排序）：toybox ls 管道下会漏列最旧条目，
# 且 -t（最新优先）方向与 LRU 相反——两坑均为 2026-09-29 实测。
bun_cache_gc() {
  [ -d "$BUN_CACHE" ] || return 0
  local used; used=$(du -sk "$BUN_CACHE" 2>/dev/null | awk '{print $1}')
  [ "${used:-0}" -le "$BUN_CACHE_CAP_KB" ] && { hg_log "bun cache ${used:-0}K under cap, skip"; return 0; }
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
  local i=0 d
  for d in $(find "$TREE_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'opencode-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-); do
    i=$((i+1)); [ "$i" -le "$TREE_KEEP" ] && continue
    rm -rf "$d"; hg_log "sweep_trees removed $d"
  done
}

# F1: df 门——低于阈值先扫后判（中间件→bun cache→树），仍不足才返回 1
df_gate() {
  local min_kb="${1:-$DF_MIN_KB}" tries=0
  while [ "$(free_kb)" -lt "$min_kb" ] && [ "$tries" -lt 4 ]; do
    tries=$((tries+1))
    case $tries in
      1) sweep_intermediates ;;
      2) bun_cache_gc ;;
      3) sweep_trees ;;
    esac
  done
  if [ "$(free_kb)" -ge "$min_kb" ]; then
    hg_log "df_gate ok (${tries} sweeps, $(free_kb)K free)"
    return 0
  fi
  hg_log "df_gate FAIL after ${tries} sweeps ($(free_kb)K free < ${min_kb}K)"
  return 1
}
