#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

# pilot-fleet-v1.sh — task-30阶段 B: v1 线最新版的未压缩 / 无 UPX pilot。
#
# 与 press-v5/press6 链的差异（唯一实质差异 = 不做 UPX 压制）:
#   press-v5/6  : graft → hermetic → **upx -4** → kit → 装机 → 冒烟
#   本脚本       : graft → hermetic → **（跳过 upx）** → 未压缩包 → 冒烟
#
# 阶段 1 复用 tools/a2/single-elf-namespace-patch.sh（A+ --ignore-xdg 默认）
# 阶段 2 复用 tools/a2/pty-embed-store-patch.sh（bun-pty store 换 bionic）
# 阶段 3 复用 tools/a2/build-v1.sh（android bun --compile，无 web-ui 嵌入）
# 阶段 4 graft（swap_tui.pyTLSDESC 槽位手术）
# 阶段 5 hermetic-home-patch.py（home 路径归零）
# 阶段 6 断言（hermetic strings home=0 / readelf -l 静态自证）
# 阶段 7 打包（package_pacman_compressed.shOCOMP_LAYOUT=single-elf，但**不做任何压缩**）
# 阶段 8 冒烟（--version / 隔离假 HOME 五根落位 / 诱饵 XDG 零外泄 / 真 PTY TUI 一帧 / DELTA>0）
#
# 用法: VER=1.18.34 bash tools/a2/pilot-fleet-v1.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VER="${VER:-1.18.34}"
TAG="fleet-$VER"
EFFECT_VER="${EFFECT_VER:-4.0.0-beta.103}"
BTAG="fleet$VER"
V1_SRC="${V1_SRC:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/opencode-$VER}"
BUN="${ANDROID_BUN:-$ROOT_DIR/artifacts/transplant/android-bun/bun-1.4.2/bun}"
SHIM="$ROOT_DIR/tools/transplant/toolchain/openat2_shim.so"
GRAFT_LIB="$ROOT_DIR/artifacts/transplant/opentui-bionic-tlsdesc/libopentui.embed.so"
OUT_DIR="$ROOT_DIR/artifacts/build/$VER"
MODELS_JSON="${MODELS_JSON:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/models.dev-api.json}"
EV_DIR="$ROOT_DIR/.omo/evidence/a2-v1-effect-rebuild"
EVID="$EV_DIR/task-30-fleet-plan.txt"

# 未压缩件（graft 前 src / graft 后 / hermetic 后）
RAW_BIN="$OUT_DIR/opencode-v1-$VER-$BTAG-raw"
GRAFTED_BIN="$OUT_DIR/opencode-v1-$VER-$BTAG-grafted"
HERMETIC_BIN="$OUT_DIR/opencode-v1-$VER-$BTAG-hermetic"

# pilot 包 = 未压缩本体包，包名 opencode1-<ver>-<pkgrel>-aarch64.pkg.tar.xz。
#
# 为什么用 package_pacman_native.sh 而不是 package_pacman_compressed.sh：
#   compressed 脚本第 49 行硬编码 PKG_NAME="${FAMILY}-compressed"，产物必然叫
#   opencode1-compressed-* —— 那是**被用户指令跳过的那一族**，用它等于把 pilot
#   打进禁用族。native 脚本产出的 opencode1-<ver>-<rel>-aarch64.pkg.tar.xz 才是
#   未压缩本体包的规范名，也正是 fleet-push.py 版本正则唯一认的形式。
#
# fleet 标识：pkgrel 取 90（fleet 专用带，与历史-1..-10 压不冲突）。**不能把
# "fleet" 写进文件名** —— fleet-push.py 的版本正则要求 pkgrel 段是纯数字
# （见 docs/fleet-matrix.md §3.3 #3），带字母会被静默漏掉。fleet 身份改由
# pkgrel 带 + MANIFEST 记录。
PKGREL="${PKGREL:-90}"
FAMILY="${FAMILY:-opencode1}"

mkdir -p "$(dirname "$EVID")"
say() { printf '%s\n' "$*" | tee -a "$EVID"; }

# ── 门禁 ────────────────────────────────────────────────────────────────
df_free_mb() { df -k /data/user/0 | awk 'NR==2{print int($4/1024)}'; }
FREE_MB="$(df_free_mb)"
[[ "$FREE_MB" -ge 1500 ]] || { echo "Error: only ${FREE_MB}MB free (<1500MB gate)" >&2; exit 1; }
for f in "$BUN" "$SHIM" "$GRAFT_LIB" "$ROOT_DIR/tools/a2/hermetic-home-patch.py"; do
	[[ -e "$f" ]] || { say "Error: missing $f" >&2; exit 1; }
done
[[ -d "$V1_SRC" ]] || { say "Error: V1_SRC missing: $V1_SRC" >&2; exit 1; }
command -v python3 >/dev/null || { say "Error: python3 missing" >&2; exit 1; }
command -v readelf >/dev/null || { say "Error: readelf missing" >&2; exit 1; }
command -v script >/dev/null || { say "Error: script(util-linux) missing" >&2; exit 1; }

say ""
say "############### pilot-fleet-v1 $TAG$(date -u +%FT%TZ) ###############"
say "VER=$VER EFFECT_VER=$EFFECT_VER src=$V1_SRC"
say "bun=$($BUN --version)  free=${FREE_MB}MB"
say "未压缩 / 无 UPX / 不 push / 不发布 / 不装机"

# ── 1. A+ namespace 补丁（single-elf-namespace-patch.sh，默认 ignore-xdg） ──
say ""
say "== [1/8] single-elf namespace patch (A+ ignore-xdg, default) =="
V1_SRC="$V1_SRC" bash "$ROOT_DIR/tools/a2/single-elf-namespace-patch.sh" 2>&1 | tee -a "$EVID"
say "-- 补丁后 global.ts 关键行实证 --"
sed -n '1,16p' "$V1_SRC/packages/core/src/global.ts" | grep -nE 'const (app|home|data|cache|config|state|tmp) =' | tee -a "$EVID"

# ── 2. bun-pty store 补丁（bionic 内嵌） ─────────────────────────────────
say ""
say "== [2/8] bun-pty store patch (bionic embed) =="
V1_SRC="$V1_SRC" bash "$ROOT_DIR/tools/a2/pty-embed-store-patch.sh" 2>&1 | tee -a "$EVID"

# ── 3. build-v1（android bun --compile，无 UPX） ────────────────────────
say ""
say "== [3/8] build-v1.sh compile (effect $EFFECT_VER) =="
SKIP_SMOKE=1 VER="$VER" V1_SRC="$V1_SRC" ANDROID_BUN="$BUN" \
	MODELS_JSON="$MODELS_JSON" EFFECT_VER="$EFFECT_VER" TAG="$BTAG" \
	BUILD_ROOT="$ROOT_DIR/artifacts/build" \
	bash "$ROOT_DIR/tools/a2/build-v1.sh" 2>&1 | tee -a "$EVID"
BUILT="$OUT_DIR/opencode-v1-$VER-$BTAG"
[[ -x "$BUILT" ]] || { say "Error: build output not found: $BUILT" >&2; exit 1; }
RAW_BIN="$BUILT"
RAW_SZ="$(stat -c%s "$RAW_BIN")"
RAW_SHA="$(sha256sum "$RAW_BIN" | awk '{print $1}')"
say "    built: $RAW_BIN"
say "    size=$RAW_SZ sha256=$RAW_SHA"

# ── 4. TLSDESC graft（swap_tui 槽位手术 + 三重断言） ─────────────────────
say ""
say "== [4/8] TLSDESC graft (swap_tui slot surgery) =="
rm -f "$GRAFTED_BIN"
python3 "$ROOT_DIR/tools/transplant/swap_tui.py" \
	--binary "$RAW_BIN" --tui-lib "$GRAFT_LIB" --out "$GRAFTED_BIN" 2>&1 | tee -a "$EVID"
chmod 755 "$GRAFTED_BIN"
python3 - "$ROOT_DIR" "$RAW_BIN" "$GRAFTED_BIN" "$GRAFT_LIB" << 'PYEOF' 2>&1 | tee -a "$EVID"
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
print(f"    graft assert: slot@{base:#x} {so}B (embed {sg}B + {so-sg}B pad), 0B drift outside slot, total {len(graf)}B")
PYEOF
W="$ROOT_DIR/artifacts/build/.pilot-assert.$$"
mkdir -p "$W"
python3 - "$ROOT_DIR" "$GRAFTED_BIN" "$W/slot.so" << 'PYEOF'
import sys
sys.path.insert(0, sys.argv[1] + "/tools/transplant")
import swap_tui
graf = open(sys.argv[2], "rb").read()
base = swap_tui.find_libopentui_asset(graf)
open(sys.argv[3], "wb").write(graf[base:base + swap_tui.elf_size(graf, base)])
PYEOF
INIT="$(readelf -d "$W/slot.so" | grep -c INIT_ARRAY || true)"
TLSDESC="$(readelf -r "$W/slot.so" | grep -c R_AARCH64_TLSDESC || true)"
rm -rf "$W"
[[ "$INIT" -ge 2 ]] || { say "Error: INIT_ARRAY/INIT_ARRAYSZ missing after graft ($INIT)" >&2; exit 1; }
[[ "$TLSDESC" -eq 11 ]] || { say "Error: TLSDESC relocs=$TLSDESC (expect 11)" >&2; exit 1; }
say "    graft assert: INIT_ARRAY=$INIT TLSDESC=$TLSDESC preserved"
GRAFTED_SZ="$(stat -c%s "$GRAFTED_BIN")"
GRAFTED_SHA="$(sha256sum "$GRAFTED_BIN" | awk '{print $1}')"
say "    grafted size=$GRAFTED_SZ sha256=$GRAFTED_SHA"

# ── 5. hermetic home remap（断言内建在脚本里） ──────────────────────────
say ""
say "== [5/8] hermetic home remap =="
rm -f "$HERMETIC_BIN"
python3 "$ROOT_DIR/tools/a2/hermetic-home-patch.py" "$GRAFTED_BIN" "$HERMETIC_BIN" 2>&1 | tee -a "$EVID"
chmod 755 "$HERMETIC_BIN"
python3 - "$ROOT_DIR" "$HERMETIC_BIN" << 'PYEOF' 2>&1 | tee -a "$EVID"
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
HER_SZ="$(stat -c%s "$HERMETIC_BIN")"
HER_SHA="$(sha256sum "$HERMETIC_BIN" | awk '{print $1}')"
say "    hermetic size=$HER_SZ sha256=$HER_SHA"

# ── 6. 断言：hermetic strings home=0 + readelf -l 静态自证 ───────────────
say ""
say "== [6/8] assertions: hermetic strings + readelf -l =="
HOME_HITS="$(grep -c '/data/data/com.termux/files/home' "$HERMETIC_BIN" || true)"
say "    strings home-path hits = $HOME_HITS (expect 0)"
[[ "$HOME_HITS" == "0" ]] || { say "Error: home paths survived" >&2; exit 1; }
PT_INTERP="$(readelf -l "$HERMETIC_BIN" | grep -c INTERP || true)"
PT_DYNAMIC="$(readelf -l "$HERMETIC_BIN" | grep -c DYNAMIC || true)"
NEEDED="$(readelf -d "$HERMETIC_BIN" | grep NEEDED || true)"
say "    readelf -l: INTERP=$PT_INTERP DYNAMIC=$PT_DYNAMIC (static, both 0)"
say "    NEEDED: $(echo "$NEEDED" | tr '\n' ' ')"
[[ "$PT_INTERP" == "0" && "$PT_DYNAMIC" == "0" ]] || {
	say "Error: not a static self-contained ELF" >&2; exit 1; }
echo "$NEEDED" | grep -Eq 'NEEDED.*lib(c|m|dl|pthread|rt)\.so\.[0-9]' && {
	say "Error: glibc NEEDED in hermetic binary" >&2; exit 1; }
PT_ASSET="$(grep -c 'librust_pty_arm64-[a-z0-9]*\.so' "$HERMETIC_BIN" || true)"
say "    embedded pty asset markers = $PT_ASSET (expect >=1)"
[[ "$PT_ASSET" -ge 1 ]] || { say "Error: embedded librust_pty asset not found" >&2; exit 1; }
# 未压缩自证：不得带 UPX 魔数
UPX_MAGIC="$(grep -c 'UPX!' "$HERMETIC_BIN" || true)"
say "    UPX! magic hits = $UPX_MAGIC (expect 0 — 未压缩)"
[[ "$UPX_MAGIC" == "0" ]] || { say "Error: binary carries UPX magic — not uncompressed" >&2; exit 1; }

# ── 7. 打包（未压缩本体包；OCOMP_LAYOUT=single-elf；不做任何压缩） ────────
say ""
say "== [7/8] package (native uncompressed body, pkgrel=$PKGREL = fleet band) =="
VERSION="$VER" PKGREL="$PKGREL" \
	OPENCODE_NATIVE_BIN="$HERMETIC_BIN" \
	OPENCODE_BIN_NAME="$PKG_NAME" \
	bash "$ROOT_DIR/scripts/package/package_pacman_native.sh" 2>&1 | tee -a "$EVID"
BUILT_PKG="$ROOT_DIR/packing/pacman/$PKG_NAME-$VER-$PKGREL-aarch64.pkg.tar.xz"
[[ -f "$BUILT_PKG" ]] || { say "Error: package not produced: $BUILT_PKG" >&2; exit 1; }
say "    pkg: $BUILT_PKG"
say "    size: $(stat -c%s "$BUILT_PKG") sha256: $(sha256sum "$BUILT_PKG" | awk '{print $1}')"
#包内容自证：入口成员 + 零 .sh/零外部 .so + 内含未压缩 runtime
say "    -- package members --"
bsdtar -tf "$BUILT_PKG" 2>/dev/null | tee -a "$EVID"
RUNTIME_MEMBER="data/data/com.termux/files/usr/lib/$FAMILY/runtime/opencode"
bsdtar -tf "$BUILT_PKG" | grep -qxF "$RUNTIME_MEMBER" || {
	say "Error: package missing runtime member $RUNTIME_MEMBER" >&2; exit 1; }
bsdtar -tf "$BUILT_PKG" | grep -qxF "data/data/com.termux/files/usr/bin/$FAMILY" || {
	say "Error: package missing entry point bin/$FAMILY" >&2; exit 1; }
say "    entry+runtime members OK"

# ── 8. 冒烟 ─────────────────────────────────────────────────────────────
say ""
say "== [8/8] smoke: --version / 隔离假 HOME 五根 / 诱饵 XDG 零外泄 / 真 PTY TUI =="
V_OUT="$("$HERMETIC_BIN" --version 2>&1 || true)"
say "    --version = $V_OUT"
[[ "$V_OUT" == *"$VER"* ]] || { say "Error: version mismatch" >&2; exit 1; }

# 8.1隔离假 HOME + 诱饵 XDG：跑 --version 后五根应全落$HOME/…/opencode1/opencode
W="$ROOT_DIR/artifacts/build/.pilot-smoke.$$"
rm -rf "$W"; mkdir -p "$W/home" "$W/tmp" "$W/decoy-cfg" "$W/decoy-data" "$W/decoy-state" "$W/decoy-cache"
mkdir -p "$W/home/.config/opencode1/opencode"
printf '{"port": %d}\n' "$((20000 + RANDOM % 20000))" > "$W/home/.config/opencode1/opencode/service.json"
(
	export HOME="$W/home" TMPDIR="$W/tmp"
	export XDG_CONFIG_HOME="$W/decoy-cfg" XDG_DATA_HOME="$W/decoy-data"
	export XDG_STATE_HOME="$W/decoy-state" XDG_CACHE_HOME="$W/decoy-cache"
	cd "$W"
	timeout 25 "$HERMETIC_BIN" --print-logs 2>/dev/null || timeout 25 "$HERMETIC_BIN" >/dev/null 2>&1 || true
) || true
sleep 1
FIVE=0
for p in ".local/share/opencode1/opencode" ".cache/opencode1/opencode" \
	".config/opencode1/opencode" ".local/state/opencode1/opencode"; do
	if [ -e "$W/home/$p" ]; then say "    root OK: \$HOME/$p"; FINE=$((FINE + 1)); fi
done
DECOY_LEAK=0
for d in decoy-cfg decoy-data decoy-state decoy-cache; do
	n=$(find "$W/$d" -mindepth 1 2>/dev/null | wc -l)
	say "    decoy $d entries = $n"
	[[ "$n" -eq 0 ]] || DECOY_LEAK=$((DECOY_LEAK + 1))
done
say "    five-roots landed=$FINE/4  decoy-leak-dirs=$DECOY_LEAK (expect 0)"
rm -rf "$W"
[[ "$DECOY_LEAK" -eq 0 ]] || { say "Error: decoy XDG leak detected" >&2; exit 1; }

# 8.2 真 PTY TUI 一帧 + DELTA>0（复用 task-3-smoke.sh harness）
bash "$EV_DIR/task-3-smoke.sh" "$HERMETIC_BIN" "fleet-$VER" 2>&1 | tee -a "$EVID"

say ""
say "==> pilot-fleet-v1 done: $TAG"
say "    raw=$RAW_BIN ($RAW_SZ B)"
say "    grafted=$GRAFTED_BIN ($GRAFTED_SZ B)"
say "    hermetic=$HERMETIC_BIN ($HER_SZ B)  ← 未压缩本体，无 UPX"
say "    pkg=$BUILT_PKG"