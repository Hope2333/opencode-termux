#!/data/data/com.termux/files/usr/bin/bash
# compat-graft-build.sh — oldkernel-compat T6: B 档 graft 产品化编排
#
# 调用方: make compat-graft-renderer VER=<v>  （Makefile 已做 T6 范围锁，本脚本
#         再校验一次，便于单独调用时也不越界）
#
# 锁定流水线（plan oldkernel-compat.md T6，批准门裁决）:
#   build -> harden -> graft-old -> upx -> regraft-new 门禁 -> 打包
#
#   1. build     解析出 1.19.3 的 hardened native 产品到
#                artifacts/transplant/<ver>/opencode-native-tui。
#                默认复用既有产品（T1 实证件，与已交付 native deb 逐字节同源，
#                见 provenance-verdict 的 sha 比对）；产品缺失时才从已交付 deb
#                还原；COMPAT_BUILD_SOURCE=1 则强制 `make transplant` 全量重推。
#                不做静默替换：产品 --version / hardening 标记不达标直接 FATAL。
#   2. harden    `make seccomp-harden`（幂等；已 harden 则只重建 shim）。
#   3. graft-old 复用 T1 工具 scripts/compat/hybrid-renderer.sh（不改其逻辑）:
#                1.18.34 donor 的 bionic OpenTUI 0.5.10 (5495136B) 等长换入目标
#                slot(6037032, 小换大 NUL pad)。graft 必须在 upx 之前 —— swap_tui
#                对 UPX 压缩过的 ELF 会崩（与 transplant-upx 同一条约束）。
#                校验: --version 不变 + hardening 标记仍在 + 内嵌渲染库与 donor
#                资源逐字节相同（真 graft，不看日志自称）。
#   4. upx       graft 件过 UPX 默认**不跑**（既往实证: UPX×graft 必崩，见
#                docs/tui-reachability.md「UPX×graft 不兼容（2026-10-02）」——
#                graft 只改载荷 asset 字节，压制后启动即崩，且崩因与 shim/回填
#                无关；由此本仓惯例= graft 件一律未压出货）。要给老内核设备压制品
#                必须先拿到反证: COMPAT_TRY_UPX=1 才真跑 upx，并把结果交给 stage 5
#                门禁；跑不动/没标记也绝不静默跳过，一定留 upx-verdict 行。
#   5. regraft-new 门禁（本机 pty 5 连, rc=124=活 / 139=SIGSEGV）:
#                - unpacked hybrid 必须 5/5 活，否则视为 graft 本身坏 → 不出包。
#                - graft+upx 候选件要不要作为 compressed 出货，只能由**老内核机
#                  实测**决定（本机内核 6.x 会屏蔽老内核竞态，本地"活"不构成
#                  证据）。判定顺序:
#                    a) COMPAT_OSCAR_TARGET 给了 → 本脚本自己 scp 到该机（先
#                       uname -r 核身，内核前缀不符即拒判）跑 pty 5 连 + 渲染
#                       序列取证；5/5 活且有 alt-screen 序列 → compressed 出货。
#                    b) 未给 target 且 COMPAT_COMPRESSED_GRAFT=1 → 视调用方已在
#                       老内核机实测放行（仅要求本机 5/5），compressed 出货。
#                    c) 其余 → compressed 不出货（native-only），verdict 里写明
#                       原因与复跑方式。
#                禁假绿: 崩的候选件永不出包；本地"活"不代替老内核实测。
#   6. 打包       native(hybrid) [+ compressed(graft+upx，仅门禁放行时)] 的
#                deb+pacman。打包用 $WORK 内的 TRANSPLANT_ROOT 快照隔离（不复用
#                artifacts/transplant 活路径，避免与并发构建串扰）。同版本货架包
#                在打包前整体挪入 quarantine，结束后原样还原。出货目录
#                packing/compat/<ver>/（发布分发属 T7 决策，不在本目标内），
#                产出 MANIFEST.txt + SHA256SUMS。
#
# 出货路径: packing/compat/<ver>/ （*.deb / *.pkg.tar.* 均被 .gitignore 忽略，
#           产物不入库，路径与 sha 写 evidence）
#
# 环境变量:
#   COMPAT_BUILD_SOURCE=1        强制 `make transplant` 全量重推产品
#   COMPAT_TRY_UPX=1             真跑 upx 压制实验（默认跳过，见 stage 4）
#   COMPAT_OSCAR_TARGET=u@host  老内核机（配合 COMPAT_OSCAR_PORT，默认 8022）
#   COMPAT_OSCAR_KERNEL=3.18.140 老内核机核身前缀（默认 3.18.140，不符即拒判）
#   COMPAT_COMPRESSED_GRAFT=1   调用方已用别的方式完成老内核实测，放行 compressed
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
set -e

VER="${1:-}"
[[ -n "$VER" ]] || {
	echo "usage: compat-graft-build.sh <ver>" >&2
	exit 1
}
SCOPE_LOCK=1.19.3
if [[ "$VER" != "$SCOPE_LOCK" ]]; then
	echo "FATAL: T6 scope locked to $SCOPE_LOCK (approval gate)." >&2
	echo "       Widening to other versions is a DEFERRED decision (plan T6 note)." >&2
	exit 1
fi
DONOR_VER=1.18.34

case "$VER" in
1.*) PKGNAME=opencode1 ;;
*) PKGNAME=opencode ;;
esac

NDIR="artifacts/transplant/$VER"
NATIVE="$NDIR/opencode-native-tui"
CRH="$NDIR/libopencode-crhandler.so"
HYB="$NDIR/opencode-native-hybrid"
HYB_UPX="$NDIR/opencode-native-hybrid-upx"
OUT="packing/compat/$VER"
DONOR_DEB="packing/dpkg-native/${PKGNAME}_${DONOR_VER}_aarch64.deb"
SHELF_DEB="packing/dpkg-native/${PKGNAME}_${VER}_aarch64.deb"
SHELF_DEB_COMP="packing/dpkg-compressed/${PKGNAME}-compressed_${VER}_aarch64.deb"
PACM_NATIVE_GLOB="packing/pacman/${PKGNAME}-${VER}-"
PACM_COMP_GLOB="packing/pacman/${PKGNAME}-compressed-${VER}-"

OSCAR_TARGET="${COMPAT_OSCAR_TARGET:-}"
OSCAR_PORT="${COMPAT_OSCAR_PORT:-8022}"
OSCAR_KERNEL="${COMPAT_OSCAR_KERNEL:-3.18.140}"

WORK="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/compat-graft-XXXXXX")"
fail() {
	echo "FATAL: $*" >&2
	exit 1
}

# ── shelf quarantine / restore（失败也还原，别把货架留空） ────────────────
_quarantine_one() {
	local f="$1"
	[[ -f "$f" ]] || return 0
	mkdir -p "$WORK/shelf/$(dirname "$f")"
	mv "$f" "$WORK/shelf/$f"
	printf '%s\n' "$f" >>"$WORK/shelf.list"
	echo "shelf-quarantine: $f"
}
quarantine_shelf() {
	local f
	shopt -s nullglob
	for f in "${PACM_NATIVE_GLOB}"*.pkg.* "${PACM_COMP_GLOB}"*.pkg.*; do
		_quarantine_one "$f"
	done
	shopt -u nullglob
	_quarantine_one "$SHELF_DEB"
	_quarantine_one "$SHELF_DEB_COMP"
}
restore_shelf() {
	local rel
	[[ -f "$WORK/.shelf-restored" ]] && return 0
	if [[ -f "$WORK/shelf.list" ]]; then
		while IFS= read -r rel; do
			[[ -n "$rel" ]] || continue
			mkdir -p "$(dirname "$rel")"
			rm -f "$rel" # 同名出货件不得覆盖货架原件
			cp -p "$WORK/shelf/$rel" "$rel" && echo "shelf-restore: $rel"
		done <"$WORK/shelf.list"
	fi
	touch "$WORK/.shelf-restored"
}
cleanup() {
	local rc=$?
	restore_shelf || true
	rm -rf "$WORK"
	exit $rc
}
trap cleanup EXIT INT TERM

# ── 磁盘护栏（graft 峰值: 181M 原始 + 181M packed + staging 快照 ≈ 1.5G）──
AVAIL_MB=$(df -P . | awk 'NR==2{print int($4/1024)}')
if [[ "$AVAIL_MB" -lt 1500 ]]; then
	fail "only ${AVAIL_MB}MB free under $ROOT; pipeline needs ~1500MB peak. Free space first."
fi

# ── 二进制直跑器（harden 后 DT_NEEDED libopencode-crhandler.so，需要 shim 路径）──
run_bin() { # run_bin <abs-path> [args...]
	local bin="$1"
	shift
	LD_LIBRARY_PATH="$ROOT/$NDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$bin" "$@"
}
ver_of() { # ver_of <abs-path> -> x.y.z or empty
	run_bin "$1" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){2}' | head -n1 || true
}
probe_once() { # pty 单发: 124=活(被 timeout 收尾) / 139=SIGSEGV / 其它原样返回
	local bin="$1" rc=0
	set +e
	LD_LIBRARY_PATH="$ROOT/$NDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		script -qec "timeout 10 $bin" /dev/null >/dev/null 2>&1
	rc=$?
	set -e
	echo "$rc"
}
probe5() { # probe5 <abs-path> -> "124 124 124 124 124"
	local bin="$1" i rcs=()
	for i in 1 2 3 4 5; do rcs+=("$(probe_once "$bin")"); done
	echo "${rcs[*]}"
}
all_124() { # all_124 "<rc list>"
	local r
	for r in $1; do [[ "$r" == "124" ]] || return 1; done
	[[ -n "$1" ]]
}
embedded_tui_sha() { # embedded_tui_sha <elf> -> "<sha256> <size>" of the bunfs OpenTUI asset
	python3 - "$1" <<'PY'
import sys, hashlib, importlib.util
spec = importlib.util.spec_from_file_location('swap_tui', 'tools/transplant/swap_tui.py')
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)
data = open(sys.argv[1], 'rb').read()
off = st.find_libopentui_asset(data)
if off <= 0:
    print("MISSING 0")
    sys.exit(0)
size = st.elf_size(data, off)
print(f"{hashlib.sha256(data[off:off+size]).hexdigest()} {size}")
PY
}

# ── 老内核机门禁（仅当 COMPAT_OSCAR_TARGET 给出时启用）─────────────────
OSCAR_KERNEL_SEEN=""
oscar_gate() { # oscar_gate <local-bin> -> 0 = 5/5 活且渲染实证齐; 1 = 未过; 2 = 跳过(不可达/核身不符)
	local bin="$1" rtmp rdir rcs render k
	OSCAR_KERNEL_SEEN="$(ssh -p "$OSCAR_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
		"$OSCAR_TARGET" 'uname -r' 2>/dev/null)" || {
		echo "oscar-gate: SKIP (ssh 不可达 $OSCAR_TARGET:$OSCAR_PORT)" >&2
		return 2
	}
	OSCAR_KERNEL_SEEN="${OSCAR_KERNEL_SEEN%% *}"
	if [[ "$OSCAR_KERNEL_SEEN" != *"$OSCAR_KERNEL"* ]]; then
		echo "oscar-gate: SKIP (kernel '$OSCAR_KERNEL_SEEN' 不匹配 '$OSCAR_KERNEL' —— IP 可能漂移/抢占，拒判)" >&2
		return 2
	fi
	rtmp="$(ssh -p "$OSCAR_PORT" -o BatchMode=yes "$OSCAR_TARGET" 'echo $TMPDIR' 2>/dev/null)" || return 2
	rdir="${rtmp%/}/t6probe"
	ssh -p "$OSCAR_PORT" -o BatchMode=yes "$OSCAR_TARGET" \
		"mkdir -p '$rdir' && rm -f '$rdir'/*" 2>/dev/null || return 2
	scp -q -P "$OSCAR_PORT" -o BatchMode=yes "$bin" "$OSCAR_TARGET:$rdir/t6probe.bin" 2>/dev/null || {
		echo "oscar-gate: SKIP (scp 二进制失败)" >&2
		return 2
	}
	scp -q -P "$OSCAR_PORT" -o BatchMode=yes "$ROOT/$CRH" \
		"$OSCAR_TARGET:$rdir/libopencode-crhandler.so" 2>/dev/null || {
		echo "oscar-gate: SKIP (scp crhandler shim 失败)" >&2
		return 2
	}
	rcs="$(ssh -p "$OSCAR_PORT" -o BatchMode=yes "$OSCAR_TARGET" "RDIR='$rdir' sh -s" <<'EOS' 2>/dev/null
i=0
while [ "$i" -lt 5 ]; do
	LD_LIBRARY_PATH="$RDIR" script -qec "timeout 10 $RDIR/t6probe.bin" /dev/null >/dev/null 2>&1
	printf '%s ' "$?"
	i=$((i + 1))
done
echo
EOS
)" || return 2
	OSCAR_RCS="$(echo "$rcs" | tr -s ' \n' ' ')"
	render="$(ssh -p "$OSCAR_PORT" -o BatchMode=yes "$OSCAR_TARGET" "RDIR='$rdir' sh -s" <<'EOS' 2>/dev/null
LD_LIBRARY_PATH="$RDIR" script -qec "timeout 10 $RDIR/t6probe.bin" /dev/null 2>&1 | head -c 40000
EOS
)" || render=""
	printf '%s' "$render" >"$WORK/oscar-render-$(basename "$bin").out"
	ssh -p "$OSCAR_PORT" -o BatchMode=yes "$OSCAR_TARGET" "rm -rf '$rdir'" 2>/dev/null || true
	k=0
	for _ in $OSCAR_RCS; do k=$((k + 1)); done
	if [[ "$k" -ne 5 ]] || ! all_124 "$OSCAR_RCS"; then
		return 1
	fi
	grep -qa '1049h' "$WORK/oscar-render-$(basename "$bin").out" || return 1 # alt-screen 序列缺失 = 没真出全屏 TUI
	return 0
}

# ══════════════════════════════════════════════════════════════════════
echo "==> [stage 1/6 build] VER=$VER — 解析 hardened native 产品"
mkdir -p "$NDIR"
BUILD_SOURCE=""
if [[ "${COMPAT_BUILD_SOURCE:-0}" == "1" ]]; then
	echo "==> COMPAT_BUILD_SOURCE=1: 全量重推（make transplant，含 npm 取源 + TUI swap + harden）"
	make --no-print-directory transplant VER="$VER"
	BUILD_SOURCE="transplant-rebuild"
elif [[ -f "$NATIVE" ]] && grep -aqF libopencode-crhandler.so "$NATIVE" &&
	[[ "$(ver_of "$PWD/$NATIVE")" == "$VER" ]]; then
	BUILD_SOURCE="existing-transplant-product"
	echo "==> 复用既有 hardened 产品（无需重推）"
else
	[[ -f "$SHELF_DEB" ]] || fail "无 $NATIVE 也无 $SHELF_DEB；先跑 make transplant VER=$VER（或放好已交付 deb）"
	echo "==> 产品缺失: 从已交付 native deb 还原 runtime"
	dpkg-deb -x "$SHELF_DEB" "$WORK/deb"
	cp -p "$WORK/deb/data/data/com.termux/files/usr/lib/$PKGNAME/runtime/opencode" "$NATIVE"
	chmod +x "$NATIVE"
	for _sd in opencode "$PKGNAME"; do
		_shim="$WORK/deb/data/data/com.termux/files/usr/lib/$_sd/libopencode-crhandler.so"
		[[ -f "$_shim" ]] && {
			cp -p "$_shim" "$CRH"
			break
		}
	done
	BUILD_SOURCE="restored-from-delivered-deb"
fi
[[ -f "$NATIVE" ]] || fail "no native product at $NATIVE after stage 1"
NATIVE_VER=$(ver_of "$PWD/$NATIVE")
[[ "$NATIVE_VER" == "$VER" ]] || fail "product --version='$NATIVE_VER', expected $VER"
grep -aqF libopencode-crhandler.so "$NATIVE" || fail "product at $NATIVE is not seccomp-hardened"
NATIVE_SHA=$(sha256sum "$NATIVE" | cut -d' ' -f1)
echo "build-verdict: source=$BUILD_SOURCE sha256=$NATIVE_SHA size=$(stat -c%s "$NATIVE")B version=$NATIVE_VER"

# ══════════════════════════════════════════════════════════════════════
echo "==> [stage 2/6 harden] seccomp-harden（幂等，已 harden 则只重建 shim）"
make --no-print-directory seccomp-harden VER="$VER"
[[ -f "$CRH" ]] || fail "crhandler shim missing at $CRH after stage 2"
grep -aqF libopencode-crhandler.so "$NATIVE" || fail "product lost hardening at stage 2"
echo "harden-verdict: ok — DT_NEEDED libopencode-crhandler.so present (shim $(stat -c%s "$CRH")B)"
NATIVE_SHA=$(sha256sum "$NATIVE" | cut -d' ' -f1)

# 一致性护栏: hybrid-renderer.sh（T1 工具，不改）以货架 deb 为 graft 输入端。若货架
# deb 与刚解析/刚重推的产品不同源，graft 会静默作用在旧件上 —— 直接拦下。
[[ -f "$SHELF_DEB" ]] || fail "货架 deb 缺失 $SHELF_DEB（hybrid-renderer.sh 需要它作 graft 输入）"
dpkg-deb -x "$SHELF_DEB" "$WORK/debsrc"
DEB_RT_SHA=$(sha256sum "$WORK/debsrc/data/data/com.termux/files/usr/lib/$PKGNAME/runtime/opencode" | cut -d' ' -f1)
if [[ "$DEB_RT_SHA" != "$NATIVE_SHA" ]]; then
	fail "货架 deb runtime sha=$DEB_RT_SHA 与产品 sha=$NATIVE_SHA 不同源。
       graft 会作用在旧件上。先重打货架件: make deb-native VER=$VER pacman-native VER=$VER（或删掉产品走 deb 还原路径）"
fi
echo "provenance-verdict: 货架 deb runtime == 产品 sha256 ($NATIVE_SHA)"

# ══════════════════════════════════════════════════════════════════════
echo "==> [stage 3/6 graft-old] donor $DONOR_VER 的 OpenTUI 0.5.10 等长换入（复用 T1 工具）"
[[ -f "$DONOR_DEB" ]] || fail "donor deb missing: $DONOR_DEB"
bash scripts/compat/hybrid-renderer.sh "$VER" "$DONOR_VER" "$HYB" || fail "hybrid-renderer.sh failed"

HYB_VER=$(ver_of "$PWD/$HYB")
[[ "$HYB_VER" == "$VER" ]] || fail "hybrid --version='$HYB_VER', expected $VER（CLI 身份必须不变）"
grep -aqF libopencode-crhandler.so "$HYB" || fail "graft dropped the hardening (unexpected: 等长换位不动 dynamic section)"

# donor 资源指纹（作为 graft 真伪的唯一判据）
dpkg-deb -x "$DONOR_DEB" "$WORK/donor"
DONOR_RT="$WORK/donor/data/data/com.termux/files/usr/lib/$PKGNAME/runtime/opencode"
DONOR_TUI=$(embedded_tui_sha "$DONOR_RT")
HYB_TUI=$(embedded_tui_sha "$HYB")
[[ "$DONOR_TUI" != MISSING* ]] || fail "donor 件里找不到 OpenTUI 资源（$DONOR_DEB 不是预期的 bunfs 布局）"
[[ "$HYB_TUI" != MISSING* ]] || fail "hybrid 件里找不到 OpenTUI 资源"
[[ "${DONOR_TUI%% *}" == "${HYB_TUI%% *}" ]] || fail "graft 未生效: hybrid 内嵌 TUI $HYB_TUI != donor $DONOR_TUI"
HYB_SHA=$(sha256sum "$HYB" | cut -d' ' -f1)
HYB_SIZE=$(stat -c%s "$HYB")
echo "graft-verdict: ok — hybrid sha256=$HYB_SHA size=${HYB_SIZE}B"
echo "               embedded-open-tui sha256=${HYB_TUI%% *} size=${HYB_TUI##* }B == donor $DONOR_VER (真 graft 判据)"
case "$HYB_SHA" in
04dfae41*)
	echo "               reproducible: 与 T1 实证件 sha256 前缀 04dfae41 一致（确定性 graft）"
	;;
*)
	echo "               NOTE: sha256 与 T1 参考（04dfae41…）不同 —— donor/target 件可能已变更，见 evidence"
	;;
esac

# ── B 档装机标记（follow-up: launcher graft 探测的识别依据）──────────────────
# 老内核机（如 oscar）裸跑 opencode1 时, launcher 靠 runtime 同目录的 .grafted
# 标记跳过 T4 无脑降级、直起 TUI。标记随 native deb/pacman 出货到
# <prefix>/lib/opencode1/runtime/.grafted; runtime_sha 用刚算出的 hybrid 件
# （stage 6 对 deb/pacman 包内标记逐包校验; 打包脚本另有 sha 一致性护栏）。
{
	printf 'grafted=1\n'
	printf 'donor=%s\n' "$DONOR_VER"
	printf 'target=%s\n' "$VER"
	printf 'runtime_sha=%s\n' "$HYB_SHA"
	printf 'runtime_size=%s\n' "$HYB_SIZE"
	printf 'built_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >"$NDIR/.grafted"
echo "graft-marker: wrote $NDIR/.grafted (donor=$DONOR_VER target=$VER sha256=$HYB_SHA size=${HYB_SIZE}B)"

# ══════════════════════════════════════════════════════════════════════
echo "==> [stage 4/6 upx] graft 件压制（默认跳过: UPX×graft 既往实证必崩）"
UPX_OK=0
HYB_UPX_SIZE=0
UPX_RATIO="n/a"
if [[ "${COMPAT_TRY_UPX:-0}" != "1" ]]; then
	echo "upx-verdict: SKIP — graft 件默认不出压制品。既往实证: UPX×graft 必崩（启动即 rc=139），"
	echo "             根因与 shim/回填/提取内容无关，docs/tui-reachability.md「UPX×graft 不兼容（2026-10-02）」;"
	echo "             本仓惯例 = graft 件一律未压出货。要复测取证请加 COMPAT_TRY_UPX=1。"
	# 有残留的「未压缩同名副本」必须清掉，否则下游会把未压件当压制品
	if [[ -f "$HYB_UPX" ]] && ! grep -aqF 'UPX!' "$HYB_UPX" 2>/dev/null; then
		rm -f "$HYB_UPX" "$HYB_UPX.upx"
		echo "             清掉残骸 $HYB_UPX（无 UPX! 标记，不是有效压制品）"
	fi
else
# 残骸清理: 既往中断的 upx 会留下不带 UPX! 标记的同名副本与 *.upx 备份碎片，
# 若被复用分支命中，就会把「未压缩件」当压缩件出货 —— 先清掉。
for _junk in "$HYB_UPX" "$HYB_UPX.upx"; do
	[[ -f "$_junk" ]] || continue
	if grep -aqF 'UPX!' "$_junk" 2>/dev/null && [[ "$_junk" == "$HYB_UPX" ]]; then
		: # 有效压缩件交下面复用分支判断
	else
		rm -f "$_junk"
	fi
done
if ! command -v upx >/dev/null 2>&1; then
	echo "upx-verdict: SKIP — upx 未安装，compressed 变体不可产出"
elif [[ -f "$HYB_UPX" ]] && ! [[ "$HYB" -nt "$HYB_UPX" ]] && grep -aqF 'UPX!' "$HYB_UPX"; then
	UPX_OK=1
	HYB_UPX_SIZE=$(stat -c%s "$HYB_UPX")
	UPX_RATIO=$(awk "BEGIN{printf \"%.1f\", $HYB_UPX_SIZE*100/$HYB_SIZE}")
	echo "upx-verdict: ok — 复用既有压缩件 $HYB_UPX ${HYB_UPX_SIZE}B (ratio ${UPX_RATIO}%)"
else
	cp -p "$HYB" "$HYB_UPX"
	if upx --best --no-color "$HYB_UPX" >/dev/null 2>&1 && grep -aqF 'UPX!' "$HYB_UPX"; then
		UPX_OK=1
		HYB_UPX_SIZE=$(stat -c%s "$HYB_UPX")
		UPX_RATIO=$(awk "BEGIN{printf \"%.1f\", $HYB_UPX_SIZE*100/$HYB_SIZE}")
		echo "upx-verdict: ok — $HYB_UPX ${HYB_UPX_SIZE}B (ratio ${UPX_RATIO}%)"
	else
		rm -f "$HYB_UPX" "$HYB_UPX.upx"
		echo "upx-verdict: FAILED — upx 未能产出带 UPX! 标记的件，compressed 变体禁用（native-only 交付）"
	fi
fi
fi

# ══════════════════════════════════════════════════════════════════════
echo "==> [stage 5/6 regraft-new] 门禁（本机 kernel $(uname -r)）"
RC_HYB=$(probe5 "$PWD/$HYB")
echo "probe hybrid(unpacked) : $RC_HYB   (124=活 139=SIGSEGV)"
all_124 "$RC_HYB" || fail "unpacked hybrid 本机未 5/5 活（$RC_HYB）—— graft 本身坏了，拒绝出包"

RC_UPX="(n/a: upx 未产出)"
if [[ "$UPX_OK" == "1" ]]; then
	RC_UPX=$(probe5 "$PWD/$HYB_UPX")
	echo "probe hybrid+upx       : $RC_UPX"
	all_124 "$RC_UPX" || echo "           NOTE: 本地打包件已崩 —— 与既往 UPX×graft 教训一致；最终以老内核实测为准"
fi

# compressed 出货裁决: 只有老内核机（或调用方显式放行）能把 graft+upx 变成可交付件
COMPRESSED_SRC=""
COMPRESSED_MODE="native-only"
COMPRESSED_WHY="graft+upx 候选未取得老内核机放行证据（禁假绿: 本地活不等于 3.18 活）"
OSCAR_RCS="(not tested)"
if [[ "$UPX_OK" != "1" ]]; then
	COMPRESSED_WHY="graft+upx 没有有效压制品（默认跳过: UPX×graft 既往实证必崩，见 docs/tui-reachability.md；复测取证加 COMPAT_TRY_UPX=1）"
elif [[ -n "$OSCAR_TARGET" ]]; then
	echo "==> 老内核门禁: $OSCAR_TARGET (kernel 期望含 $OSCAR_KERNEL)"
	set +e
	oscar_gate "$PWD/$HYB_UPX"
	GATE_RC=$?
	set -e
	case "$GATE_RC" in
	0)
		COMPRESSED_SRC="$PWD/$HYB_UPX"
		COMPRESSED_MODE="graft-hybrid upx (旧渲染器打包件)"
		COMPRESSED_WHY="老内核机 $(OSCAR_KERNEL_SEEN) 实测 5/5 活 + alt-screen 渲染序列实证"
		;;
	1)
		COMPRESSED_WHY="老内核机 $(OSCAR_KERNEL_SEEN) 实测未过（rc=[$OSCAR_RCS]）—— UPX×graft 崩，compressed 不出货"
		;;
	*)
		COMPRESSED_WHY="老内核门禁跳过（kernel='$OSCAR_KERNEL_SEEN' ssh 不可达/核身不符），未取得放行证据"
		;;
	esac
	echo "oscar-gate: kernel=$OSCAR_KERNEL_SEEN rc=[$OSCAR_RCS] -> compressed=$( [[ -n $COMPRESSED_SRC ]] && echo 出货 || echo 不出货 )"
elif [[ "${COMPAT_COMPRESSED_GRAFT:-0}" == "1" ]]; then
	all_124 "$RC_UPX" || fail "COMPAT_COMPRESSED_GRAFT=1 但 hybrid+upx 本机未 5/5 活（$RC_UPX）"
	COMPRESSED_SRC="$PWD/$HYB_UPX"
	COMPRESSED_MODE="graft-hybrid upx (旧渲染器打包件)"
	COMPRESSED_WHY="调用方 COMPAT_COMPRESSED_GRAFT=1 显式放行（已在老内核机另行实测）"
fi
if [[ -n "$COMPRESSED_SRC" ]]; then
	echo "verdict: compressed=旧渲染器打包件 — $COMPRESSED_WHY"
	echo "         (regraft-new: 新渲染器路径在本目标内不采用 —— 它不解决老内核崩, 单出 compressed 会误导)"
else
	echo "verdict: compressed 不出货（native-only）— $COMPRESSED_WHY"
	echo "         复跑放行: COMPAT_OSCAR_TARGET=<user@host> make compat-graft-renderer VER=$VER"
fi

# ══════════════════════════════════════════════════════════════════════
echo "==> [stage 6/6 打包] native(hybrid)$( [[ -n $COMPRESSED_SRC ]] && echo ' + compressed(graft+upx)' ) -> $OUT/"
mkdir -p "$OUT"
quarantine_shelf

SNAP="$WORK/snaproot" # 快照隔离: 不复用 artifacts/transplant 活路径
mkdir -p "$SNAP/$VER"
# 模式归一: transplant 产品的落盘模式可能是 700（umask 残留），deb 侧 install -m755
# 会纠正，pacman 侧却原样继承 —— 不归一就会产出 700 runtime 的 pacman 包（与货架
# 上全部 1.18.x/2.0.x 包的 755 约定不符）。所以快照阶段就钉死 755/644。
install -m755 "$HYB" "$SNAP/$VER/opencode-native-tui"
install -m644 "$CRH" "$SNAP/$VER/libopencode-crhandler.so"
# .grafted 标记随快照进包（deb/pacman 打包脚本只取 $TRANSPLANT_ROOT/$VER/ 下的件;
# 装机后 launcher 的 graft 探测读它, 老内核机裸跑直起 TUI 不再无脑降级）
[[ -f "$NDIR/.grafted" ]] || fail "graft marker missing at $NDIR/.grafted（stage 3 应已写出）"
install -m644 "$NDIR/.grafted" "$SNAP/$VER/.grafted"

TRANSPLANT_ROOT="$SNAP" make --no-print-directory deb-native VER="$VER"
TRANSPLANT_ROOT="$SNAP" make --no-print-directory pacman-native VER="$VER"
if [[ -n "$COMPRESSED_SRC" ]]; then
	OPENCODE_COMPRESSED_BIN="$COMPRESSED_SRC" OPENCODE_CRHANDLER_SO="$PWD/$CRH" TRANSPLANT_ROOT="$SNAP" \
		make --no-print-directory deb-compressed VER="$VER"
	OPENCODE_COMPRESSED_BIN="$COMPRESSED_SRC" OPENCODE_CRHANDLER_SO="$PWD/$CRH" TRANSPLANT_ROOT="$SNAP" \
		make --no-print-directory pacman-compressed VER="$VER"
fi
rm -rf "$SNAP" packing/dpkg-native/work packing/dpkg-compressed/work packing/pacman/pkg packing/pacman/src

# 收集本变体产物（货架已 quarantine，此刻同名通配只会命中本次产物）
DELIVERED=()
collect() {
	local f
	for f in "$@"; do
		[[ -f "$f" ]] || fail "预期产物缺失: $f"
		mv -f "$f" "$OUT/"
		DELIVERED+=("$(basename "$f")")
	done
}
shopt -s nullglob
collect "$SHELF_DEB"
[[ -n "$COMPRESSED_SRC" ]] && collect "$SHELF_DEB_COMP"
nat=("${PACM_NATIVE_GLOB}"*.pkg.*)
comp=("${PACM_COMP_GLOB}"*.pkg.*)
shopt -u nullglob
[[ ${#nat[@]} -gt 0 ]] || fail "pacman native 产物缺失（${PACM_NATIVE_GLOB}*.pkg.*）"
PAC_NAT_NAME="$(basename "${nat[0]}")"
collect "${nat[@]}"
if [[ -n "$COMPRESSED_SRC" ]]; then
	[[ ${#comp[@]} -gt 0 ]] || fail "pacman compressed 产物缺失（${PACM_COMP_GLOB}*.pkg.*）"
	collect "${comp[@]}"
fi

# ── 出货件指纹校验（反假绿: 验包内容，不信构建日志）───────────────────
CHK="$WORK/chk"
mkdir -p "$CHK" # dpkg-deb -x 不会创建多级父目录，缺了会 "failed to create directory"
dpkg-deb -x "$OUT/${PKGNAME}_${VER}_aarch64.deb" "$CHK/native"
NAT_RT="$CHK/native/data/data/com.termux/files/usr/lib/$PKGNAME/runtime/opencode"
[[ -f "$NAT_RT" ]] || fail "native deb 里没有 runtime/$PKGNAME 件"
grep -aqF libopencode-crhandler.so "$NAT_RT" || fail "native deb 的 runtime 丢了 hardening"
[[ "$(sha256sum "$NAT_RT" | cut -d' ' -f1)" == "$HYB_SHA" ]] || fail "native deb 的 runtime != hybrid 件（打包串味）"
[[ "$(embedded_tui_sha "$NAT_RT")" == "$HYB_TUI" ]] || fail "native deb 的 runtime 内嵌渲染库 != donor（graft 没进包）"
grep -q -- '--force-tui' "$CHK/native/data/data/com.termux/files/usr/bin/${PKGNAME}" ||
	fail "native deb 带的是 T4 之前的 launcher（无 --force-tui 兜底开关）"
[[ "$(stat -c%a "$NAT_RT")" == "755" ]] || fail "native deb 的 runtime 模式 $(stat -c%a "$NAT_RT") != 755"
# follow-up: .grafted 标记必须在包内 runtime 同目录（老内核机裸跑直起 TUI 的识别依据）
NAT_MARKER="$CHK/native/data/data/com.termux/files/usr/lib/$PKGNAME/runtime/.grafted"
[[ -f "$NAT_MARKER" ]] || fail "native deb 缺 .grafted 标记（装机后裸跑将退化成无脑降级 CLI）"
grep -qF "target=$VER" "$NAT_MARKER" || fail "native deb 的 .grafted 标记 target 不是 $VER"
grep -qF "runtime_sha=$HYB_SHA" "$NAT_MARKER" || fail "native deb 的 .grafted 标记 runtime_sha != hybrid $HYB_SHA"
echo "native-pkg-verdict: ok — runtime==hybrid (755), embedded TUI==donor $DONOR_VER, launcher 含 T4 --force-tui, .grafted 标记在包"

# pacman 侧模式同样校验（pacman 打包会继承源文件模式，历史上因此出过 700 包）
PAC_MODE="$(tar -tvf "$OUT/$PAC_NAT_NAME" | awk '$0 ~ /lib\/'"$PKGNAME"'\/runtime\/opencode$/ {print $1; exit}')"
[[ -n "$PAC_MODE" ]] || fail "pacman native 包里找不到 runtime 件（$PAC_NAT_NAME）"
[[ "$PAC_MODE" == "-rwxr-xr-x" ]] || fail "pacman native 的 runtime 模式 $PAC_MODE != -rwxr-xr-x"
tar -tf "$OUT/$PAC_NAT_NAME" | grep -q "lib/$PKGNAME/runtime/\.grafted$" ||
	fail "pacman native 包缺 .grafted 标记（装机后裸跑将退化成无脑降级 CLI）"
echo "pacman-native-verdict: ok — runtime 模式 $PAC_MODE, .grafted 标记在包"

COMP_SHA="n/a"
if [[ -n "$COMPRESSED_SRC" ]]; then
	COMP_DEB="$OUT/${PKGNAME}-compressed_${VER}_aarch64.deb"
	dpkg-deb -x "$COMP_DEB" "$CHK/comp"
	COMP_RT=$(find "$CHK/comp" -path "*runtime/opencode" -type f | head -n1)
	[[ -n "$COMP_RT" ]] || fail "compressed deb 里没有 runtime 件"
	COMP_SHA=$(sha256sum "$COMPRESSED_SRC" | cut -d' ' -f1)
	[[ "$(sha256sum "$COMP_RT" | cut -d' ' -f1)" == "$COMP_SHA" ]] ||
		fail "compressed deb 的 runtime != 指定的 compressed 源件"
	grep -aqF 'UPX!' "$COMP_RT" || fail "compressed deb 的 runtime 不是 UPX 件"
	echo "compressed-pkg-verdict: ok — runtime==$(basename "$COMPRESSED_SRC") (UPX shim 齐)"
fi

# ── MANIFEST + SHA256SUMS ─────────────────────────────────────────────
{
	echo "oldkernel-compat T6 — B 档 graft 出货清单"
	echo "version          : $VER (scope lock $SCOPE_LOCK, approval gate)"
	echo "built at         : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "host             : $(uname -r)"
	echo
	echo "variant native   : CLI $VER + OpenTUI 0.5.10 (donor $DONOR_VER) — 老内核可用"
	echo "  runtime sha256 : $HYB_SHA ($HYB_SIZE B)"
	echo "  embedded tui   : ${HYB_TUI%% *} (${HYB_TUI##* } B) == donor asset"
	echo "  reproducible   : T1 参考 sha256 04dfae41a770eb73… (同源则一致)"
	echo "  graft marker   : .grafted (donor=$DONOR_VER, target=$VER) 随 deb/pacman 出货 — launcher graft 探测据此让老内核机裸跑直起 TUI"
	if [[ -n "$COMPRESSED_SRC" ]]; then
		echo "variant compressed: $COMPRESSED_MODE"
		echo "  runtime sha256 : $COMP_SHA"
		echo "  放行依据       : $COMPRESSED_WHY"
	else
		echo "variant compressed: NOT SHIPPED (native-only)"
		echo "  原因           : $COMPRESSED_WHY"
		echo "  复跑           : COMPAT_OSCAR_TARGET=<user@host> COMPAT_OSCAR_PORT=8022 make compat-graft-renderer VER=$VER"
	fi
	echo
	echo "gate (pty 5x, rc=124=alive; 139=SIGSEGV):"
	echo "  local  $(uname -r)  hybrid unpacked : $RC_HYB"
	echo "  local  $(uname -r)  hybrid + upx    : $RC_UPX"
	echo "  oldkernel ${OSCAR_KERNEL_SEEN:-<none>}  hybrid + upx : [$OSCAR_RCS]"
	echo
	echo "note: 出货只到本目录（packing/compat/$VER/）。发布分发/推广到其他版本属 T7 与后续决策，"
	echo "      本目标不越界；同版本货架包已原样还原到 packing/ 下。"
	echo
	echo "products:"
	printf '  %s\n' "${DELIVERED[@]}"
} >"$OUT/MANIFEST.txt"

(
	cd "$OUT"
	sha256sum "${DELIVERED[@]}" >SHA256SUMS
)

echo
echo "════ compat-graft-renderer verdict (VER=$VER) ════"
echo "build:      $BUILD_SOURCE (product sha256=$NATIVE_SHA)"
echo "harden:     ok (DT_NEEDED libopencode-crhandler.so)"
echo "graft:      ok — T1 工具等长换位, hybrid sha256=$HYB_SHA (T1 参考 04dfae41…)"
echo "marker:     .grafted (donor=$DONOR_VER target=$VER) 随 native deb/pacman 出货 — 老内核机裸跑直起 TUI"
echo "upx:        $( [[ $UPX_OK == 1 ]] && echo "ok — hybrid ${HYB_SIZE}B -> ${HYB_UPX_SIZE}B (${UPX_RATIO}%)" || echo "FAILED/SKIP — compressed 禁用" )"
echo "compressed: $( [[ -n $COMPRESSED_SRC ]] && echo "出货 — $COMPRESSED_MODE" || echo "不出货（native-only）— $COMPRESSED_WHY" )"
echo "probes:     local[$RC_HYB] local-upx[$RC_UPX] oldkernel[${OSCAR_RCS}] kernel $(uname -r) / ${OSCAR_KERNEL_SEEN:-no-oldkernel-host}"
echo "products:   $OUT/"
while IFS= read -r l; do echo "  $l"; done <"$OUT/SHA256SUMS"
echo "════ end verdict ════"
