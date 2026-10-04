#!/data/data/com.termux/files/usr/bin/bash
# task-24: v2 sessions -> v1 (opencode1) 并轨脚本
#
# 结论依据（沙箱实证，见 .omo/evidence/a2-v1-effect-rebuild/task-24-sessions.txt）:
#   v1 (1.18.32) 与 v2 (2.x) 都有官方 `session export` / `session import`，
#   但两侧 export JSON 的 message 结构不同，必须转换：
#     v2: messages[] = {id,time,type,text|content,model:{id,providerID}}        (扁平)
#     v1: messages[] = {info:{...},parts:[...]}                                (两层)
#   v1 import 对 v2 原始 JSON 直接报 "Missing key at [slug]" -> "at [title]" ->
#   "at [version]" -> "Expected Message, got undefined"。
#
# 本脚本用「v1 原生骨架 + v2 内容」策略：先让 v1 自己导出一条会话做骨架（保证
# schema 100% 合法），再把 v2 的 id/时间/文本/model 覆盖进去。
#
# 安全性:
#   - 默认 DRY-RUN（只生成 JSON，不 import）
#   - import 前强制备份 v1 库
#   - 不触碰 v2 库（只读 export）
set -euo pipefail

VER_V1="1.18.32"
V1="${V1:-opencode1}"
V2="${V2:-opencode}"
SANDBOX="${SANDBOX:-$PWD/.v1-port-out}"
APPLY="${APPLY:-0}"          # 1 = 真正 import（需显式开启）
BACKUP="${BACKUP:-$HOME/.local/share/opencode1/opencode}"

log() { printf '[v1-port] %s\n' "$*" >&2; }
die() { printf '[v1-port] ERROR: %s\n' "$*" >&2; exit 1; }

command -v "$V1" >/dev/null || die "$V1 not found"
command -v "$V2" >/dev/null || die "$V2 not found"
mkdir -p "$SANDBOX"

# ---------- 0. 实况指纹留档 ----------
log "v1 db: $("$V1" db path 2>/dev/null | tail -1)"
V1DB="$("$V1" db path 2>/dev/null | tail -1)"
[ -e "$V1DB" ] && log "v1 db sha256(before)=$(sha256sum "$V1DB" | cut -d' ' -f1)"

# ---------- 1. 骨架: v1 自己导出一条原生会话 ----------
SKEL_DIR="$SANDBOX/.skel-home"
mkdir -p "$SKEL_DIR"
log "building v1-native skeleton in $SKEL_DIR"
# 若已有可用 provider, 建一条真会话; 否则退化为「用 v1 自己的 export 结构做模板」
# 优先复用调用者已有会话: 由 SKELETON_SESSION 环境变量指定
SKELETON="${SKELETON_SESSION:-}"
if [ -z "$SKELETON" ]; then
  log "no SKELETON_SESSION given; try creating one via v1 run"
  SKELETON=$(HOME="$SKEL_DIR" "$V1" run --model "${SKELETON_MODEL:-opencode/big-pickle}" \
      "reply with exactly: ok" 2>&1 | grep -oE 'ses_[A-Za-z0-9]+' | head -1 || true)
  if [ -z "$SKELETON" ]; then
    SKELETON=$(HOME="$SKEL_DIR" "$V1" db "select id from session order by time_created desc limit 1;" --format tsv 2>/dev/null | tail -1)
  fi
fi
[ -n "$SKELETON" ] || die "cannot obtain a v1-native skeleton session (set SKELETON_SESSION=<id>)"
log "skeleton session = $SKELETON"
HOME="$SKEL_DIR" "$V1" export "$SKELETON" 2>/dev/null | sed '1{/^Exporting/d}' > "$SANDBOX/_skeleton.json"
python3 -c "import json,sys;d=json.load(open('$SANDBOX/_skeleton.json'));assert d['messages'],'skeleton has no messages'" \
  || die "skeleton export invalid"

# ---------- 2. v2 导出全部会话 ----------
log "listing v2 sessions"
"$V2" session list --format json --standalone > "$SANDBOX/_v2-list.json" 2>/dev/null \
  || die "v2 session list failed (is the v2 runtime runnable?)"
N=$(python3 -c "import json;print(len(json.load(open('$SANDBOX/_v2-list.json'))))")
log "v2 has $N top-level sessions"
[ "$N" -gt 0 ] || die "v2 has no sessions to export"

mkdir -p "$SANDBOX/exports"
i=0
while IFS= read -r sid; do
  i=$((i+1))
  "$V2" session export "$sid" --standalone > "$SANDBOX/exports/$sid.json" 2>/dev/null \
    && log "  exported $sid" || log "  WARN export failed $sid"
done < <(python3 -c "
import json
for s in json.load(open('$SANDBOX/_v2-list.json')): print(s['id'])")

# ---------- 3. 转换 ----------
log "converting"
python3 "$(dirname "$0")/v1-session-port-convert.py" "$SANDBOX" || die "conversion failed"

# ---------- 4. import (需 APPLY=1) ----------
if [ "$APPLY" != "1" ]; then
  log "DRY-RUN done. Converted files in $SANDBOX/converted/"
  log "Review them, then re-run with APPLY=1 to import into v1."
  exit 0
fi

TS=$(date +%Y%m%d-%H%M%S)
BK="$BACKUP/pre-v1-port-$TS"
log "backing up v1 data -> $BK"
mkdir -p "$BK"
# BACKUP may not exist yet (fresh HOME); copy the v1 data dir by its real path
V1DATA="$(dirname "$V1DB")"
if [ ! -d "$V1DATA" ]; then die "v1 data dir not found: $V1DATA"; fi
cp -a "$V1DATA/." "$BK/" || die "backup failed"
log "backup ok ($(du -sh "$BK" 2>/dev/null | cut -f1)). Rollback: rm -rf '$V1DATA' && cp -a '$BK' '$V1DATA'"

for f in "$SANDBOX"/converted/*.json; do
  [ -e "$f" ] || continue
  log "importing $(basename "$f")"
  "$V1" import "$f" 2>&1 | tail -2
done

log "post-import v1 db sha256=$(sha256sum "$V1DB" | cut -d' ' -f1)"
log "session count = $("$V1" db 'select count(*) from session;' --format tsv 2>/dev/null | tail -1)"
log "DONE. rollback point: $BK"
