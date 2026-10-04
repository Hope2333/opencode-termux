#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# press-v5.sh — A2 todo16 (rc6-a2/todo16-bun-absorb): 零外部 .so candidate kit.
#
# 与 press-v4.sh 的差异（本脚本为其删减版，链路其余完全同源）:
#   - 无 epoll/ 资产: bun 1.4.2 上游已内建 epoll_pwait 回退（android target
#     无条件跳过 pwait2 + 内核<5.11 uname 门 + ENOSYS 运行时回退，
#     src/analytics/lib.rs Bun__isEpollPwait2SupportedOnLinuxKernel +
#     packages/bun-usockets/src/eventing/epoll_kqueue.c），strace 实证 441
#     零调用 → libepoll-compat.so 退役。
#   - 无 pty/ 资产: bionic-native librust_pty（tools/bun-pty-embed/）经
#     pty-embed-store-patch.sh 进 store，bun --compile 内嵌，运行时由 bun
#     自身机制提取 $TMPDIR/.bun-*.so 后 dlopen（strace 实证）→
#     pty/librust_pty_arm64_musl_patched.so + shim.so + BUN_PTY_LIB 退役。
#   - launcher 变为裸 exec：无 LD_LIBRARY_PATH / LD_PRELOAD / BUN_PTY_LIB。
#   - kit 增加零外部 .so 断言（目录无 .so、压件 NEEDED 无 glibc）。
#
# 环境变量:
#   SRC_RUNTIME  输入未压 runtime（默认 beta103-t16-absorb，须先跑
#                pty-embed-store-patch.sh + build-v1.sh）
#   GRAFTED_BIN  graft 后中间件（默认 beta103-t16-grafted；复用规则同 v4）
#   HERMETIC_BIN hermetic 中间件（默认 beta103-t16-hermetic-grafted）
#   KIT_DIR      输出 kit 目录（默认 artifacts/build/1.18.32/beta103-press5）
#   UPX_LEVEL    默认 -4
#   SMOKE_RUNS   TUI 冒烟次数（默认 3）

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VER="1.18.32"
SRC_RUNTIME="${SRC_RUNTIME:-$ROOT_DIR/artifacts/build/$VER/opencode-v1-$VER-beta103-t16-absorb}"
GRAFT_LIB="$ROOT_DIR/artifacts/transplant/opentui-bionic-tlsdesc/libopentui.embed.so"
GRAFTED_BIN="${GRAFTED_BIN:-$ROOT_DIR/artifacts/build/$VER/opencode-v1-$VER-beta103-t16-grafted}"
HERMETIC_BIN="${HERMETIC_BIN:-$ROOT_DIR/artifacts/build/$VER/opencode-v1-$VER-beta103-t16-hermetic-grafted}"
KIT_DIR="${KIT_DIR:-$ROOT_DIR/artifacts/build/$VER/beta103-press5}"
UPX_LEVEL="${UPX_LEVEL:--4}"
SMOKE_RUNS="${SMOKE_RUNS:-3}"
EV_DIR="$ROOT_DIR/.omo/evidence/a2-v1-effect-rebuild"

for f in "$SRC_RUNTIME" "$GRAFT_LIB" "$ROOT_DIR/tools/a2/hermetic-home-patch.py"; do
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
echo "==> press-v5: src=$SRC_RUNTIME"
echo "    src size=$SRC_SZ sha256=$SRC_SHA"
echo "    kit=$KIT_DIR upx=$UPX_LEVEL free=${FREE_MB}MB"

# ── 0. TLSDESC shim graft（swap_tui 槽位手术 + 三重断言；press-v4 同件） ──
echo "==> [0/6] tlsdesc shim graft (swap_tui slot surgery)"
if [[ ! -e "$GRAFTED_BIN" ]]; then
	python3 "$ROOT_DIR/tools/transplant/swap_tui.py" \
		--binary "$SRC_RUNTIME" --tui-lib "$GRAFT_LIB" --out "$GRAFTED_BIN"
fi
chmod 755 "$GRAFTED_BIN"
python3 - "$ROOT_DIR" "$SRC_RUNTIME" "$GRAFTED_BIN" "$GRAFT_LIB" << 'PYEOF'
import sys
sys.path.insert(0, sys.argv[1] + "/tools/transplant")
import swap_tui
orig = open(sys.argv[2], "rb").read()
graf = open(sys.argv[3], "rb").read()
lib = open(sys.argv[4], "rb").read()
base = swap_tui.find_libopentui_asset(graf)
assert base >= 0, "grafted: libopentui asset not found"
so = swap_tui.elf_size(orig, base)
sg = swap_tui.elf_size(graf, base)
assert len(orig) == len(graf), "total size drifted"
assert orig[:base] == graf[:base], "prefix drift"
assert orig[base + so:] == graf[base + so:], "suffix drift"
assert graf[base:base + sg] == lib, "slot content != graft lib"
assert sg <= so, "graft lib larger than slot"
print(f"    graft assert: slot@{base:#x} {so}B (embed {sg}B + {so-sg}B pad), "
      f"0B drift outside slot, total {len(graf)}B")
PYEOF
W="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2t16-assert.XXXXXX")"
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
echo "    graft assert: INIT_ARRAY ctor present, TLSDESC relocs=$TLSDESC preserved"
GRAFTED_SHA="$(sha256sum "$GRAFTED_BIN" | awk '{print $1}')"
GRAFTED_SZ="$(stat -c%s "$GRAFTED_BIN")"
echo "    grafted size=$GRAFTED_SZ sha256=$GRAFTED_SHA"

# ── 1. hermetic home remap（原位 .rodata 重映射 + 槽位/门禁断言） ─────────
echo "==> [1/6] hermetic home remap"
if [[ ! -e "$HERMETIC_BIN" ]] || [[ "$(strings "$HERMETIC_BIN" | grep -c 'data/data/com.termux/files/home' || true)" != "0" ]]; then
	cp -p "$GRAFTED_BIN" "$HERMETIC_BIN"
	python3 "$ROOT_DIR/tools/a2/hermetic-home-patch.py" "$HERMETIC_BIN" "$HERMETIC_BIN"
else
	echo "    hermetic intermediate already clean (reuse)"
fi
chmod 755 "$HERMETIC_BIN"
HERMETIC_SHA="$(sha256sum "$HERMETIC_BIN" | awk '{print $1}')"
HERMETIC_SZ="$(stat -c%s "$HERMETIC_BIN")"
echo "    hermetic size=$HERMETIC_SZ sha256=$HERMETIC_SHA"

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
PRESS_BIN="$PRESS_DIR/opencode-v1-$VER-beta103-press5"
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

# ── 3. 零外部 .so 断言 + 裸 launcher ─────────────────────────────────────
echo "==> [3/6] zero-external-.so gate + bare launcher"
EXT_SO="$(find "$KIT_DIR" -name '*.so' | grep -v "^$PRESS_DIR/" || true)"
[[ -z "$EXT_SO" ]] || { echo "Error: external .so present in kit: $EXT_SO" >&2; exit 1; }
NEED="$(readelf -d "$HERMETIC_BIN" | grep NEEDED || true)"
echo "$NEED" | grep -Eq 'NEEDED.*lib(c|m|dl|pthread|rt)\.so\.[0-9]' && {
	echo "Error: glibc NEEDED in hermetic binary: $NEED" >&2; exit 1; }
echo "    zero-external-.so gate OK (kit has no loose .so; NEEDED bionic-only)"
cat > "$KIT_DIR/opencode" << LAUNCHER
#!/data/data/com.termux/files/usr/bin/bash
# beta103-press5 candidate launcher (A2 todo16: bun-absorb, zero external .so)
set -euo pipefail
D="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$D/runtime/opencode-v1-$VER-beta103-press5" "\$@"
LAUNCHER
chmod 755 "$KIT_DIR/opencode"

# ── 4. 内嵌 pty 探针（压件直跑，无 env 注入） ─────────────────────────────
echo "==> [4/6] embedded-pty probe (no env injection)"
# bun 1.4.2 内嵌 pty 资产名断言：压件应携带 librust_pty_arm64 bunfs 资产
PT_ASSET="$(grep -c 'librust_pty_arm64-[a-z0-9]*\.so' "$HERMETIC_BIN" || true)"
[[ "$PT_ASSET" -ge 1 ]] || { echo "Error: embedded librust_pty asset not found in binary" >&2; exit 1; }
echo "    embedded pty asset marker found ($PT_ASSET hits)"

# ── 5. --version（launcher 链路 + 压件直跑 双验，均裸跑零注入） ───────────
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
		bash "$EV_DIR/task-3-smoke.sh" "$KIT_DIR/opencode" "press5-run$i"
	done
else
	echo "==> [6/6] smoke skipped (SKIP_SMOKE=1)"
fi

# ── MANIFEST ─────────────────────────────────────────────────────────────
cat > "$KIT_DIR/MANIFEST.txt" << MANIFEST
# beta103-press5 candidate kit (A2 todo16: bun-absorb, zero external .so) $(date -u +%FT%TZ)
src_runtime: $SRC_RUNTIME
src_size: $SRC_SZ
src_sha256: $SRC_SHA
android_bun: artifacts/transplant/android-bun/bun-1.4.2/bun (bun-linux-aarch64-android, NDK r27c, android 28)
epoll: none — bun 1.4.2 builtin fallback (android target skips pwait2; kernel<5.11 gate; ENOSYS->epoll_pwait); strace 441=0
pty: embedded — tools/bun-pty-embed bionic build inside bun-pty store chunk; extracted by bun to \$TMPDIR/.bun-*.so at runtime; no BUN_PTY_LIB / shim.so
graft_lib: artifacts/transplant/opentui-bionic-tlsdesc/libopentui.embed.so
graft_lib_sha256: de06c780a23ef8bdff481e34668db3e89437604605d8b8cbc11c959bc1cede5f
grafted: $GRAFTED_BIN
grafted_size: $GRAFTED_SZ
grafted_sha256: $GRAFTED_SHA
hermetic_patch: tools/a2/hermetic-home-patch.py (baked home paths remapped to /opentui-vendor-src/, in-place .rodata assert-string remap, size unchanged)
hermetic: $HERMETIC_BIN
hermetic_size: $HERMETIC_SZ
hermetic_sha256: $HERMETIC_SHA
pressed: runtime/opencode-v1-$VER-beta103-press5
pressed_size: $PRESS_SZ
pressed_sha256: $PRESS_SHA
ratio: $(awk "BEGIN{printf \"%.1f%%\", $PRESS_SZ*100/$HERMETIC_SZ}")
upx_level: $UPX_LEVEL
external_so: NONE (kit-wide gate)
launcher: opencode (bare exec, no env injection)
MANIFEST
echo "==> MANIFEST written"
echo "==> press-v5 done: $KIT_DIR"
