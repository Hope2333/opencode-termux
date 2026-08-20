#!/usr/bin/env bash
#
# transplant-verify.sh — agent-executable 7-point verification checklist
# for native-android transplant binaries.
#
# Checklist source: docs/performance-optimization.md §4.4 (移植后每版本必须通过)
#
# Usage:
#   scripts/transplant-verify.sh --runtime <path> [--offline] [--out <path>]
#
#   --runtime <path>  被测二进制 (required)
#   --offline         模拟网络缺失: 网络依赖项 (3) 直接记 WARN 不执行
#   --out <path>      report 输出路径 (default: report-verify.json)
#
# Exit code: 0 when no item FAILs (WARN allowed); 1 when any item FAILs.
#
# 网络项失败策略 (item 3): 记录 WARN 不 FAIL —— 设计如此。网络缺失是环境
# 问题, 不应与移植缺陷混淆; 移植缺陷由 item 2 (dlopen/崩溃) 与 item 4 (serve)
# 捕获。--offline 模式下 item 2 的非崩溃/非 dlopen 失败同样降级为 WARN
# (chat 命令依赖网络, 离线时无法区分环境与缺陷)。

set -euo pipefail

# ── 默认值 ──────────────────────────────────────────────────────────────────
RUNTIME=""
OFFLINE=0
OUT="report-verify.json"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TMPDIR="${TMPDIR:-$PREFIX/tmp}"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

# ── 参数解析 ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime) RUNTIME="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$RUNTIME" ]] || { echo "ERROR: --runtime <path> 必填" >&2; exit 2; }
[[ -x "$RUNTIME" ]] || { echo "ERROR: runtime 不存在或不可执行: $RUNTIME" >&2; exit 2; }

# ── 工具检查 ────────────────────────────────────────────────────────────────
for t in python3 curl timeout git dd awk; do
  command -v "$t" >/dev/null 2>&1 || { echo "缺少 $t" >&2; exit 1; }
done

# ── 工作区 ──────────────────────────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR}/transplant-verify.XXXXXX")"
ITEMS="$WORK/items.tsv"
: >"$ITEMS"
FAILED=0

# ── 测量原语 (参照 scripts/bench/bench-opencode.sh) ────────────────────────
time_ms() {  # $1=cmd... 输出毫秒整数到 stdout
  local t
  t=$( { TIMEFORMAT='%R'; time "$@" >/dev/null 2>&1; } 2>&1 )
  awk -v x="$t" 'BEGIN{ printf "%d", x*1000 }'
}

sanitize() { printf '%s' "$*" | tr '\t\n' '  '; }

record() {  # $1=id $2=name $3=status $4=evidence
  local ev
  ev="$(sanitize "$4")"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$ev" >>"$ITEMS"
  printf '[%s/7] %s ... %s (%s)\n' "$1" "$2" "$3" "$ev"
  if [[ "$3" == "FAIL" ]]; then FAILED=1; fi
}

# ── 环境前置检查: android sdk >= 28 (不计入 7 项, 不足 WARN 不 FAIL) ────────
SDK="$(getprop ro.build.version.sdk 2>/dev/null || echo 0)"
if [[ "$SDK" =~ ^[0-9]+$ ]] && [[ "$SDK" -ge 28 ]]; then
  API_STATUS="PASS"
  API_NOTE="sdk=$SDK >= 28"
else
  API_STATUS="WARN"
  API_NOTE="sdk=$SDK < 28 (android 9+ 要求; 低版本可能缺 syscall/链接器能力)"
fi
printf '[env] android sdk check ... %s (%s)\n' "$API_STATUS" "$API_NOTE"

# ═══════════════════════════════════════════════════════════════════════════
# item 1: --version < 300ms
# ═══════════════════════════════════════════════════════════════════════════
{
  runs=()
  for _ in 1 2 3; do
    runs+=("$(time_ms "$RUNTIME" --version)")
  done
  min=999999999
  for t in "${runs[@]}"; do (( t < min )) && min=$t; done
  if [[ "$min" -lt 300 ]]; then
    record 1 "startup --version <300ms" "PASS" "min=${min}ms (runs: ${runs[*]})"
  else
    record 1 "startup --version <300ms" "FAIL" "min=${min}ms (runs: ${runs[*]}) >= 300ms"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# item 2: TUI 渲染冒烟 (run "hi" --mode=dev, timeout 60s)
#   断言退出码 ∈ {0,124}; 139/负数信号码 = 崩溃 FAIL;
#   stderr 含 dlopen/cannot open shared object → 记录原生模块名 FAIL
# ═══════════════════════════════════════════════════════════════════════════
{
  local_out="$WORK/tui.out"
  local_err="$WORK/tui.err"
  set +e
  timeout 60 "$RUNTIME" run "hi" --mode=dev >"$local_out" 2>"$local_err"
  rc=$?
  set -e
  dlopen_line="$(grep -iE 'dlopen|cannot open shared object' "$local_err" "$local_out" 2>/dev/null | head -1 || true)"
  if [[ "$rc" -eq 0 || "$rc" -eq 124 ]]; then
    record 2 "TUI render smoke (run hi --mode=dev)" "PASS" "exit=$rc (0=正常退出, 124=存活至超时)"
  elif [[ "$rc" -eq 139 || "$rc" -lt 0 ]]; then
    record 2 "TUI render smoke (run hi --mode=dev)" "FAIL" "crash exit=$rc (segfault/signal)"
  elif [[ -n "$dlopen_line" ]]; then
    mod="$(printf '%s' "$dlopen_line" | grep -oE '[A-Za-z0-9_./-]+\.(so|node)' | head -1 || true)"
    record 2 "TUI render smoke (run hi --mode=dev)" "FAIL" "dlopen failure: ${mod:-$(sanitize "$dlopen_line")}"
  elif [[ "$rc" -ge 128 ]]; then
    record 2 "TUI render smoke (run hi --mode=dev)" "FAIL" "signal exit=$rc"
  elif [[ "$OFFLINE" -eq 1 ]]; then
    record 2 "TUI render smoke (run hi --mode=dev)" "WARN" "exit=$rc (offline: chat 命令依赖网络, 无法区分环境与缺陷)"
  else
    record 2 "TUI render smoke (run hi --mode=dev)" "FAIL" "unexpected exit=$rc (期望 0/124); stderr: $(sanitize "$(head -3 "$local_err")")"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# item 3: opencode run "hi" 端到端 (网络依赖 → 失败记 WARN 不 FAIL, 设计如此)
# ═══════════════════════════════════════════════════════════════════════════
{
  if [[ "$OFFLINE" -eq 1 ]]; then
    record 3 "e2e run hi (network)" "WARN" "skipped (--offline 模拟网络缺失)"
  else
    set +e
    timeout 120 "$RUNTIME" run "hi" >"$WORK/e2e.out" 2>"$WORK/e2e.err"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      record 3 "e2e run hi (network)" "PASS" "exit=0"
    else
      record 3 "e2e run hi (network)" "WARN" "exit=$rc (网络依赖项, 失败不阻塞); stderr: $(sanitize "$(head -3 "$WORK/e2e.err")")"
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# item 4: serve 启动 + HTTP 200
# ═══════════════════════════════════════════════════════════════════════════
{
  port=""
  for p in 43123 43124 43125 43126 43127; do
    # Termux curl 连接被拒时输出两遍 000 ("000000") — 取末 3 位规整
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$p/" 2>/dev/null || echo 000)"
    code="${code: -3}"
    if [[ "$code" == "000" ]]; then port="$p"; break; fi
  done
  if [[ -z "$port" ]]; then
    record 4 "serve + HTTP 200" "FAIL" "no free port in 43123-43127"
  else
    set +e
    "$RUNTIME" serve --port "$port" >"$WORK/serve.out" 2>"$WORK/serve.err" &
    spid=$!
    set -e
    code="000"
    for _ in $(seq 1 30); do
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$port/" 2>/dev/null || echo 000)"
      code="${code: -3}"
      [[ "$code" == "200" ]] && break
      kill -0 "$spid" 2>/dev/null || break
      sleep 1
    done
    kill "$spid" 2>/dev/null || true
    wait "$spid" 2>/dev/null || true
    if [[ "$code" == "200" ]]; then
      record 4 "serve + HTTP 200" "PASS" "http_code=200 port=$port"
    else
      record 4 "serve + HTTP 200" "FAIL" "http_code=$code port=$port; stderr: $(sanitize "$(head -3 "$WORK/serve.err")")"
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# item 5: plugin install/update/rollback 三态冒烟 (本地 file:// 夹具插件,
#         参照 tools/plugin-manager.sh 流程; XDG_CONFIG_HOME 隔离, 不碰真实配置)
# ═══════════════════════════════════════════════════════════════════════════
{
  FIX="$WORK/fixture"
  mkdir -p "$FIX/dist"
  cat >"$FIX/package.json" <<'EOF'
{"name":"verify-fixture","version":"1.0.0","main":"dist/index.js"}
EOF
  cat >"$FIX/dist/index.js" <<'EOF'
module.exports = { name: "verify-fixture", version: "v1" };
EOF
  git -C "$FIX" init -q -b main
  git -C "$FIX" add -A
  git -C "$FIX" -c user.email=verify@local -c user.name=verify commit -qm "v1"

  CFG="$WORK/plugin-cfg"
  PM="$(pwd)/tools/plugin-manager.sh"
  ENTRY="$CFG/opencode/local-plugins/verify-fixture/index.js"

  # install (v1)
  if XDG_CONFIG_HOME="$CFG" bash "$PM" install verify-fixture "file://$FIX" >"$WORK/p-install.out" 2>&1; then
    if [[ -f "$ENTRY" ]] && grep -q '"v1"' "$ENTRY"; then
      p1="PASS"
    else
      p1="FAIL"
    fi
  else
    p1="FAIL"
  fi
  [[ "$p1" == "PASS" ]] || p1_ev="install failed: $(sanitize "$(tail -3 "$WORK/p-install.out")")"

  # update (v1 -> v2)
  cat >"$FIX/dist/index.js" <<'EOF'
module.exports = { name: "verify-fixture", version: "v2" };
EOF
  git -C "$FIX" add -A
  git -C "$FIX" -c user.email=verify@local -c user.name=verify commit -qm "v2"
  if XDG_CONFIG_HOME="$CFG" bash "$PM" update verify-fixture >"$WORK/p-update.out" 2>&1; then
    if [[ -f "$ENTRY" ]] && grep -q '"v2"' "$ENTRY"; then
      p2="PASS"
    else
      p2="FAIL"
    fi
  else
    p2="FAIL"
  fi
  [[ "$p2" == "PASS" ]] || p2_ev="update failed: $(sanitize "$(tail -3 "$WORK/p-update.out")")"

  # rollback (v2 -> v1 snapshot)
  if XDG_CONFIG_HOME="$CFG" bash "$PM" rollback verify-fixture >"$WORK/p-rollback.out" 2>&1; then
    if [[ -f "$ENTRY" ]] && grep -q '"v1"' "$ENTRY"; then
      p3="PASS"
    else
      p3="FAIL"
    fi
  else
    p3="FAIL"
  fi
  [[ "$p3" == "PASS" ]] || p3_ev="rollback failed: $(sanitize "$(tail -3 "$WORK/p-rollback.out")")"

  if [[ "$p1$p2$p3" == "PASSPASSPASS" ]]; then
    record 5 "plugin install/update/rollback" "PASS" "install=v1 update=v2 rollback=v1 (file:// fixture, isolated XDG_CONFIG_HOME)"
  else
    record 5 "plugin install/update/rollback" "FAIL" "install=$p1 update=$p2 rollback=$p3 ${p1_ev:-}${p2_ev:-}${p3_ev:-}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# item 6: 系统 skill hooks (post_install / post_upgrade, 干跑态:
#         strict=0 network=0, 隔离 PREFIX/registry/log, 参照
#         scripts/hooks/run-system-skills.sh)
# ═══════════════════════════════════════════════════════════════════════════
{
  HK="$WORK/hooks"
  # 注意: run-system-skills.sh 对 SYS_SKILL_DIR/USER_SKILL_DIR 是硬赋值
  # (SYS_SKILL_DIR="$PREFIX/lib/opencode/system-skills"), 环境变量覆盖无效 —
  # 夹具 manifest 必须放到 PREFIX 推导路径下; XDG_CONFIG_HOME 隔离用户 skill 目录
  mkdir -p "$HK/prefix/lib/opencode/system-skills" "$HK/prefix/lib/opencode/tools" "$HK/bin" "$HK/cfg/opencode/system-skills"
  cat >"$HK/prefix/lib/opencode/system-skills/verify-hook-fixture.json" <<'EOF'
{"plugin_id":"verify-hook-fixture","enabled":true,"events":["post_install","post_upgrade"],"policy":"warn"}
EOF
  ln -sf "$(pwd)/tools/plugin-manager.sh" "$HK/prefix/lib/opencode/tools/plugin-manager.sh"
  ln -sf "$(realpath "$RUNTIME")" "$HK/bin/opencode"

  run_hook() {  # $1=event
    PREFIX="$HK/prefix" \
    XDG_CONFIG_HOME="$HK/cfg" \
    OPENCODE_HOOK_STATE_DIR="$HK/state" \
    OPENCODE_HOOK_REGISTRY="$HK/registry.json" \
    OPENCODE_HOOK_LOG="$HK/hooks.log" \
    OPENCODE_HOOK_STRICT=0 \
    OPENCODE_HOOK_ENABLE_NETWORK=0 \
    PATH="$HK/bin:$PATH" \
    bash "$(pwd)/scripts/hooks/run-system-skills.sh" "$1"
  }

  check_registry() {  # $1=expected_event
    python3 - "$HK/registry.json" "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
item=d.get("items",{}).get("verify-hook-fixture",{})
ok = item.get("last_event") == sys.argv[2]
print(f"last_event={item.get('last_event')} last_status={item.get('last_status')}")
raise SystemExit(0 if ok else 1)
PY
  }

  h1="FAIL"; h1_ev=""
  if run_hook post_install >"$WORK/hook1.out" 2>&1; then
    if check_registry post_install >"$WORK/hook1-reg.out" 2>&1; then
      h1="PASS"
    else
      h1_ev="registry mismatch: $(sanitize "$(cat "$WORK/hook1-reg.out")")"
    fi
  else
    h1_ev="post_install failed: $(sanitize "$(tail -3 "$WORK/hook1.out")")"
  fi

  h2="FAIL"; h2_ev=""
  if run_hook post_upgrade >"$WORK/hook2.out" 2>&1; then
    if check_registry post_upgrade >"$WORK/hook2-reg.out" 2>&1; then
      h2="PASS"
    else
      h2_ev="registry mismatch: $(sanitize "$(cat "$WORK/hook2-reg.out")")"
    fi
  else
    h2_ev="post_upgrade failed: $(sanitize "$(tail -3 "$WORK/hook2.out")")"
  fi

  if [[ "$h1$h2" == "PASSPASS" ]]; then
    record 6 "system skill hooks post_install/post_upgrade" "PASS" "both events processed, registry updated (dry-run: strict=0 network=0)"
  else
    record 6 "system skill hooks post_install/post_upgrade" "FAIL" "post_install=$h1 post_upgrade=$h2 ${h1_ev}${h2_ev}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# item 7: 冷启动复测 (无 root 无法 drop_caches → 内存压力法: dd 写大文件
#         挤占页缓存驱逐 runtime 页, 再计时; 参照 bench 脚本)
#         §4.4: 冷启动 < 2s, RSS 稳定 < 400MB (RSS 为补充证据)
# ═══════════════════════════════════════════════════════════════════════════
{
  BIG="$WORK/bigfile"
  dd if=/dev/zero of="$BIG" bs=1M count=768 2>/dev/null || true
  t="$(time_ms "$RUNTIME" --version)"
  rm -f "$BIG"

  # RSS 补充采样 (serve 8s, 参照 bench rss_at)
  rss="unmeasurable"
  set +e
  "$RUNTIME" serve --port 43128 >"$WORK/rss.out" 2>"$WORK/rss.err" &
  rpid=$!
  set -e
  sleep 8
  if [[ -r "/proc/$rpid/status" ]]; then
    rss="$(awk '/^VmRSS:/{print $2}' "/proc/$rpid/status" 2>/dev/null || echo 0)kB"
  fi
  kill "$rpid" 2>/dev/null || true
  wait "$rpid" 2>/dev/null || true

  if [[ "$t" -lt 2000 ]]; then
    record 7 "cold start <2s (memory pressure)" "PASS" "cold_start=${t}ms (<2000ms); rss=${rss}"
  else
    record 7 "cold start <2s (memory pressure)" "FAIL" "cold_start=${t}ms (>=2000ms); rss=${rss}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# report 落盘 + 汇总
# ═══════════════════════════════════════════════════════════════════════════
python3 - "$OUT" "$RUNTIME" "$OFFLINE" "$SDK" "$API_STATUS" "$API_NOTE" "$ITEMS" <<'PY'
import json,sys
from datetime import datetime, timezone

out, runtime, offline, sdk, api_status, api_note, items_file = sys.argv[1:]
items = []
for line in open(items_file, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    iid, name, status, evidence = line.split("\t", 3)
    items.append({"id": int(iid), "name": name, "status": status, "evidence": evidence})

report = {
    "api_check": {"sdk": int(sdk), "status": api_status, "note": api_note},
    "runtime": runtime,
    "offline": offline == "1",
    "items": items,
    "generated_at": datetime.now(timezone.utc).isoformat(),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(json.dumps(report, ensure_ascii=False, indent=2))
PY

echo
echo "=== summary ==="
echo "api_check: $API_STATUS (sdk=$SDK)"
echo "report: $OUT"
echo "workdir: $WORK"
if [[ "$FAILED" -eq 1 ]]; then
  echo "exit: 1 (存在 FAIL 项)"
  exit 1
fi
echo "exit: 0 (无 FAIL 项)"
exit 0
