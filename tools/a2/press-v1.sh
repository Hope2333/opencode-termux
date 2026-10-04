#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# press-v1.sh — A2 todo4: beta103 PTY graft + UPX press → 终验候选件（kit）
#
# 复刻 B2 先例（rc6-b2-upx-tui）:
#   - PTY graft = bun-pty splice 外置资产 + BUN_PTY_LIB 注入（task-4-pty.txt 先例；
#     v1 runtime 同样内置 BUN_PTY_LIB probe 链，见 beta103 ELF 内 loader JS）
#   - press    = upx -4（B2/RC5 同参数系；v1.18.33 stock upx -4 VIABLE 先例 33.7%）
#   - 附带 epoll-compat shim（bun 1.4.0 底座在 kernel<5.1 需 LD_PRELOAD 转译
#     syscall 441，oscar 3.18 必需；kernel>=5.1 加载无害，旗舰 6.6 已实证）
#
# kit 布局契约（task-5 上机部署单位）:
#   <KIT>/opencode                                launcher（自定位，注入 pty/epoll 后 exec runtime）
#   <KIT>/runtime/opencode-v1-1.18.32-beta103-press   UPX 压后 runtime
#   <KIT>/pty/{librust_pty_arm64_musl_patched.so,shim.so}
#   <KIT>/epoll/libepoll-compat.so
#   <KIT>/MANIFEST.txt                            size/sha256 记录
#
# 禁令: 只读输入件（upx -o 出新文件）；rm -rf 仅限 kit 目录本身。
#
# 环境变量:
#   SRC_RUNTIME  输入未压 runtime（默认 beta103-bump）
#   KIT_DIR      输出 kit 目录（默认 artifacts/build/1.18.32/beta103-press）
#   UPX_LEVEL    默认 -4
#   SKIP_SMOKE   1 = 跳过冒烟（默认 0）

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VER="1.18.32"
SRC_RUNTIME="${SRC_RUNTIME:-$ROOT_DIR/artifacts/build/$VER/opencode-v1-$VER-beta103-bump}"
KIT_DIR="${KIT_DIR:-$ROOT_DIR/artifacts/build/$VER/beta103-press}"
UPX_LEVEL="${UPX_LEVEL:--4}"
EV_DIR="$ROOT_DIR/.omo/evidence/a2-v1-effect-rebuild"

for f in "$SRC_RUNTIME" \
	"$ROOT_DIR/tools/bun-pty-splice/dist/librust_pty_arm64_musl_patched.so" \
	"$ROOT_DIR/tools/bun-pty-splice/dist/shim.so" \
	"$ROOT_DIR/tools/epoll-shim/dist/libepoll-compat.so"; do
	[[ -e "$f" ]] || { echo "Error: missing $f" >&2; exit 1; }
done
command -v upx >/dev/null 2>&1 || { echo "Error: upx not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 not found" >&2; exit 1; }

df_free_mb() { df -k /data/user/0 | awk 'NR==2{print int($4/1024)}'; }
FREE_MB="$(df_free_mb)"
[[ "$FREE_MB" -ge 800 ]] || {
	echo "Error: only ${FREE_MB}MB free on /data (<800MB gate) — clean scratch first" >&2; exit 1; }

SRC_SHA="$(sha256sum "$SRC_RUNTIME" | awk '{print $1}')"
SRC_SZ="$(stat -c%s "$SRC_RUNTIME")"
echo "==> press-v1: src=$SRC_RUNTIME"
echo "    src size=$SRC_SZ sha256=$SRC_SHA"
echo "    kit=$KIT_DIR upx=$UPX_LEVEL free=${FREE_MB}MB"

# ── 1. 资产 sha 锚（B2 验证台基准，逐字节确定性） ─────────────────────────
echo "==> [1/6] asset sha gates"
echo "1047d3e2b55580918b01256e992817ff46e5a2521c7421fa04235f5799f21a0d  $ROOT_DIR/tools/bun-pty-splice/dist/librust_pty_arm64_musl_patched.so" | sha256sum -c - >/dev/null
echo "babfea63c10282730fa8fda35ed41e67192ccb55ab10459d428a87483df5d2e9  $ROOT_DIR/tools/bun-pty-splice/dist/shim.so" | sha256sum -c - >/dev/null
echo "    pty splice assets OK (patched 1047d3e2… / shim babfea63…)"

# ── 2. UPX press（只读输入，-o 出新件） ──────────────────────────────────
echo "==> [2/6] upx $UPX_LEVEL press"
PRESS_DIR="$KIT_DIR/runtime"
PRESS_BIN="$PRESS_DIR/opencode-v1-$VER-beta103-press"
mkdir -p "$PRESS_DIR"
if [[ ! -e "$PRESS_BIN" ]]; then
	upx "$UPX_LEVEL" -o "$PRESS_BIN" "$SRC_RUNTIME"
fi
upx -t "$PRESS_BIN"
chmod 755 "$PRESS_BIN"
PRESS_SZ="$(stat -c%s "$PRESS_BIN")"
PRESS_SHA="$(sha256sum "$PRESS_BIN" | awk '{print $1}')"
echo "    pressed size=$PRESS_SZ sha256=$PRESS_SHA"
FREE_MB="$(df_free_mb)"
[[ "$FREE_MB" -ge 300 ]] || { echo "Error: ${FREE_MB}MB free after press (<300MB)" >&2; exit 1; }

# ── 3. 资产落位 + launcher ───────────────────────────────────────────────
echo "==> [3/6] assets + launcher"
mkdir -p "$KIT_DIR/pty" "$KIT_DIR/epoll"
cp -p "$ROOT_DIR/tools/bun-pty-splice/dist/librust_pty_arm64_musl_patched.so" "$KIT_DIR/pty/"
cp -p "$ROOT_DIR/tools/bun-pty-splice/dist/shim.so" "$KIT_DIR/pty/"
cp -p "$ROOT_DIR/tools/epoll-shim/dist/libepoll-compat.so" "$KIT_DIR/epoll/"
cat > "$KIT_DIR/opencode" << LAUNCHER
#!/data/data/com.termux/files/usr/bin/bash
# beta103-press candidate launcher (A2 todo4; B2 splice precedent)
set -euo pipefail
D="\$(cd "\$(dirname "\$0")" && pwd)"
export LD_LIBRARY_PATH="\$D/pty:\$D/epoll\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
if [ -f "\$D/epoll/libepoll-compat.so" ]; then
	export LD_PRELOAD="\$D/epoll/libepoll-compat.so\${LD_PRELOAD:+:\$LD_PRELOAD}"
fi
if [ -f "\$D/pty/librust_pty_arm64_musl_patched.so" ]; then
	export BUN_PTY_LIB="\$D/pty/librust_pty_arm64_musl_patched.so"
fi
exec "\$D/runtime/opencode-v1-$VER-beta103-press" "\$@"
LAUNCHER
chmod 755 "$KIT_DIR/opencode"

# ── 4. PTY graft 本机探针（B2 ctypes 先例: 8 符号 + shim canary） ────────
echo "==> [4/6] pty graft probe (ctypes dlopen + canary)"
W="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2t4-probe.XXXXXX")"
trap 'rm -rf "$W"' EXIT
LD_LIBRARY_PATH="$KIT_DIR/pty" OPENCODE_PTY_SHIM_LOG="$W/canary.log" python3 - "$KIT_DIR/pty/librust_pty_arm64_musl_patched.so" << 'PYEOF'
import ctypes, os, sys
lib = ctypes.CDLL(sys.argv[1])
syms = ["bun_pty_spawn", "bun_pty_read", "bun_pty_write", "bun_pty_resize",
        "bun_pty_kill", "bun_pty_close", "bun_pty_get_pid", "bun_pty_get_exit_code"]
for s in syms:
    getattr(lib, s)
print(f"pty probe: symbols resolved {len(syms)}/8")
PYEOF
CANARY="$W/canary.log"
if [[ -s "$CANARY" ]] && grep -q "shim loaded" "$CANARY"; then
	echo "    shim canary fired via DT_NEEDED: $(cat "$CANARY")"
else
	echo "Error: shim canary did not fire ($CANARY empty) — shim not loaded" >&2
	exit 1
fi

# ── 5. --version（launcher 链路 + 压件直跑 双验） ─────────────────────────
echo "==> [5/6] --version"
V_KIT="$("$KIT_DIR/opencode" --version)"
echo "    launcher --version = $V_KIT"
[[ "$V_KIT" == *"$VER"* ]] || { echo "Error: launcher version mismatch" >&2; exit 1; }
V_PRESS="$("$PRESS_BIN" --version)"
echo "    pressed  --version = $V_PRESS"
[[ "$V_PRESS" == *"$VER"* ]] || { echo "Error: pressed version mismatch" >&2; exit 1; }

# ── 6. TUI 冒烟（launcher 链路；对照=task-3 未压判据同系） ───────────────
if [[ "${SKIP_SMOKE:-0}" != "1" ]]; then
	echo "==> [6/6] TUI smoke via launcher (task-3-smoke.sh harness)"
	bash "$EV_DIR/task-3-smoke.sh" "$KIT_DIR/opencode" press-pressed
else
	echo "==> [6/6] smoke skipped (SKIP_SMOKE=1)"
fi

# ── MANIFEST ─────────────────────────────────────────────────────────────
cat > "$KIT_DIR/MANIFEST.txt" << MANIFEST
# beta103-press candidate kit (A2 todo4) $(date -u +%FT%TZ)
src_runtime: $SRC_RUNTIME
src_size: $SRC_SZ
src_sha256: $SRC_SHA
pressed: runtime/opencode-v1-$VER-beta103-press
pressed_size: $PRESS_SZ
pressed_sha256: $PRESS_SHA
ratio: $(awk "BEGIN{printf \"%.1f%%\", $PRESS_SZ*100/$SRC_SZ}")
upx_level: $UPX_LEVEL
pty: pty/librust_pty_arm64_musl_patched.so sha256=$(sha256sum "$KIT_DIR/pty/librust_pty_arm64_musl_patched.so" | awk '{print $1}')
pty_shim: pty/shim.so sha256=$(sha256sum "$KIT_DIR/pty/shim.so" | awk '{print $1}')
epoll: epoll/libepoll-compat.so sha256=$(sha256sum "$KIT_DIR/epoll/libepoll-compat.so" | awk '{print $1}')
launcher: opencode (BUN_PTY_LIB + LD_PRELOAD epoll-compat 注入)
MANIFEST
echo "==> MANIFEST written"
echo "==> press-v1 done: $KIT_DIR"
