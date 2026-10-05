#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

# fleet-v2-build.sh — task-30: v2 线上游新增版本的真编译（不 UPX）。
#
# 与 fleet-v2-repack.sh 的分工：
#   repack  2.0.0–2.0.18  RC4 沿途已实证件重打包（盘上有 runtime，直接用）
#   build   2.0.19–2.0.22  上游新增，盘上无件 → 必须真编译
#
# 配方 = v2 历史形态 + 不 UPX：
#   单份 clone 逐版 git checkout <tag> → scripts/build-bionic.sh
#   （bun 1.4.0 pin、PTY_VARIANT=musl、bionic libopentui 部署 + DT_NEEDED 门禁、
#     web-ui dist、target=opencode-linux-arm64）
#   → TLSDESC graft → hermetic-home-patch（分类断言内建）
#   → 形态自证（零 UPX 魔数 / 零 glibc NEEDED）
#   → package_pacman_native.sh（pkgrel=90 fleet 带）
#   → 冒烟（--version / TUI，判据见 tools/a2/fleet-v2-tui-smoke.sh 文件头：
#     v2 是全屏原地重绘，**不能**用 v1 的「键入字节增长」当活性判据 —— 对照
#     实测 RC4 已实证的 2.0.18 在同一 harness 下同样 DELTA=0）
#
# 与 v1 的差异（为什么 v2 不做 A+ namespace bake）：
#   single-elf-namespace-patch.sh bake 的是 `opencode1` 命名空间，是 v1 线专用；
#   v2 必须保持 plain `opencode/` 根（两代数据不通，v2 是主流主线）。阶段 A
#   §2.4 已判定 v2 该补丁「不适用」。graft + hermetic 则两条线同构，都要做。
#
# 用法: bash tools/a2/fleet-v2-build.sh 2.0.19 [2.0.20 ...]
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PKGREL="${PKGREL:-90}"
FAMILY="opencode"
FLEET_SRC="${FLEET_SRC:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/opencode-fleet}"
BUN="${ANDROID_BUN:-$ROOT_DIR/artifacts/transplant/android-bun/bun-1.4.0/bun}"
GRAFT_LIB="$ROOT_DIR/artifacts/transplant/opentui-bionic-tlsdesc/libopentui.embed.so"
EV_DIR="$ROOT_DIR/.omo/evidence/a2-v1-effect-rebuild"
EVID="$EV_DIR/task-30-fleet-build.txt"
MANIFEST="$EV_DIR/task-30-fleet-manifest.tsv"
# 磁盘门：单版真编译峰值（源树 2.7G + store 2.4G + 各阶段 ELF 4×290M）≈ 7G。
# 低于 MIN_FREE_MB 直接停手 —— 宁可少几版，也不能把盘填到影响用户。
MIN_FREE_MB="${MIN_FREE_MB:-7200}"

VERS="${*:-${VERS:-}}"
[[ -n "$(echo "$VERS" | tr -d ' ')" ]] || { echo "usage: $0 <ver> [ver...]" >&2; exit 2; }
[[ "$PKGREL" =~ ^[0-9]+$ ]] || { echo "Error: PKGREL must be numeric" >&2; exit 1; }

say() { printf '%s\n' "$*" | tee -a "$EVID"; }
df_free_mb() { df -k /data/user/0 | awk 'NR==2{print int($4/1024)}'; }

mkdir -p "$(dirname "$EVID")"
say ""
say "############### fleet-v2-build (pkgrel=$PKGREL, no UPX) $(date -u +%FT%TZ) ###############"
say "versions: $(echo "$VERS" | tr '\n' ' ')  free=$(df_free_mb)MB (min ${MIN_FREE_MB}MB)"

for f in "$BUN" "$GRAFT_LIB" "$ROOT_DIR/tools/a2/hermetic-home-patch.py" \
	"$ROOT_DIR/tools/transplant/swap_tui.py" "$EV_DIR/task-3-smoke.sh" \
	"$ROOT_DIR/artifacts/transplant/opentui-bionic/libopentui.so"; do
	[[ -e "$f" ]] || { say "FATAL missing $f" >&2; exit 1; }
done
command -v python3 >/dev/null || { say "FATAL python3 missing" >&2; exit 1; }
command -v readelf >/dev/null || { say "FATAL readelf missing" >&2; exit 1; }
command -v script >/dev/null || { say "FATAL script(util-linux) missing" >&2; exit 1; }

DONE=0
FAILED=""
SUMMARY=""

for VER in $VERS; do
	TAG="v$VER"
	OUT_DIR="$ROOT_DIR/artifacts/build/$VER"
	REVIVED="$OUT_DIR/opencode-native-revived"
	GRAFTED="$OUT_DIR/opencode-native-fleet-grafted"
	HERMETIC="$OUT_DIR/opencode-native-fleet-hermetic"
	OUT_PKG="$ROOT_DIR/packing/pacman/$FAMILY-$VER-$PKGREL-aarch64.pkg.tar.xz"

	say ""
	say "############ v2 $VER ($TAG) 真编译 ############"
	FREE_MB="$(df_free_mb)"
	if [[ "$FREE_MB" -lt "$MIN_FREE_MB" ]]; then
		say "STOP: only ${FREE_MB}MB free (<${MIN_FREE_MB}MB gate) — 单版峰值需 ~7G"
		FAILED="$FAILED $VER(disk)"
		break
	fi

	# ── 0. 断线续接快路径：revived 件已在就直接复用，跳过 checkout+编译 ──
	# **只省编译，不省任何断言**：2b 的 crhandler 硬门、3 的 graft 零漂移、
	# 4 的 hermetic 分类、5 的形态自证、6 的打包门、7 的冒烟全都照跑。
	# 不这么做的话，一次断线就得重付 15 分钟编译，而 15 分钟里磁盘峰值 7G。
	if [[ "${RESUME:-1}" == "1" && -x "$REVIVED" ]]; then
		say "-- [0/7] RESUME: reusing $REVIVED (all assertions + smoke still run) --"
		RAW_SZ="$(stat -c%s "$REVIVED")"
		RAW_SHA="$(sha256sum "$REVIVED" | awk '{print $1}')"
		say "    revived: $RAW_SZ B  sha256=$RAW_SHA"
	else
		SKIP_BUILD=0
	fi

	if [[ "${SKIP_BUILD:-1}" -eq 0 ]]; then
	# ── 1. 逐版 checkout ───────────────────────────────────────────────
	say "-- [1/7] git checkout $TAG --"
	git -C "$FLEET_SRC" rev-parse "$TAG" >/dev/null 2>&1 || {
		say "STOP $VER: tag $TAG not in $FLEET_SRC"
		FAILED="$FAILED $VER(no-tag)"
		continue
	}
	git -C "$FLEET_SRC" checkout -f "$TAG" >>"$EVID" 2>&1 || {
		say "STOP $VER: git checkout $TAG failed"
		FAILED="$FAILED $VER(checkout)"
		continue
	}
	# `git reset --hard` 而不是 `reset -f`：后者不是合法选项组合（git 打印
	# 一整页 usage 灌进 evidence，看着像构建出错，实际无副作用）。
	git -C "$FLEET_SRC" reset --hard >>"$EVID" 2>&1
	git -C "$FLEET_SRC" clean -xdf -q 2>/dev/null
	say "    HEAD=$(git -C "$FLEET_SRC" rev-parse --short HEAD) free=$(df_free_mb)MB"
	[[ -f "$FLEET_SRC/packages/cli/script/build.ts" ]] || {
		say "STOP $VER: $TAG has no packages/cli/script/build.ts (not a v2 tag)"
		FAILED="$FAILED $VER(not-v2)"
		continue
	}

	# ── 2. build-bionic.sh（真编译） ───────────────────────────────────
	say "-- [2/7] build-bionic.sh (bun 1.4.0 pin, PTY_VARIANT=musl, no UPX) --"
	VER="$VER" V2_SRC="$FLEET_SRC" ANDROID_BUN="$BUN" \
		OPENCODE_VERSION="$VER" UPX=0 PTY_VARIANT=musl \
		BUILD_ROOT="$ROOT_DIR/artifacts/build" \
		bash "$ROOT_DIR/scripts/build-bionic.sh" 2>&1 | tee -a "$EVID" | \
		grep -E '^==>|^Error|^WARN|opentui|PTY|installing|deploy|web-ui|building|normalized|sha256|cleaning' | tail -40
	if [[ ! -x "$REVIVED" ]]; then
		say "STOP $VER: build-bionic.sh produced no runtime: $REVIVED"
		FAILED="$FAILED $VER(build)"
		continue
	fi
	RAW_SZ="$(stat -c%s "$REVIVED")"
	RAW_SHA="$(sha256sum "$REVIVED" | awk '{print $1}')"
	say "    revived: $RAW_SZ B  sha256=$RAW_SHA"
	fi # end SKIP_BUILD==0（编译链）

	# ── 2b. W11 seccomp harden（**v2 历史形态的组成件，两条路径都要跑**） ──
	# 实测教训：build-bionic.sh **不做** seccomp harden —— 那是 Makefile 的
	# `transplant` 目标在 build 之后单独跑的一步（Makefile:296-299 →
	# seccomp-harden）。漏掉的后果是静默的形态漂移：
	#   2.0.18（RC4 件）: grep -c libopencode-crhandler = 1，DT_NEEDED 带 shim，
	#     包里因此有 usr/lib/opencode/libopencode-crhandler.so
	#   2.0.19（漏 harden）: = 0 → PKGBUILD 的 W11 判据为假 → **包不带
	#     crhandler** → 与 2.0.0-2.0.18 的历史形态不一致，且 shim 机制
	#     （spawn-child fd 卫生）失效。包能打出来、--version 也过，只有把
	#     两代包并排比才看得出差别 —— 所以这里做成硬断言。
	#
	# **必须在 SKIP_BUILD 块之外**：RESUME 路径复用的 revived 件同样没被
	# harden 过，把这段放进编译链里会导致 RESUME 静默跳过它（实测踩到：
	# 第一次加这步时放在块内，RESUME 打出���包**仍然不带 crhandler**，
	# 而 driver 报了 DONE —— 又是一个「不报错但结果错」）。
	say "-- [2b/7] W11 seccomp harden (crhandler DT_NEEDED + shim) --"
	if ! command -v clang >/dev/null 2>&1; then
		say "STOP $VER: clang missing — cannot build libopencode-crhandler.so (v2 历史形态硬要求)"
		FAILED="$FAILED $VER(no-clang)"
		continue
	fi
	clang -shared -fPIC -O2 -o "$OUT_DIR/libopencode-crhandler.so" \
		"$ROOT_DIR/tools/shim/sigsys_handler.c" 2>&1 | tee -a "$EVID"
	[[ -s "$OUT_DIR/libopencode-crhandler.so" ]] || {
		say "STOP $VER: libopencode-crhandler.so build produced nothing"
		FAILED="$FAILED $VER(shim-build)"
		continue
	}
	if ! grep -aqF libopencode-crhandler.so "$REVIVED"; then
		cp -p "$REVIVED" "$REVIVED.pre-crhandler"
		if ! python3 "$ROOT_DIR/tools/transplant/crhandler_patch.py" "$REVIVED" 2>&1 | tee -a "$EVID"; then
			say "STOP $VER: crhandler_patch.py failed"
			FAILED="$FAILED $VER(crhandler-patch)"
			continue
		fi
	fi
	CR_N="$(grep -ac libopencode-crhandler "$REVIVED" || true)"
	say "    crhandler DT_NEEDED refs=$CR_N (expect >=1)  shim=$(stat -c%s "$OUT_DIR/libopencode-crhandler.so") B"
	[[ "$CR_N" -ge 1 ]] || {
		say "STOP $VER: runtime does not reference crhandler after harden — 形态与 v2 历史形态不符"
		FAILED="$FAILED $VER(no-crhandler)"
		continue
	}

	# 续接路径也要报一次尺寸（前面 RESUME 分支已报过，这里补 shim 后的真实值）
	RAW_SZ="$(stat -c%s "$REVIVED")"
	RAW_SHA="$(sha256sum "$REVIVED" | awk '{print $1}')"

	# ── 3. TLSDESC graft ──────────────────────────────────────────────
	say "-- [3/7] TLSDESC graft --"
	rm -f "$GRAFTED"
	if ! python3 "$ROOT_DIR/tools/transplant/swap_tui.py" \
		--binary "$REVIVED" --tui-lib "$GRAFT_LIB" --out "$GRAFTED" 2>&1 | tee -a "$EVID"; then
		say "STOP $VER: TLSDESC graft failed"
		FAILED="$FAILED $VER(graft)"
		continue
	fi
	chmod 755 "$GRAFTED"
	if ! python3 - "$ROOT_DIR" "$REVIVED" "$GRAFTED" "$GRAFT_LIB" 2>&1 << 'PYEOF' | tee -a "$EVID"
import sys
sys.path.insert(0, sys.argv[1] + "/tools/transplant")
import swap_tui
orig = open(sys.argv[2], "rb").read()
graf = open(sys.argv[3], "rb").read()
lib = open(sys.argv[4], "rb").read()
base = swap_tui.find_libopentui_asset(graf)
assert base >= 0, "grafted: libopentui asset not found"
so, sg = swap_tui.elf_size(orig, base), swap_tui.elf_size(graf, base)
assert len(orig) == len(graf), "total size drifted"
assert orig[:base] == graf[:base], "prefix drift"
assert orig[base + so:] == graf[base + so:], "suffix drift"
assert graf[base:base + sg] == lib, "slot content != graft lib"
assert sg <= so, "graft lib larger than slot"
print(f"    graft assert: slot@{base:#x} {so}B (embed {sg}B + {so-sg}B pad), 0B drift outside slot")
PYEOF
	then
		say "STOP $VER: graft byte assertion failed"
		FAILED="$FAILED $VER(graft-assert)"
		continue
	fi
	W="$ROOT_DIR/artifacts/build/.fleet-v2-assert.$$"
	rm -rf "$W"; mkdir -p "$W"
	python3 - "$ROOT_DIR" "$GRAFTED" "$W/slot.so" << 'PYEOF'
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
	say "    graft assert: INIT_ARRAY=$INIT (>=2)  TLSDESC=$TLSDESC (==11)"
	[[ "$INIT" -ge 2 && "$TLSDESC" -eq 11 ]] || {
		say "STOP $VER: post-graft readelf assert failed"
		FAILED="$FAILED $VER(graft-assert)"
		continue
	}

	# ── 4. hermetic remap（分类断言内建；不过即停） ───────────────────
	say "-- [4/7] hermetic home remap (classification gate) --"
	rm -f "$HERMETIC"
	if ! python3 "$ROOT_DIR/tools/a2/hermetic-home-patch.py" "$GRAFTED" "$HERMETIC" 2>&1 | tee -a "$EVID"; then
		say "STOP $VER: hermetic classification NOT clean — 见 hermetic-home-patch.py:54"
		FAILED="$FAILED $VER(hermetic-class)"
		continue
	fi
	chmod 755 "$HERMETIC"
	if ! python3 - "$ROOT_DIR" "$HERMETIC" 2>&1 << 'PYEOF' | tee -a "$EVID"
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
	then
		say "STOP $VER: post-remap assertion failed"
		FAILED="$FAILED $VER(hermetic-assert)"
		continue
	fi
	HER_SZ="$(stat -c%s "$HERMETIC")"
	HER_SHA="$(sha256sum "$HERMETIC" | awk '{print $1}')"

	# ── 5. 形态自证 ───────────────────────────────────────────────────
	say "-- [5/7] form self-proof (zero-UPX / zero-glibc) --"
	UPX_MAGIC="$(grep -c 'UPX!' "$HERMETIC" || true)"
	HOME_HITS="$(grep -c '/data/data/com.termux/files/home' "$HERMETIC" || true)"
	NEEDED="$(readelf -d "$HERMETIC" | grep NEEDED || true)"
	say "    home-path hits=$HOME_HITS (0)  UPX! magic=$UPX_MAGIC (0 — 未压缩)"
	say "    NEEDED: $(echo "$NEEDED" | tr '\n' ' ')"
	OK=1
	[[ "$UPX_MAGIC" == "0" ]] || { say "STOP $VER: UPX magic present"; OK=0; }
	[[ "$HOME_HITS" == "0" ]] || { say "STOP $VER: home paths survived"; OK=0; }
	if echo "$NEEDED" | grep -Eq 'NEEDED.*lib(c|m|dl|pthread|rt|util)\.so\.[0-9]'; then
		say "STOP $VER: glibc NEEDED in hermetic binary"
		OK=0
	else
		say "    zero-glibc gate: OK (no versioned soname)"
	fi
	[[ "$OK" -eq 1 ]] || { FAILED="$FAILED $VER(form)"; continue; }

	# crhandler shim 是 PKGBUILD 的 W11 硬门：binary 引用它就必须同包
	SHIM_SRC="$ROOT_DIR/tools/transplant/crhandler_patch.py"
	command -v true >/dev/null
	[[ -f "$OUT_DIR/libopencode-crhandler.so" ]] || say "    NOTE: no prebuilt crhandler shim; PKGBUILD will error if referenced"

	# ── 6. 打包（跨 driver flock 串行） ────────────────────────────────
	say "-- [6/7] package (pkgrel=$PKGREL) --"
	exec 9>"$ROOT_DIR/packing/pacman/.fleet-pkg.lock"
	if ! flock -w 1800 9; then
		say "STOP $VER: could not acquire packaging lock"
		FAILED="$FAILED $VER(pkg-lock)"
		continue
	fi
	VERSION="$VER" PKGREL="$PKGREL" OPENCODE_NATIVE_BIN="$HERMETIC" \
		bash "$ROOT_DIR/scripts/package/package_pacman_native.sh" >>"$EVID" 2>&1
	PKG_RC=$?
	flock -u 9
	exec 9>&-
	if [[ "$PKG_RC" -ne 0 ]]; then
		say "STOP $VER: package_pacman_native.sh failed (rc=$PKG_RC, see $EVID)"
		FAILED="$FAILED $VER(pkg)"
		continue
	fi
	[[ -f "$OUT_PKG" ]] || { say "STOP $VER: package not produced"; FAILED="$FAILED $VER(nopkg)"; continue; }
	MEMBERS="$(bsdtar -tf "$OUT_PKG")"
	echo "$MEMBERS" | grep -qxF "data/data/com.termux/files/usr/bin/$FAMILY" || {
		say "STOP $VER: missing bin/$FAMILY"; FAILED="$FAILED $VER(member-bin)"; continue; }
	# crhandler 成员断言：harden 过了 DT_NEEDED，PKGBUILD 就**必须**把 shim
	# 装进包（否则装机的 opencode 找不到 DT_NEEDED 的库 → 直接起不来）。
	# 反向也成立：harden 漏了的话这里不会少成员、只是 assert 提前在 2b 拦下。
	# 两个方向都断言，才能保证「包形态 == 历史形态」。
	echo "$MEMBERS" | grep -qxF "data/data/com.termux/files/usr/lib/opencode/libopencode-crhandler.so" || {
		say "STOP $VER: package missing libopencode-crhandler.so (harden 过了但 shim 没进包)"
		FAILED="$FAILED $VER(member-shim)"; continue; }
	if echo "$MEMBERS" | grep -qE '^usr/'; then
		say "STOP $VER: RELATIVE usr/ members — absolute convention required"
		FAILED="$FAILED $VER(rel-usr)"; continue
	fi
	PKG_SZ="$(stat -c%s "$OUT_PKG")"
	PKG_SHA="$(sha256sum "$OUT_PKG" | awk '{print $1}')"
	say "    pkg: $(basename "$OUT_PKG")  size=$PKG_SZ  sha256=$PKG_SHA"

	# ── 7. 冒烟 ───────────────────────────────────────────────────────
	say "-- [7/7] smoke (--version + TUI) --"
	V_OUT="$(LD_LIBRARY_PATH="$OUT_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$HERMETIC" --version 2>&1 || true)"
	say "    --version = $V_OUT"
	if [[ "$V_OUT" != *"$VER"* ]]; then
		say "STOP $VER: version mismatch"
		FAILED="$FAILED $VER(version)"
		continue
	fi
	SMOKE_OUT="$(bash "$ROOT_DIR/tools/a2/fleet-v2-tui-smoke.sh" "$HERMETIC" "fleet-$VER" "$OUT_DIR" 2>&1)"
	echo "$SMOKE_OUT" | tee -a "$EVID"
	if ! echo "$SMOKE_OUT" | grep -q 'verdict=GREEN'; then
		say "STOP $VER: TUI smoke not GREEN"
		FAILED="$FAILED $VER(tui)"
		continue
	fi

	DONE=$((DONE + 1))
	SUMMARY="$SUMMARY
$VER	OK	$PKG_SZ	$PKG_SHA	$HER_SZ	$HER_SHA	hermetic=CLEAN	tui=GREEN"
	printf '%s\tv2\tOK\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$VER" "$OUT_PKG" "$PKG_SZ" "$PKG_SHA" "$HER_SZ" "$HER_SHA" "hermetic=CLEAN" "tui=GREEN" \
		>>"$MANIFEST"
	say "    ==> v2 $VER DONE"
	# 逐版清中间件：源树由下一版 checkout 时 git clean -xdf 兜底，这里只清
	# 本版的 4 个 290MB 级 ELF（revived/grafted/hermetic + 临时），保留 hermetic
	# 直到包已打出并记录 sha。
	rm -f "$REVIVED" "$GRAFTED"
	say "    cleaned intermediates; free=$(df_free_mb)MB"
done

say ""
say "=== fleet-v2-build summary: done=$DONE failed=${FAILED:-none} ==="
if [[ -n "$SUMMARY" ]]; then
	say "$(printf 'ver\tstatus\tbytes\tsha256\telf_bytes\telf_sha256\thermetic\ttui')
$SUMMARY"
fi
exit 0
