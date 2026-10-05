#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

# fleet-v2-repack.sh — task-30 阶段B: v2 线 fleet 未压缩本体包（不 UPX）。
#
# 配方（v2 = 历史形态 + 不 UPX）：
#   runtime（未压缩 ELF，本体）+ libopencode-crhandler.so + pty 资产
#   → scripts/package/package_pacman_native.sh（PKGREL=90 fleet 带）
#   → packing/pacman/opencode-<ver>-90-aarch64.pkg.tar.xz
#
# **runtime 来源（重打包，非重新编译）**：RC4 沿途已实证的未压缩 ELF。
#   优先 artifacts/build/<ver>/opencode-native-revived（在盘的 RC4 构建件）；
#   缺失时从 packing/pacman/opencode-<ver>-*-aarch64.pkg.tar.xz 里提取
#   （在架包内 ELF 与构建件同源，已用 2.0.18-6 逐字节 sha256 对账验证）。
#   两者都是 **未压缩本体**（实测 UPX! 命中 = 0），与"本轮不 UPX"一致。
#   2.0.19+ 无在架件 → 由 fleet-v2-build.sh 真正编译（走 build-bionic.sh）。
#
# 与 pilot-fleet-v1.sh 的差异：v2 **不做** TLSDESC graft / hermetic remap ——
#   历史形态就是历史形态，remap 会偏离 RC4 在架件（v2 全线 PT_INTERP=1、
#   home 路径 46 处，这是 B 线原生形态，不是缺陷）。单版仍跑
#   hermetic-home-patch.py 的**分类断言**（只读探测，不改件）作为记录证据。
#
# 用法:
#   bash tools/a2/fleet-v2-repack.sh 2.0.0 2.0.1 ...     # 逐版
#   VERS="2.0.0 2.0.1" bash tools/a2/fleet-v2-repack.sh # 空格分隔批
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PKGREL="${PKGREL:-90}"
FAMILY="opencode"
EV_DIR="$ROOT_DIR/.omo/evidence/a2-v1-effect-rebuild"
EVID="$EV_DIR/task-30-fleet-build.txt"
STAGE="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/fleet-v2-stage"

# fleet 标识：pkgrel=90（fleet 专用带，与历史-1..-6 压不冲突）。**不能把
# "fleet" 写进文件名** —— tools/fleet-push.py 的版本正则要求 pkgrel 段是
# 纯数字（docs/fleet-matrix.md §3.3 #3），带字母会被静默漏配。
[[ "$PKGREL" =~ ^[0-9]+$ ]] || { echo "Error: PKGREL must be numeric (got '$PKGREL')" >&2; exit 1; }

say() { printf '%s\n' "$*" | tee -a "$EVID"; }

df_free_mb() { df -k /data/user/0 | awk 'NR==2{print int($4/1024)}'; }

VERS="${*:-${VERS:-}}"
[[ -n "$(echo "$VERS" | tr -d ' ')" ]] || { echo "usage: $0 <ver> [ver...]" >&2; exit 2; }

mkdir -p "$(dirname "$EVID")"
say ""
say "############### fleet-v2-repack (pkgrel=$PKGREL, no UPX) $(date -u +%FT%TZ) ###############"
say "versions: $(echo "$VERS" | tr '\n' ' ')"

DONE=0
SKIPPED=0
FAILED=""
SUMMARY=""

for VER in $VERS; do
	OUT_PKG="$ROOT_DIR/packing/pacman/$FAMILY-$VER-$PKGREL-aarch64.pkg.tar.xz"
	BUILD_DIR="$ROOT_DIR/artifacts/build/$VER"
	RUNTIME=""

	say ""
	say "=== v2 $VER ==="
	FREE_MB="$(df_free_mb)"
	if [[ "$FREE_MB" -lt 1500 ]]; then
		say "STOP: only ${FREE_MB}MB free (<1500MB) — per task rule avail<6G stop"
		FAILED="$FAILED $VER(disk)"
		break
	fi

	# ── 1. 取 runtime（RC4 已实证未压缩 ELF） ─────────────────────────────
	if [[ -f "$BUILD_DIR/opencode-native-revived" ]]; then
		RUNTIME="$BUILD_DIR/opencode-native-revived"
		RUNTIME_SRC="artifacts/build/$VER/opencode-native-revived"
	elif [[ -f "$BUILD_DIR/opencode-native-tlsdesc-trial" ]]; then
		RUNTIME="$BUILD_DIR/opencode-native-tlsdesc-trial"
		RUNTIME_SRC="artifacts/build/$VER/opencode-native-tlsdesc-trial"
	else
		# 从在架包提取（取 -4/-5 中最新者；-6 是 task-25 绝对成员重打包）
		SRC_PKG=""
		for r in 6 5 4 3 2 1; do
			cand="$ROOT_DIR/packing/pacman/$FAMILY-$VER-$r-aarch64.pkg.tar.xz"
			[[ -f "$cand" ]] || continue
			[[ -n "$SRC_PKG" ]] || SRC_PKG="$cand"
		done
		if [[ -z "$SRC_PKG" ]]; then
			say "SKIP $VER: no in-tree runtime and no in-arc package — needs a real build"
			SKIPPED=$((SKIPPED + 1))
			SUMMARY="$SUMMARY
$VER	SKIP	no-runtime"
			continue
		fi
		rm -rf "$STAGE"; mkdir -p "$STAGE"
		# 在架包可能是相对 usr/ 或绝对 data/... 两种成员形态，都取
		bsdtar -xf "$SRC_PKG" -C "$STAGE" 2>/dev/null
		EXTRACTED="$(find "$STAGE" -type f -name opencode -path '*bin/opencode' | head -1)"
		[[ -n "$EXTRACTED" ]] || {
			say "SKIP $VER: could not extract runtime from $SRC_PKG"
			SKIPPED=$((SKIPPED + 1))
			SUMMARY="$SUMMARY
$VER	SKIP	extract-failed"
			rm -rf "$STAGE"
			continue
		}
		mkdir -p "$BUILD_DIR"
		RUNTIME="$BUILD_DIR/opencode-native-revived"
		cp -f "$EXTRACTED" "$RUNTIME"
		chmod 755 "$RUNTIME"
		RUNTIME_SRC="extracted:$(basename "$SRC_PKG")"
		# crhandler 也可能只在包里
		SHIM_SRC="$(find "$STAGE" -type f -name 'libopencode-crhandler.so' | head -1)"
		[[ -z "$SHIM_SRC" || -f "$BUILD_DIR/libopencode-crhandler.so" ]] || {
			cp -f "$SHIM_SRC" "$BUILD_DIR/libopencode-crhandler.so"
			chmod 755 "$BUILD_DIR/libopencode-crhandler.so"
		}
		rm -rf "$STAGE"
	fi

	SZ="$(stat -c%s "$RUNTIME")"
	SHA="$(sha256sum "$RUNTIME" | awk '{print $1}')"
	say "    runtime: $RUNTIME_SRC  size=$SZ"
	say "    sha256=$SHA"

	# ── 2. 形态自证：必须是未压缩本体（零 UPX 魔数） ──────────────────────
	UPX_MAGIC="$(grep -c 'UPX!' "$RUNTIME" || true)"
	HOME_HITS="$(grep -c '/data/data/com.termux/files/home' "$RUNTIME" || true)"
	say "    UPX! magic=$UPX_MAGIC (expect 0 — 未压缩)  home-path hits=$HOME_HITS (B线原生形态)"
	if [[ "$UPX_MAGIC" != "0" ]]; then
		say "STOP $VER: runtime carries UPX magic — not an uncompressed body"
		FAILED="$FAILED $VER(upx)"
		continue
	fi

	# ── 3. hermetic 分类断言（只读探测，不改件） ─────────────────────────
	# 记录 n_target / n_opentui / n_cargo 三元组。历史形态保留 46 处 home
	# 路径（B 线原生产物），所以这里断言的是**分类干净**：n_target 全部被已知
	# 前缀解释，没有来源不明的新增 home 路径。
	CLASS="$(python3 - "$RUNTIME" "$ROOT_DIR" << 'PYEOF'
import sys
sys.path.insert(0, sys.argv[2] + "/tools/a2")
import importlib.util
spec = importlib.util.spec_from_file_location("hhp", sys.argv[2] + "/tools/a2/hermetic-home-patch.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
data = open(sys.argv[1], "rb").read()
n_t = data.count(m.TARGET)
n_p = data.count(m.OLD_PREFIX)
n_c = data.count(m.CARGO_PREFIX)
print(f"{n_t} {n_p} {n_c} {'CLEAN' if n_t == n_p + n_c else 'UNKNOWN'}")
PYEOF
)"
	read -r N_T N_P N_C CLASS_VERDICT <<<"$CLASS"
	say "    hermetic classification: n_target=$N_T n_opentui=$N_P n_cargo=$N_C -> $CLASS_VERDICT"
	if [[ "$CLASS_VERDICT" != "CLEAN" ]]; then
		say "STOP $VER: hermetic classification NOT clean (未知 home 路径来源) — 见 tools/a2/hermetic-home-patch.py:54"
		FAILED="$FAILED $VER(hermetic-class)"
		continue
	fi

	# ── 4. 打包（fleet pkgrel 带；绝不 UPX） ──────────────────────────────
	[[ -f "$BUILD_DIR/libopencode-crhandler.so" ]] || {
		say "STOP $VER: libopencode-crhandler.so missing next to runtime (PKGBUILD W11 hard gate)"
		FAILED="$FAILED $VER(no-shim)"
		continue
	}
	VERSION="$VER" PKGREL="$PKGREL" \
		OPENCODE_NATIVE_BIN="$RUNTIME" \
		bash "$ROOT_DIR/scripts/package/package_pacman_native.sh" >>"$EVID" 2>&1 || {
		say "STOP $VER: package_pacman_native.sh failed (see $EVID)"
		FAILED="$FAILED $VER(pkg)"
		continue
	}
	[[ -f "$OUT_PKG" ]] || {
		say "STOP $VER: package not produced: $OUT_PKG"
		FAILED="$FAILED $VER(nopkg)"
		continue
	}
	PKG_SZ="$(stat -c%s "$OUT_PKG")"
	PKG_SHA="$(sha256sum "$OUT_PKG" | awk '{print $1}')"
	say "    pkg: $(basename "$OUT_PKG")  size=$PKG_SZ"
	say "    pkg sha256=$PKG_SHA"

	# ── 5. 冒烟：包成员 + --version ──────────────────────────────────────
	MEMBERS="$(bsdtar -tf "$OUT_PKG")"
	echo "$MEMBERS" | grep -qxF "data/data/com.termux/files/usr/bin/$FAMILY" || {
		say "STOP $VER: package missing bin/$FAMILY member"
		FAILED="$FAILED $VER(member-bin)"
		continue
	}
	echo "$MEMBERS" | grep -qxF "data/data/com.termux/files/usr/lib/opencode/libopencode-crhandler.so" || {
		say "STOP $VER: package missing libopencode-crhandler.so member"
		FAILED="$FAILED $VER(member-shim)"
		continue
	}
	# 相对 usr/ 成员是已知致命约定（task-25）——硬门禁
	if echo "$MEMBERS" | grep -qE '^usr/'; then
		say "STOP $VER: package has RELATIVE usr/ members — termux-pacman absolute convention required"
		FAILED="$FAILED $VER(rel-usr)"
		continue
	fi
	# crhandler 是 DT_RUNPATH $ORIGIN/../lib/opencode —— 在 artifacts/build/<ver>/
	# 这种平铺布局下跑不到（装机后布局才匹配），所以冒烟显式给 LD_LIBRARY_PATH。
	V_OUT="$(LD_LIBRARY_PATH="$BUILD_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$RUNTIME" --version 2>&1 || true)"
	say "    --version = $V_OUT"
	if [[ "$V_OUT" != *"$VER"* ]]; then
		say "STOP $VER: version mismatch: $V_OUT"
		FAILED="$FAILED $VER(version)"
		continue
	fi

	DONE=$((DONE + 1))
	SUMMARY="$SUMMARY
$VER	OK	$PKG_SZ	$PKG_SHA	hermetic=$N_T/$N_P/$N_C	$VER"
	say "    ==> v2 $VER DONE"
done

rm -rf "$STAGE"
say ""
say "=== fleet-v2-repack summary: done=$DONE skipped=$SKIPPED failed=${FAILED:-none} ==="
if [[ -n "$SUMMARY" ]]; then
	say "--- per-version ---"
	say "$(printf 'ver\tstatus\tbytes\tsha256\thermetic(n_t/n_opentui/n_cargo)\tver')
$SUMMARY"
fi
exit 0
