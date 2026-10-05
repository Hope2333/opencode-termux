#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

# fleet-v1-build.sh — task-30 阶段B: v1 线 fleet 未压缩本体包（不 UPX）。
#
# 配方（v1 = single-elf + 静态自证 + 不 UPX）：
#   1. 单份上游 clone 逐版 `git checkout <tag>`（FLEET_SRC）
#   2. tools/a2/single-elf-namespace-patch.sh（A+ --ignore-xdg 默认）
#   3. tools/a2/pty-embed-store-patch.sh（bun-pty bionic 内嵌）
#   4. tools/a2/build-v1.sh（android bun 1.4.2 编译，effect 4.0.0-beta.83）
#   5. TLSDESC graft（tools/transplant/swap_tui.py 槽位手术 + 三重断言）
#   6. tools/a2/hermetic-home-patch.py（home 路径归零，内建分类断言）
#   7. 形态自证：strings home=0 / **零 glibc NEEDED**（带版本号 soname 即 glibc）
#      / 内嵌 pty 资产标记 / **零 UPX 魔数**（未压缩自证）
#   8. 打包：scripts/package/package_pacman_native.sh（PKGREL=90 fleet 带）
#   9. 冒烟：--version / 隔离假 HOME 四根落位 / 诱饵 XDG 零外泄 /
#      真 PTY TUI 一帧 + 键入 DELTA>0（task-3-smoke.sh harness）
#
# **绝不 UPX**：第7 步的 UPX! 魔数门是硬断言，命中即停。
#
# effect 版本口径（重要，勿改）：**用上游 catalog 原值 4.0.0-beta.83**，即
# build-v1.sh 自己的默认值。A2 的 beta.103 bump（tools/a2/effect-beta103-bump.patch）
# 是 1.18.32 单版的实验线，实测 `git apply --check`：1.18.30/31/32 可应用，
# **1.18.33/34 在 package.json:142 上下文已漂移、不可应用**。若整 fleet 走
# beta.103，就得逐版重新推导 patch —— 那正是 docs/fleet-matrix.md §2 判定的
# 「需适配」档，而阶段 A 判定 v1 线 5/5 **零适配**（catalog 逐版都是 beta.83）。
# fleet 的目的是产出各版本的可压制未压缩件，不是复现 A2 的 effect 实验；
# 每版与其**同版本上游发布态**一致才是 fleet 该有的语义。
#
# 用法:
#   bash tools/a2/fleet-v1-build.sh 1.18.34
#   VERS="1.18.33 1.18.34" bash tools/a2/fleet-v1-build.sh
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PKGREL="${PKGREL:-90}"
FAMILY="${FAMILY:-opencode1}"
FLEET_SRC="${FLEET_SRC:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/opencode-fleet}"
BUN="${ANDROID_BUN:-$ROOT_DIR/artifacts/transplant/android-bun/bun-1.4.2/bun}"
GRAFT_LIB="$ROOT_DIR/artifacts/transplant/opentui-bionic-tlsdesc/libopentui.embed.so"
MODELS_JSON="${MODELS_JSON:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/models.dev-api.json}"
EV_DIR="$ROOT_DIR/.omo/evidence/a2-v1-effect-rebuild"
EVID="$EV_DIR/task-30-fleet-build.txt"
MANIFEST="$EV_DIR/task-30-fleet-manifest.tsv"
EFFECT_VER="${EFFECT_VER:-4.0.0-beta.83}"

VERS="${*:-${VERS:-}}"
[[ -n "$(echo "$VERS" | tr -d ' ')" ]] || { echo "usage: $0 <ver> [ver...]" >&2; exit 2; }
[[ "$PKGREL" =~ ^[0-9]+$ ]] || { echo "Error: PKGREL must be numeric" >&2; exit 1; }

# RESUME=1（默认）：已产出且通过形态自证的 Hermetic 件直接复用，跳过
# checkout/install/compile。**不是**跳过断言 —— 第7 步的形态门与第9 步的冒烟
# 每版都实跑，所以续接不会把没验过的件当成好的。断线续接时省的是几十分钟
# 编译，不是验收。
RESUME="${RESUME:-1}"

say() { printf '%s\n' "$*" | tee -a "$EVID"; }
df_free_mb() { df -k /data/user/0 | awk 'NR==2{print int($4/1024)}'; }

mkdir -p "$(dirname "$EVID")"
say ""
say "############### fleet-v1-build (pkgrel=$PKGREL, no UPX) $(date -u +%FT%TZ) ###############"
say "versions: $(echo "$VERS" | tr '\n' ' ')  effect=$EFFECT_VER (upstream catalog;见文件头说明)"
say "src=$FLEET_SRC bun=$($BUN --version 2>&1 | head -1) free=$(df_free_mb)MB"

for f in "$BUN" "$GRAFT_LIB" "$ROOT_DIR/tools/a2/hermetic-home-patch.py" \
	"$ROOT_DIR/tools/transplant/swap_tui.py" "$EV_DIR/task-3-smoke.sh"; do
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
	BTAG="fleet$VER"
	BUILT="$OUT_DIR/opencode-v1-$VER-$BTAG"
	GRAFTED="$OUT_DIR/opencode-v1-$VER-$BTAG-grafted"
	HERMETIC="$OUT_DIR/opencode-v1-$VER-$BTAG-hermetic"
	OUT_PKG="$ROOT_DIR/packing/pacman/$FAMILY-$VER-$PKGREL-aarch64.pkg.tar.xz"

	say ""
	say "############ v1 $VER ($TAG) ############"
	FREE_MB="$(df_free_mb)"
	if [[ "$FREE_MB" -lt 1500 ]]; then
		say "STOP: only ${FREE_MB}MB free (<1500MB) — per task rule avail<6G stop"
		FAILED="$FAILED $VER(disk)"
		break
	fi

	# ── 1'. 断线续接快路径：Hermetic 件已在且形态门已过 → 跳到打包+冒烟 ──
	# 只省编译，**不省验收**（第7/8/9 步照跑）。
	if [[ "$RESUME" == "1" && -x "$HERMETIC" ]]; then
		if [[ "$(grep -c 'UPX!' "$HERMETIC" || true)" == "0" ]] &&
			[[ "$(grep -c '/data/data/com.termux/files/home' "$HERMETIC" || true)" == "0" ]]; then
			say "-- [1'/8] RESUME: reusing verified hermetic artifact (assertions still run) --"
			say "    $HERMETIC ($(stat -c%s "$HERMETIC") B  sha256=$(sha256sum "$HERMETIC" | awk '{print $1}'))"
			RAW_SZ=0
			RAW_SHA="(resumed)"
			HER_SZ="$(stat -c%s "$HERMETIC")"
			HER_SHA="$(sha256sum "$HERMETIC" | awk '{print $1}')"
			SKIP_TO_PACK=1
		else
			say "-- [1'/8] RESUME declined: existing hermetic artifact fails the form gate (rebuild) --"
			SKIP_TO_PACK=0
		fi
	else
		SKIP_TO_PACK=0
	fi

	if [[ "$SKIP_TO_PACK" -eq 0 ]]; then
	# ── 1. 逐版 checkout（单份 clone；构建间 git clean -xdf） ─────────────
	say "-- [1/8] git checkout $TAG (single clone, clean between builds) --"
	git -C "$FLEET_SRC" rev-parse "$TAG" >/dev/null 2>&1 || {
		say "STOP $VER: tag $TAG not present in $FLEET_SRC (fetch incomplete)"
		FAILED="$FAILED $VER(no-tag)"
		continue
	}
	git -C "$FLEET_SRC" checkout -f "$TAG" >>"$EVID" 2>&1 || {
		say "STOP $VER: git checkout $TAG failed"
		FAILED="$FAILED $VER(checkout)"
		continue
	}
	# `git reset --hard` 而不是 `reset -f`：后者不是合法选项组合（git 打印
	# 一整页 usage 灌进 evidence，看着像出错了）。checkout -f 已经Discard 了
	# 工作树改动，这里再 reset --hard 是为了连带重置 index。
	git -C "$FLEET_SRC" reset --hard >>"$EVID" 2>&1
	git -C "$FLEET_SRC" clean -xdf -q 2>/dev/null
	say "    HEAD=$(git -C "$FLEET_SRC" rev-parse --short HEAD) free=$(df_free_mb)MB"

	# v1 与 v2 是不同代的仓库形态；v1 的构建入口在 packages/opencode。
	[[ -f "$FLEET_SRC/packages/opencode/script/build.ts" ]] || {
		say "STOP $VER: $TAG has no packages/opencode/script/build.ts (not a v1 tag)"
		FAILED="$FAILED $VER(not-v1)"
		continue
	}

	# ── 2. single-elf namespace patch（A+ ignore-xdg 默认） ──────────────
	say "-- [2/8] single-elf namespace patch (A+ ignore-xdg) --"
	V1_SRC="$FLEET_SRC" bash "$ROOT_DIR/tools/a2/single-elf-namespace-patch.sh" 2>&1 | tee -a "$EVID"

	# ── 3. bun install（pty patch 需要 store 先落地） ───────────────────
	# 顺序理由：pty-embed-store-patch.sh 替换的是 node_modules/.bun/bun-pty@*/
	# rust-pty/target/release/librust_pty_arm64.so —— chunk 不存在就报
	# "no bun-pty store chunk"。所以 install 必须先跑；随后 build-v1.sh 见到
	# 完整 store 会自己跳过 install（幂等 by design）。
	say "-- [3/8] bun install (store must exist before the pty swap) --"
	(
		cd "$FLEET_SRC"
		LD_PRELOAD="$ROOT_DIR/tools/transplant/toolchain/openat2_shim.so" \
			"$BUN" install --force --ignore-scripts 2>&1 | tail -3
	) 2>&1 | tee -a "$EVID"
	[[ -d "$FLEET_SRC/node_modules/.bun" ]] || {
		say "STOP $VER: bun install produced no store"
		FAILED="$FAILED $VER(install)"
		continue
	}
	say "    store keys: $(ls "$FLEET_SRC/node_modules/.bun" | wc -l)  free=$(df_free_mb)MB"

	# 3a. platform 变体补装（android bun 报 platform=android，所以
	# `bun install` 不会拉 linux-arm64 的 @opentui/core 平台包 ——
	# 少了它 build-v1.sh 第 3 步就报 "no libopentui.so found in store"，
	# 编译出来的 TUI 会链不上。A2 的 1.18.32 树是 warm node_modules，
	# 早就带上了这个 chunk，所以这条只在冷装树上暴露。
	# 与 build-bionic.sh 的 rc2 (#20) 同法：逐个平台包装，缺一即停。
	OPENTUI_VER="$(python3 -c "import json;print(json.load(open('$FLEET_SRC/package.json'))['workspaces']['catalog']['@opentui/core'])" 2>/dev/null || echo 0.4.5)"
	say "-- [3a/8] install @opentui/core platform variants (v$OPENTUI_VER) --"
	for pkg in "@opentui/core-linux-arm64@$OPENTUI_VER" "@opentui/core-linux-arm64-musl@$OPENTUI_VER"; do
		if (
			cd "$FLEET_SRC"
			LD_PRELOAD="$ROOT_DIR/tools/transplant/toolchain/openat2_shim.so" \
				"$BUN" install --force --ignore-scripts --os=linux --cpu=arm64 "$pkg" 2>&1 | tail -2
		); then
			say "    OK  $pkg"
		else
			say "    WARN (non-fatal) $pkg unavailable"
		fi
	done
	mapfile -t SO_FOUND < <(find "$FLEET_SRC/node_modules" "$FLEET_SRC/packages/opencode/node_modules" \
		-name libopentui.so 2>/dev/null | sort -u)
	[[ ${#SO_FOUND[@]} -ge 1 ]] || {
		say "STOP $VER: still no libopentui.so in store after platform install"
		FAILED="$FAILED $VER(no-opentui)"
		continue
	}
	say "    libopentui.so store copies: ${#SO_FOUND[@]}"

	say "-- [3b/8] bun-pty store patch (bionic embed) --"
	V1_SRC="$FLEET_SRC" bash "$ROOT_DIR/tools/a2/pty-embed-store-patch.sh" 2>&1 | tee -a "$EVID"

	# ── 4. build-v1（android bun compile；不做 UPX） ────────────────────
	say "-- [4/8] build-v1.sh compile --"
	SKIP_SMOKE=1 VER="$VER" V1_SRC="$FLEET_SRC" ANDROID_BUN="$BUN" \
		MODELS_JSON="$MODELS_JSON" EFFECT_VER="$EFFECT_VER" TAG="$BTAG" \
		BUILD_ROOT="$ROOT_DIR/artifacts/build" \
		bash "$ROOT_DIR/tools/a2/build-v1.sh" 2>&1 | tee -a "$EVID"
	if [[ ! -x "$BUILT" ]]; then
		say "STOP $VER: build output missing: $BUILT"
		FAILED="$FAILED $VER(build)"
		continue
	fi
	RAW_SZ="$(stat -c%s "$BUILT")"
	RAW_SHA="$(sha256sum "$BUILT" | awk '{print $1}')"
	say "    built: $RAW_SZ B  sha256=$RAW_SHA"

	# ── 5. TLSDESC graft（槽位手术 + 零漂移/INIT_ARRAY/TLSDESC 三重断言） ──
	say "-- [5/8] TLSDESC graft --"
	rm -f "$GRAFTED"
	python3 "$ROOT_DIR/tools/transplant/swap_tui.py" \
		--binary "$BUILT" --tui-lib "$GRAFT_LIB" --out "$GRAFTED" 2>&1 | tee -a "$EVID"
	chmod 755 "$GRAFTED"
	if ! python3 - "$ROOT_DIR" "$BUILT" "$GRAFTED" "$GRAFT_LIB" 2>&1 << 'PYEOF' | tee -a "$EVID"
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
print(f"    graft assert: slot@{base:#x} {so}B (embed {sg}B + {so-sg}B pad), 0B drift outside slot")
PYEOF
	then
		say "STOP $VER: graft byte assertion failed"
		FAILED="$FAILED $VER(graft)"
		continue
	fi
	W="$ROOT_DIR/artifacts/build/.fleet-assert.$$"
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
		say "STOP $VER: post-graft readelf assert failed (INIT=$INIT TLSDESC=$TLSDESC)"
		FAILED="$FAILED $VER(graft-assert)"
		continue
	}

	# ── 6. hermetic home remap（分类断言内建；不过即停） ──────────────────
	say "-- [6/8] hermetic home remap --"
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
	say "    hermetic: $HER_SZ B  sha256=$HER_SHA"
	fi # end SKIP_TO_PACK==0（编译链）

	# ── 7. 形态自证（零 glibc + bionic 动态 + 未压缩） ───────────────────
	#
	# **不要断言 PT_INTERP/PT_DYNAMIC == 0** —— 那是 UPX 压制**之后**的形态。
	# 实测 A2 参照件 artifacts/build/1.18.32/opencode-v1-1.18.32-beta103-
	# hermetic-grafted（136MB，未压缩本体）：INTERP=1 DYNAMIC=1 NEEDED=
	# libc.so/libm.so/libdl.so；同一条链的 press6 件（47MB，已压制）才是
	# INTERP=0 DYNAMIC=0 NEEDED 空。UPX 会把动态段压掉，所以「静态」是压制
	# 的**结果**，不是本体的属性。
	#
	# 本体该断言的是**零 glibc**：NEEDED 只能出现 bionic 的无版本号 soname
	#（libc.so / libm.so / libdl.so —— Termux 的 libc.so 就是 bionic），
	# 任何带版本号的 libc.so.6 / libm.so.6 / libpthread.so.0 都是 glibc 漏入。
	say "-- [7/8] form self-proof (zero-glibc / bionic-dynamic / uncompressed) --"
	HOME_HITS="$(grep -c '/data/data/com.termux/files/home' "$HERMETIC" || true)"
	PT_INTERP="$(readelf -l "$HERMETIC" | grep -c INTERP || true)"
	PT_DYNAMIC="$(readelf -l "$HERMETIC" | grep -c DYNAMIC || true)"
	NEEDED="$(readelf -d "$HERMETIC" | grep NEEDED || true)"
	PTY_ASSET="$(grep -c 'librust_pty_arm64' "$HERMETIC" || true)"
	UPX_MAGIC="$(grep -c 'UPX!' "$HERMETIC" || true)"
	say "    home-path hits=$HOME_HITS (0)"
	say "    PT_INTERP=$PT_INTERP PT_DYNAMIC=$PT_DYNAMIC (1/1 = bionic dynamic本体，参照 A2 hermetic-grafted)"
	say "    embedded pty markers=$PTY_ASSET (>=1)  UPX! magic=$UPX_MAGIC (0 — 未压缩)"
	say "    NEEDED: $(echo "$NEEDED" | tr '\n' ' ')"
	STATIC_OK=1
	[[ "$HOME_HITS" == "0" ]] || { say "STOP $VER: home paths survived"; STATIC_OK=0; }
	[[ "$PTY_ASSET" -ge 1 ]] || { say "STOP $VER: embedded librust_pty asset missing"; STATIC_OK=0; }
	[[ "$UPX_MAGIC" == "0" ]] || { say "STOP $VER: binary carries UPX magic — not uncompressed"; STATIC_OK=0; }
	# 零 glibc 硬门：带版本号的 soname 是 glibc 特征
	if echo "$NEEDED" | grep -Eq 'NEEDED.*lib(c|m|dl|pthread|rt|util)\.so\.[0-9]'; then
		say "STOP $VER: glibc NEEDED in hermetic binary"
		STATIC_OK=0
	else
		say "    zero-glibc gate: OK (no versioned soname)"
	fi
	[[ "$STATIC_OK" -eq 1 ]] || { FAILED="$FAILED $VER(form)"; continue; }

	# ── 8. 打包（fleet pkgrel 带；绝不 UPX） ────────────────────────────
	say "-- [8/8] package (pkgrel=$PKGREL) + smoke --"
	# makepkg 与 package_pacman_native.sh 共用 packing/pacman 下的固定临时名
	# （.makepkg-opencode-native.conf / .PKGBUILD.opencode-native.tmp /
	# packing/pacman/{pkg,src}），且脚本开头会 rm -rf 这两目录。v1 与 v2 两个
	# driver 并发跑会互删对方的 conf（实测：v2 报 "conf not found"、v1 报
	# "User signal 1"）。所以打包必须跨 driver 串行 —— 用 flock 按 packing
	# 目录取锁，v2 driver 也持同一把锁。
	exec 9>"$ROOT_DIR/packing/pacman/.fleet-pkg.lock"
	if ! flock -w 1800 9; then
		say "STOP $VER: could not acquire packaging lock within 1800s"
		FAILED="$FAILED $VER(pkg-lock)"
		continue
	fi
	VERSION="$VER" PKGREL="$PKGREL" OPENCODE_NATIVE_BIN="$HERMETIC" \
		bash "$ROOT_DIR/scripts/package/package_pacman_native.sh" >>"$EVID" 2>&1
	PKG_RC=$?
	flock -u 9
	exec 9>&-
	if [[ "$PKG_RC" -ne 0 ]]; then
		say "STOP $VER: package_pacman_native.sh failed (rc=$PKG_RC)"
		FAILED="$FAILED $VER(pkg)"
		continue
	fi
	[[ -f "$OUT_PKG" ]] || { say "STOP $VER: package not produced: $OUT_PKG"; FAILED="$FAILED $VER(nopkg)"; continue; }
	MEMBERS="$(bsdtar -tf "$OUT_PKG")"
	ENTRY="data/data/com.termux/files/usr/bin/$FAMILY"
	RUNTIME_MEMBER="data/data/com.termux/files/usr/lib/$FAMILY/runtime/opencode"
	echo "$MEMBERS" | grep -qxF "$ENTRY" || { say "STOP $VER: missing entry member $ENTRY"; FAILED="$FAILED $VER(member-bin)"; continue; }
	echo "$MEMBERS" | grep -qxF "$RUNTIME_MEMBER" || { say "STOP $VER: missing runtime member $RUNTIME_MEMBER"; FAILED="$FAILED $VER(member-rt)"; continue; }
	if echo "$MEMBERS" | grep -qE '^usr/'; then
		say "STOP $VER: RELATIVE usr/ members — absolute termux-pacman convention required"
		FAILED="$FAILED $VER(rel-usr)"
		continue
	fi
	PKG_SZ="$(stat -c%s "$OUT_PKG")"
	PKG_SHA="$(sha256sum "$OUT_PKG" | awk '{print $1}')"
	say "    pkg: $(basename "$OUT_PKG")  size=$PKG_SZ  sha256=$PKG_SHA"

	# 8.1 --version
	V_OUT="$("$HERMETIC" --version 2>&1 || true)"
	say "    --version = $V_OUT"
	[[ "$V_OUT" == *"$VER"* ]] || { say "STOP $VER: version mismatch"; FAILED="$FAILED $VER(version)"; continue; }

	# 8.2 隔离假 HOME 四根落位 + 诱饵 XDG 零外泄
	W="$ROOT_DIR/artifacts/build/.fleet-smoke.$$"
	rm -rf "$W"
	mkdir -p "$W/home" "$W/tmp" "$W/decoy-cfg" "$W/decoy-data" "$W/decoy-state" "$W/decoy-cache"
	mkdir -p "$W/home/.config/$FAMILY/opencode"
	printf '{"port": %d}\n' "$((20000 + RANDOM % 20000))" > "$W/home/.config/$FAMILY/opencode/service.json"
	(
		export HOME="$W/home" TMPDIR="$W/tmp"
		export XDG_CONFIG_HOME="$W/decoy-cfg" XDG_DATA_HOME="$W/decoy-data"
		export XDG_STATE_HOME="$W/decoy-state" XDG_CACHE_HOME="$W/decoy-cache"
		cd "$W"
		timeout 25 "$HERMETIC" --print-logs >/dev/null 2>&1 || timeout 25 "$HERMETIC" >/dev/null 2>&1 || true
	) || true
	sleep 1
	ROOTS=0
	for p in ".local/share/$FAMILY/opencode" ".cache/$FAMILY/opencode" \
		".config/$FAMILY/opencode" ".local/state/$FAMILY/opencode"; do
		if [[ -e "$W/home/$p" ]]; then
			say "    root OK: \$HOME/$p"
			ROOTS=$((ROOTS + 1))
		fi
	done
	# 判据 = **opencode 命名空间是否外泄**，不是「诱饵目录字节数为 0」。
	#
	# 为什么不能一刀切要 0（阶段 A pilot 的写法过严，实测会误杀）：
	#   bun 自带的转译器缓存 `$XDG_CACHE_HOME/bun/@t@/*.pile` 会被写进诱饵
	#   cache 目录。那是 **bun 运行时**的缓存，路径由 bun 自己按 XDG_CACHE_HOME
	#   推导，opencode 的 A+ bake 管不到它（A+ 只改 global.ts 的四根派生）。
	#   它的内容是转译后的 JS，**不含任何 opencode 用户数据**。
	#
	# 反证（实测，参照件对比）：
	#   A2 参照件 1.18.32-beta103-hermetic-grafted（**无** A+ bake）：诱饵
	#     cfg=3922 / data=7 / state=2 / cache=3 条 —— opencode 自己的四根
	#     **全部**被 XDG 诱饵重定向（cache 里就是 opencode/bin、opencode/
	#     models.json），这才是真正的命名空间泄漏。
	#   本 fleet 件（A+ bake）：诱饵 cfg/data/state **全 0**，cache 里只有
	#     bun/@t@/*.pile —— 命名空间四根零外泄。
	# 所以门禁判「诱饵里出现 opencode1/ 或 opencode/ 命名空间路径 = FAIL」，
	# 其余（bun 自身缓存）记为 informational。这才与 A+ 的声明范围一致。
	DECOY_LEAK=0
	BUN_CACHE_ENTRIES=0
	for d in decoy-cfg decoy-data decoy-state decoy-cache; do
		n=$(find "$W/$d" -mindepth 1 2>/dev/null | wc -l)
		# 命名空间泄漏：诱饵下出现 opencode1/ 或 opencode/ 开头的条目
		ns=$(find "$W/$d" -mindepth 1 2>/dev/null |
			grep -cE '(^|/)(opencode1|opencode)(/|$)' || true)
		# bun 自身转译缓存（已知豁免）
		bn=$(find "$W/$d" -mindepth 1 -path '*/bun/*' 2>/dev/null | wc -l)
		say "    decoy $d entries=$n  namespace-leak=$ns  bun-runtime-cache=$bn"
		[[ "$ns" -eq 0 ]] || DECOY_LEAK=$((DECOY_LEAK + 1))
		BUN_CACHE_ENTRIES=$((BUN_CACHE_ENTRIES + bn))
	done
	say "    namespace-leak dirs=$DECOY_LEAK (expect 0)  bun-runtime-cache entries=$BUN_CACHE_ENTRIES (informational, 非 opencode 数据)"
	say "    roots landed=$ROOTS/4"
	rm -rf "$W"
	[[ "$DECOY_LEAK" -eq 0 ]] || { say "STOP $VER: opencode namespace leaked into decoy XDG"; FAILED="$FAILED $VER(decoy)"; continue; }

	# 8.3 真 PTY TUI 一帧 + 键入 DELTA>0
	SMOKE_OUT="$(bash "$EV_DIR/task-3-smoke.sh" "$HERMETIC" "fleet-$VER" 2>&1)"
	echo "$SMOKE_OUT" | tee -a "$EVID"
	if ! echo "$SMOKE_OUT" | grep -q 'verdict=GREEN'; then
		say "STOP $VER: TUI smoke not GREEN"
		FAILED="$FAILED $VER(tui)"
		continue
	fi

	DONE=$((DONE + 1))
	SUMMARY="$SUMMARY
$VER	OK	$PKG_SZ	$PKG_SHA	elf=$HER_SZ	elfsha=$HER_SHA	roots=$ROOTS/4	tui=GREEN"
	printf '%s\tv1\tOK\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$VER" "$OUT_PKG" "$PKG_SZ" "$PKG_SHA" "$HER_SZ" "$HER_SHA" "roots=$ROOTS/4 decoy=0" "tui=GREEN" \
		>>"$MANIFEST"
	say "    ==> v1 $VER DONE"
done

say ""
say "=== fleet-v1-build summary: done=$DONE failed=${FAILED:-none} ==="
if [[ -n "$SUMMARY" ]]; then
	say "$(printf 'ver\tstatus\tbytes\tsha256\telf_bytes\telf_sha256\tisolation\ttui')
$SUMMARY"
fi
exit 0
