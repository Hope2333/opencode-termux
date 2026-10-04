#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# press-v3.sh — A2 todo8 (rc6-a2/todo8-hermetic-home): hermetic home remap + UPX press → beta103-press3 kit
#
# 与 press-v2.sh 的差异:
#   - 新增 [1] hermetic home remap：tools/a2/hermetic-home-patch.py 对 graft 中间件
#     原位重映射 46 处烤入的 build 机 home 绝对路径（全部位于内嵌 libopentui .rodata
#     的 assert()/__FILE__ 表；JS bundle 零烤入）。尺寸不变、字节级断言、幂等。
#     背景：w7b hdrfix 前置目录（$TMPDIR/w7b-hdrfix* / w7b-bionic-lib）已随 TMPDIR
#     清理丢失且无生成脚本，libopentui 源码级 -ffile-prefix-map 重建暂不可行；
#     补丁已备（patches/opentui/file-prefix-map.patch + OPENTUI_C_REMAP 机制），
#     待 hdrfix 目录可复现后可切换到重建路线。
#   - graft（TLSDESC shim）复用既有 beta103-grafted（press2 同件，槽位断言已过），
#     hermetic remap 在 graft 后做（覆盖 tlsdesc embed 的 46 处）。
#   - kit 件名后缀 press3，与 press2 并存不覆盖。
#
# 环境变量:
#   SRC_GRAFTED  输入 graft 中间件（默认 beta103-grafted，只读）
#   HERMETIC_BIN hermetic 中间件（默认 beta103-hermetic-grafted；已存在且干净则复用）
#   KIT_DIR      输出 kit 目录（默认 artifacts/build/1.18.32/beta103-press3）
#   UPX_LEVEL    默认 -4
#   SMOKE_RUNS   TUI 冒烟次数（默认 3）

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VER="1.18.32"
SRC_GRAFTED="${SRC_GRAFTED:-$ROOT_DIR/artifacts/build/$VER/opencode-v1-$VER-beta103-grafted}"
HERMETIC_BIN="${HERMETIC_BIN:-$ROOT_DIR/artifacts/build/$VER/opencode-v1-$VER-beta103-hermetic-grafted}"
KIT_DIR="${KIT_DIR:-$ROOT_DIR/artifacts/build/$VER/beta103-press3}"
UPX_LEVEL="${UPX_LEVEL:--4}"
SMOKE_RUNS="${SMOKE_RUNS:-3}"
EV_DIR="$ROOT_DIR/.omo/evidence/a2-v1-effect-rebuild"

for f in "$SRC_GRAFTED" "$ROOT_DIR/tools/a2/hermetic-home-patch.py" \
	"$ROOT_DIR/tools/bun-pty-splice/dist/librust_pty_arm64_musl_patched.so" \
	"$ROOT_DIR/tools/bun-pty-splice/dist/shim.so" \
	"$ROOT_DIR/tools/epoll-shim/dist/libepoll-compat.so"; do
	[[ -e "$f" ]] || { echo "Error: missing $f" >&2; exit 1; }
done
command -v upx >/dev/null 2>&1 || { echo "Error: upx not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 not found" >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "Error: readelf not found" >&2; exit 1; }

df_free_mb() { df -k /data/user/0 | awk 'NR==2{print int($4/1024)}'; }
FREE_MB="$(df_free_mb)"
[[ "$FREE_MB" -ge 800 ]] || {
	echo "Error: only ${FREE_MB}MB free on /data (<800MB gate) — clean scratch first" >&2; exit 1; }

SRC_SHA="$(sha256sum "$SRC_GRAFTED" | awk '{print $1}')"
SRC_SZ="$(stat -c%s "$SRC_GRAFTED")"
echo "==> press-v3: src_grafted=$SRC_GRAFTED"
echo "    src size=$SRC_SZ sha256=$SRC_SHA"
echo "    kit=$KIT_DIR upx=$UPX_LEVEL free=${FREE_MB}MB"

# ── 1. hermetic home remap（原位 .rodata 重映射 + 槽位/门禁断言） ─────────
echo "==> [1/6] hermetic home remap"
if [[ ! -e "$HERMETIC_BIN" ]] || [[ "$(strings "$HERMETIC_BIN" | grep -c 'data/data/com.termux/files/home' || true)" != "0" ]]; then
	cp -p "$SRC_GRAFTED" "$HERMETIC_BIN"
	python3 "$ROOT_DIR/tools/a2/hermetic-home-patch.py" "$HERMETIC_BIN" "$HERMETIC_BIN"
else
	echo "    hermetic intermediate already clean (reuse)"
fi
chmod 755 "$HERMETIC_BIN"
HERMETIC_SHA="$(sha256sum "$HERMETIC_BIN" | awk '{print $1}')"
HERMETIC_SZ="$(stat -c%s "$HERMETIC_BIN")"
echo "    hermetic size=$HERMETIC_SZ sha256=$HERMETIC_SHA"

# 断言：home 路径门 = 0；槽位 guard / INIT_ARRAY / TLSDESC 完整
python3 - "$ROOT_DIR" "$HERMETIC_BIN" << 'PYEOF'
import sys, subprocess, tempfile, os
sys.path.insert(0, sys.argv[1] + "/tools/transplant")
import swap_tui
data = open(sys.argv[2], "rb").read()
assert data.count(b"/data/data/com.termux/files/home") == 0, "home-path gate failed"
base = swap_tui.find_libopentui_asset(data)
so = data[base:base + swap_tui.elf_size(data, base)]
assert swap_tui.has_ffi_guard(so), "FFI guard missing after remap"
with tempfile.NamedTemporaryFile(suffix=".so", delete=False) as f:
	f.write(so); tmp = f.name
init = subprocess.run(["readelf", "-d", tmp], capture_output=True, text=True).stdout.count("INIT_ARRAY")
tlsdesc = subprocess.run(["readelf", "-r", tmp], capture_output=True, text=True).stdout.count("R_AARCH64_TLSDESC")
os.unlink(tmp)
assert init >= 2, f"INIT_ARRAY={init} after remap"
assert tlsdesc == 11, f"TLSDESC={tlsdesc} after remap (expect 11)"
print(f"    hermetic assert: gate=0, slot@{base:#x} {len(so)}B, guard=OK, INIT_ARRAY={init}, TLSDESC={tlsdesc}")
PYEOF

# ── 2. UPX press（只读输入，-o 出新件） ──────────────────────────────────
echo "==> [2/6] upx $UPX_LEVEL press"
PRESS_DIR="$KIT_DIR/runtime"
PRESS_BIN="$PRESS_DIR/opencode-v1-$VER-beta103-press3"
mkdir -p "$PRESS_DIR"
if [[ ! -e "$PRESS_BIN" ]]; then
	upx "$UPX_LEVEL" -o "$PRESS_BIN" "$HERMETIC_BIN"
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
# beta103-press3 candidate launcher (A2 todo8: hermetic home remap + press)
set -euo pipefail
D="\$(cd "\$(dirname "\$0")" && pwd)"
export LD_LIBRARY_PATH="\$D/pty:\$D/epoll\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
if [ -f "\$D/epoll/libepoll-compat.so" ]; then
	export LD_PRELOAD="\$D/epoll/libepoll-compat.so\${LD_PRELOAD:+:\$LD_PRELOAD}"
fi
if [ -f "\$D/pty/librust_pty_arm64_musl_patched.so" ]; then
	export BUN_PTY_LIB="\$D/pty/librust_pty_arm64_musl_patched.so"
fi
exec "\$D/runtime/opencode-v1-$VER-beta103-press3" "\$@"
LAUNCHER
chmod 755 "$KIT_DIR/opencode"

# ── 4. PTY graft 本机探针 ────────────────────────────────────────────────
echo "==> [4/6] pty graft probe (ctypes dlopen + canary)"
W="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2t8-probe.XXXXXX")"
LD_LIBRARY_PATH="$KIT_DIR/pty" OPENCODE_PTY_SHIM_LOG="$W/canary.log" python3 - "$KIT_DIR/pty/librust_pty_arm64_musl_patched.so" << 'PYEOF'
import ctypes, sys
lib = ctypes.CDLL(sys.argv[1])
syms = ["bun_pty_spawn", "bun_pty_read", "bun_pty_write", "bun_pty_resize",
        "bun_pty_kill", "bun_pty_close", "bun_pty_get_pid", "bun_pty_get_exit_code"]
for s in syms:
    getattr(lib, s)
print(f"pty probe: symbols resolved {len(syms)}/8")
PYEOF
if [[ -s "$W/canary.log" ]] && grep -q "shim loaded" "$W/canary.log"; then
	echo "    shim canary fired via DT_NEEDED: $(cat "$W/canary.log")"
else
	echo "Error: shim canary did not fire — shim not loaded" >&2
	exit 1
fi
rm -rf "$W"

# ── 5. --version（launcher 链路 + 压件直跑 双验） ─────────────────────────
echo "==> [5/6] --version"
V_KIT="$("$KIT_DIR/opencode" --version)"
echo "    launcher --version = $V_KIT"
[[ "$V_KIT" == *"$VER"* ]] || { echo "Error: launcher version mismatch" >&2; exit 1; }
V_PRESS="$("$PRESS_BIN" --version)"
echo "    pressed  --version = $V_PRESS"
[[ "$V_PRESS" == *"$VER"* ]] || { echo "Error: pressed version mismatch" >&2; exit 1; }

# ── 6. TUI 冒烟 ×N（launcher 链路；判据=task-3-smoke.sh 同系） ───────────
if [[ "${SKIP_SMOKE:-0}" != "1" ]]; then
	echo "==> [6/6] TUI smoke x$SMOKE_RUNS via launcher"
	for i in $(seq 1 "$SMOKE_RUNS"); do
		bash "$EV_DIR/task-3-smoke.sh" "$KIT_DIR/opencode" "press3-run$i"
	done
else
	echo "==> [6/6] smoke skipped (SKIP_SMOKE=1)"
fi

# ── MANIFEST ─────────────────────────────────────────────────────────────
cat > "$KIT_DIR/MANIFEST.txt" << MANIFEST
# beta103-press3 candidate kit (A2 todo8: hermetic home remap + press) $(date -u +%FT%TZ)
src_grafted: $SRC_GRAFTED
src_size: $SRC_SZ
src_sha256: $SRC_SHA
hermetic_patch: tools/a2/hermetic-home-patch.py (46 baked home paths remapped to /opentui-vendor-src/, in-place .rodata assert-string remap, size unchanged)
hermetic: artifacts/build/1.18.32/opencode-v1-$VER-beta103-hermetic-grafted
hermetic_size: $HERMETIC_SZ
hermetic_sha256: $HERMETIC_SHA
hermetic_assert: home-path gate=0, slot guard=OK, INIT_ARRAY=2, TLSDESC=11
pressed: runtime/opencode-v1-$VER-beta103-press3
pressed_size: $PRESS_SZ
pressed_sha256: $PRESS_SHA
ratio: $(awk "BEGIN{printf \"%.1f%%\", $PRESS_SZ*100/$HERMETIC_SZ}")
upx_level: $UPX_LEVEL
pty: pty/librust_pty_arm64_musl_patched.so sha256=$(sha256sum "$KIT_DIR/pty/librust_pty_arm64_musl_patched.so" | awk '{print $1}')
pty_shim: pty/shim.so sha256=$(sha256sum "$KIT_DIR/pty/shim.so" | awk '{print $1}')
epoll: epoll/libepoll-compat.so sha256=$(sha256sum "$KIT_DIR/epoll/libepoll-compat.so" | awk '{print $1}')
launcher: opencode (BUN_PTY_LIB + LD_PRELOAD epoll-compat 注入)
MANIFEST
echo "==> MANIFEST written"
echo "==> press-v3 done: $KIT_DIR"
