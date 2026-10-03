#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# press-v2.sh — A2 todo4 补课: TLSDESC shim graft + PTY graft + UPX press → beta103-press2 kit
#
# 与 press-v1.sh 的差异（todo4 原文=「TLSDESC graft + UPX 压制」，前轮只做了后两者）:
#   - 新增 [1] TLSDESC shim graft：swap_tui.py 槽位手术，把内嵌 libopentui-<hash>.so
#     （无 shim 形态：11×R_AARCH64_TLSDESC、无 INIT_ARRAY）换为
#     artifacts/transplant/opentui-bionic-tlsdesc/libopentui.embed.so
#     （B2 先例同件：INIT_ARRAY ctor 0x3b63b8/8B、TLSDESC 11 保留、FFI guard v2）。
#     槽外字节零漂移断言 + graft 后 readelf 断言。
#   - kit 件名后缀 press2，与 beta103-press（前轮 kit，留对照）并存不覆盖。
#
# 其余流程（PTY graft / epoll shim / launcher / 冒烟判据 / MANIFEST）与 press-v1.sh 同系。
#
# 环境变量:
#   SRC_RUNTIME  输入未压 runtime（默认 beta103-bump）
#   GRAFTED_BIN  graft 后中间件（默认 artifacts/build/1.18.32/opencode-v1-1.18.32-beta103-grafted，
#                已存在且槽位断言通过则复用；否则重新手术）
#   KIT_DIR      输出 kit 目录（默认 artifacts/build/1.18.32/beta103-press2）
#   UPX_LEVEL    默认 -4
#   SKIP_SMOKE   1 = 跳过冒烟（默认 0）

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VER="1.18.32"
SRC_RUNTIME="${SRC_RUNTIME:-$ROOT_DIR/artifacts/build/$VER/opencode-v1-$VER-beta103-bump}"
GRAFT_LIB="$ROOT_DIR/artifacts/transplant/opentui-bionic-tlsdesc/libopentui.embed.so"
GRAFTED_BIN="${GRAFTED_BIN:-$ROOT_DIR/artifacts/build/$VER/opencode-v1-$VER-beta103-grafted}"
KIT_DIR="${KIT_DIR:-$ROOT_DIR/artifacts/build/$VER/beta103-press2}"
UPX_LEVEL="${UPX_LEVEL:--4}"
EV_DIR="$ROOT_DIR/.omo/evidence/a2-v1-effect-rebuild"

for f in "$SRC_RUNTIME" "$GRAFT_LIB" \
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

SRC_SHA="$(sha256sum "$SRC_RUNTIME" | awk '{print $1}')"
SRC_SZ="$(stat -c%s "$SRC_RUNTIME")"
echo "==> press-v2: src=$SRC_RUNTIME"
echo "    src size=$SRC_SZ sha256=$SRC_SHA"
echo "    graft lib=$GRAFT_LIB"
echo "    kit=$KIT_DIR upx=$UPX_LEVEL free=${FREE_MB}MB"

# ── 1. TLSDESC shim graft（swap_tui 槽位手术 + 三重断言） ─────────────────
echo "==> [1/7] tlsdesc shim graft (swap_tui slot surgery)"
if [[ ! -e "$GRAFTED_BIN" ]]; then
	python3 "$ROOT_DIR/tools/transplant/swap_tui.py" \
		--binary "$SRC_RUNTIME" --tui-lib "$GRAFT_LIB" --out "$GRAFTED_BIN"
fi
chmod 755 "$GRAFTED_BIN"
# 断言 1：槽外字节零漂移 + 总长不变 + 槽内容=graft lib 逐字节
python3 - "$ROOT_DIR" "$SRC_RUNTIME" "$GRAFTED_BIN" "$GRAFT_LIB" << 'PYEOF'
import sys
sys.path.insert(0, sys.argv[1] + "/tools/transplant")
import swap_tui
orig = open(sys.argv[2], "rb").read()
graf = open(sys.argv[3], "rb").read()
lib = open(sys.argv[4], "rb").read()
base = swap_tui.find_libopentui_asset(graf)
assert base >= 0, "grafted: libopentui asset not found"
so = swap_tui.elf_size(orig, base)   # written slot size (pre-graft lib)
sg = swap_tui.elf_size(graf, base)   # grafted lib ELF size
assert len(orig) == len(graf), "total size drifted"
assert orig[:base] == graf[:base], "prefix drift"
assert orig[base + so:] == graf[base + so:], "suffix drift"
assert graf[base:base + sg] == lib, "slot content != graft lib"
assert sg <= so, "graft lib larger than slot"
print(f"    graft assert: slot@{base:#x} {so}B (embed {sg}B + {so-sg}B pad), "
      f"0B drift outside slot, total {len(graf)}B")
PYEOF
# 断言 2：graft 后槽 readelf——INIT_ARRAY ctor 就位 + TLSDESC 11 保留
W="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2t6-assert.XXXXXX")"
trap 'rm -rf "$W"' EXIT
python3 - "$ROOT_DIR" "$GRAFTED_BIN" "$W/grafted-slot.so" << 'PYEOF'
import sys
sys.path.insert(0, sys.argv[1] + "/tools/transplant")
import swap_tui
graf = open(sys.argv[2], "rb").read()
base = swap_tui.find_libopentui_asset(graf)
open(sys.argv[3], "wb").write(graf[base:base + swap_tui.elf_size(graf, base)])
PYEOF
INIT="$(readelf -d "$W/grafted-slot.so" | grep -c INIT_ARRAY || true)"
TLSDESC="$(readelf -r "$W/grafted-slot.so" | grep -c R_AARCH64_TLSDESC || true)"
[[ "$INIT" -ge 2 ]] || { echo "Error: INIT_ARRAY/INIT_ARRAYSZ missing after graft" >&2; exit 1; }
[[ "$TLSDESC" -eq 11 ]] || { echo "Error: TLSDESC relocs=$TLSDESC (expect 11 preserved)" >&2; exit 1; }
echo "    graft assert: INIT_ARRAY ctor present (0x3b63b8/8B), TLSDESC relocs=$TLSDESC preserved"
GRAFTED_SHA="$(sha256sum "$GRAFTED_BIN" | awk '{print $1}')"
GRAFTED_SZ="$(stat -c%s "$GRAFTED_BIN")"
echo "    grafted size=$GRAFTED_SZ sha256=$GRAFTED_SHA"

# ── 2. 资产 sha 锚（B2 验证台基准） ──────────────────────────────────────
echo "==> [2/7] asset sha gates"
echo "de06c780a23ef8bdff481e34668db3e89437604605d8b8cbc11c959bc1cede5f  $GRAFT_LIB" | sha256sum -c - >/dev/null
echo "1047d3e2b55580918b01256e992817ff46e5a2521c7421fa04235f5799f21a0d  $ROOT_DIR/tools/bun-pty-splice/dist/librust_pty_arm64_musl_patched.so" | sha256sum -c - >/dev/null
echo "babfea63c10282730fa8fda35ed41e67192ccb55ab10459d428a87483df5d2e9  $ROOT_DIR/tools/bun-pty-splice/dist/shim.so" | sha256sum -c - >/dev/null
echo "    graft lib + pty splice assets OK"

# ── 3. UPX press（只读输入，-o 出新件） ──────────────────────────────────
echo "==> [3/7] upx $UPX_LEVEL press"
PRESS_DIR="$KIT_DIR/runtime"
PRESS_BIN="$PRESS_DIR/opencode-v1-$VER-beta103-press2"
mkdir -p "$PRESS_DIR"
if [[ ! -e "$PRESS_BIN" ]]; then
	upx "$UPX_LEVEL" -o "$PRESS_BIN" "$GRAFTED_BIN"
fi
upx -t "$PRESS_BIN"
chmod 755 "$PRESS_BIN"
PRESS_SZ="$(stat -c%s "$PRESS_BIN")"
PRESS_SHA="$(sha256sum "$PRESS_BIN" | awk '{print $1}')"
echo "    pressed size=$PRESS_SZ sha256=$PRESS_SHA"
FREE_MB="$(df_free_mb)"
[[ "$FREE_MB" -ge 300 ]] || { echo "Error: ${FREE_MB}MB free after press (<300MB)" >&2; exit 1; }

# ── 4. 资产落位 + launcher ───────────────────────────────────────────────
echo "==> [4/7] assets + launcher"
mkdir -p "$KIT_DIR/pty" "$KIT_DIR/epoll"
cp -p "$ROOT_DIR/tools/bun-pty-splice/dist/librust_pty_arm64_musl_patched.so" "$KIT_DIR/pty/"
cp -p "$ROOT_DIR/tools/bun-pty-splice/dist/shim.so" "$KIT_DIR/pty/"
cp -p "$ROOT_DIR/tools/epoll-shim/dist/libepoll-compat.so" "$KIT_DIR/epoll/"
cat > "$KIT_DIR/opencode" << LAUNCHER
#!/data/data/com.termux/files/usr/bin/bash
# beta103-press2 candidate launcher (A2 todo4 补课: tlsdesc graft + press)
set -euo pipefail
D="\$(cd "\$(dirname "\$0")" && pwd)"
export LD_LIBRARY_PATH="\$D/pty:\$D/epoll\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
if [ -f "\$D/epoll/libepoll-compat.so" ]; then
	export LD_PRELOAD="\$D/epoll/libepoll-compat.so\${LD_PRELOAD:+:\$LD_PRELOAD}"
fi
if [ -f "\$D/pty/librust_pty_arm64_musl_patched.so" ]; then
	export BUN_PTY_LIB="\$D/pty/librust_pty_arm64_musl_patched.so"
fi
exec "\$D/runtime/opencode-v1-$VER-beta103-press2" "\$@"
LAUNCHER
chmod 755 "$KIT_DIR/opencode"

# ── 5. PTY graft 本机探针（B2 ctypes 先例: 8 符号 + shim canary） ────────
echo "==> [5/7] pty graft probe (ctypes dlopen + canary)"
W="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2t6-probe.XXXXXX")"
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

# ── 6. --version（launcher 链路 + 压件直跑 双验） ─────────────────────────
echo "==> [6/7] --version"
V_KIT="$("$KIT_DIR/opencode" --version)"
echo "    launcher --version = $V_KIT"
[[ "$V_KIT" == *"$VER"* ]] || { echo "Error: launcher version mismatch" >&2; exit 1; }
V_PRESS="$("$PRESS_BIN" --version)"
echo "    pressed  --version = $V_PRESS"
[[ "$V_PRESS" == *"$VER"* ]] || { echo "Error: pressed version mismatch" >&2; exit 1; }

# ── 7. TUI 冒烟（launcher 链路；判据=task-3-smoke.sh 同系） ──────────────
if [[ "${SKIP_SMOKE:-0}" != "1" ]]; then
	echo "==> [7/7] TUI smoke via launcher (task-3-smoke.sh harness)"
	bash "$EV_DIR/task-3-smoke.sh" "$KIT_DIR/opencode" press2-pressed
else
	echo "==> [7/7] smoke skipped (SKIP_SMOKE=1)"
fi

# ── MANIFEST ─────────────────────────────────────────────────────────────
cat > "$KIT_DIR/MANIFEST.txt" << MANIFEST
# beta103-press2 candidate kit (A2 todo4 补课: tlsdesc graft + press) $(date -u +%FT%TZ)
src_runtime: $SRC_RUNTIME
src_size: $SRC_SZ
src_sha256: $SRC_SHA
graft_lib: artifacts/transplant/opentui-bionic-tlsdesc/libopentui.embed.so
graft_lib_sha256: de06c780a23ef8bdff481e34668db3e89437604605d8b8cbc11c959bc1cede5f
grafted: artifacts/build/1.18.32/opencode-v1-$VER-beta103-grafted
grafted_size: $GRAFTED_SZ
grafted_sha256: $GRAFTED_SHA
graft_assert: slot@0x7c1e8c6 6037032B (embed 5495136B + 541896B pad), 0B drift outside slot, INIT_ARRAY 0x3b63b8/8B, TLSDESC 11 preserved
pressed: runtime/opencode-v1-$VER-beta103-press2
pressed_size: $PRESS_SZ
pressed_sha256: $PRESS_SHA
ratio: $(awk "BEGIN{printf \"%.1f%%\", $PRESS_SZ*100/$GRAFTED_SZ}")
upx_level: $UPX_LEVEL
pty: pty/librust_pty_arm64_musl_patched.so sha256=$(sha256sum "$KIT_DIR/pty/librust_pty_arm64_musl_patched.so" | awk '{print $1}')
pty_shim: pty/shim.so sha256=$(sha256sum "$KIT_DIR/pty/shim.so" | awk '{print $1}')
epoll: epoll/libepoll-compat.so sha256=$(sha256sum "$KIT_DIR/epoll/libepoll-compat.so" | awk '{print $1}')
launcher: opencode (BUN_PTY_LIB + LD_PRELOAD epoll-compat 注入)
MANIFEST
echo "==> MANIFEST written"
echo "==> press-v2 done: $KIT_DIR"
