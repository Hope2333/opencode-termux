#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# build-splice.sh -- 一键复刻 bionic pty 拼接成品（bun-pty 0.4.11 musl 变体）
#
# 管线（与 2026-10-01/02 oscar+本机验证台实证一致，见 docs/compressed-line.md）:
#   1. 取原件: npm bun-pty@0.4.11 tgz 内 rust-pty/target/release/librust_pty_arm64_musl.so
#      （优先本地 vendor 副本 / OPENCODE_PTY_NPM_TGZ，否则从 registry.npmjs.org 下载；
#       两种来源均校验 sha256）
#   2. 编 shim: Termux clang 把 shim.c 编成 shim.so —— 为 bionic A9 补
#      bcmp / __errno_location / __xpg_strerror_r / posix_spawn*（fork+exec 自管，
#      含 addchdir_np），musl 标志位语义
#   3. 打补丁: patch-dtneeded.py 等长替换 DT_NEEDED "libc.so" -> "shim.so"
#      （单次出现断言 + 补丁前后长度必须相同）
#   4. 产出: dist/librust_pty_arm64_musl_patched.so + dist/shim.so，打印 sha256
#
# 用法: tools/bun-pty-splice/build-splice.sh
# 环境变量:
#   OPENCODE_PTY_NPM_TGZ  预下载的 bun-pty-<ver>.tgz 路径（可选，离线用）
#   BUN_PTY_VER           bun-pty 版本（默认 0.4.11）

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_DIR="$ROOT_DIR/tools/bun-pty-splice"
DIST_DIR="$SRC_DIR/dist"
BUN_PTY_VER="${BUN_PTY_VER:-0.4.11}"

NPM_TGZ_SHA256="e40368cd7bbbd2d40d46a4701f94a8f8d45aba8fdd18a17014c76dc4a7b4dee7"
ORIG_SHA256="34643c78f52295f221891318c4db84300411e05d71ed5a604c3cbb795828e2d8"
# oscar+本机双端 dlopen 验证过的补丁成品（等长补丁是确定性的，必须逐字节复现）
PATCHED_SHA256="1047d3e2b55580918b01256e992817ff46e5a2521c7421fa04235f5799f21a0d"
TARBALL_INNER="package/rust-pty/target/release/librust_pty_arm64_musl.so"

command -v clang >/dev/null 2>&1 || { echo "ERR: 缺少 clang (pkg install clang)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERR: 缺少 python3" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/pty-splice.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ORIG_SO="$WORK/librust_pty_arm64_musl.so"

# --- 1. 原件 ---
VENDOR_SO="$SRC_DIR/vendor/librust_pty_arm64_musl.so"
if [[ -f "$VENDOR_SO" ]]; then
	echo "[1/4] 原件: 本地 vendor 副本 $VENDOR_SO"
	cp "$VENDOR_SO" "$ORIG_SO"
else
	TGZ="${OPENCODE_PTY_NPM_TGZ:-$WORK/bun-pty-$BUN_PTY_VER.tgz}"
	if [[ ! -f "$TGZ" ]]; then
		echo "[1/4] 原件: 下载 bun-pty@$BUN_PTY_VER (npm registry)"
		curl -fsSL -o "$TGZ" "https://registry.npmjs.org/bun-pty/-/bun-pty-$BUN_PTY_VER.tgz"
	fi
	echo "$NPM_TGZ_SHA256  $TGZ" | sha256sum -c - >/dev/null \
		|| { echo "ERR: tgz sha256 不匹配（期望 $NPM_TGZ_SHA256）" >&2; exit 1; }
	tar xzf "$TGZ" -C "$WORK" "$TARBALL_INNER"
	mv "$WORK/$TARBALL_INNER" "$ORIG_SO"
fi
echo "$ORIG_SHA256  $ORIG_SO" | sha256sum -c - >/dev/null \
	|| { echo "ERR: 原件 sha256 不匹配（期望 $ORIG_SHA256）" >&2; exit 1; }

# --- 2. shim ---
echo "[2/4] 编译 shim.so (Termux clang, bionic)"
clang -O2 -fPIC -shared "$SRC_DIR/shim.c" -o "$WORK/shim.so"

# --- 3. DT_NEEDED 等长补丁 ---
echo "[3/4] DT_NEEDED 等长补丁 libc.so -> shim.so"
python3 "$SRC_DIR/patch-dtneeded.py" "$ORIG_SO" "$WORK/librust_pty_arm64_musl_patched.so"

# --- 4. 产出 ---
mkdir -p "$DIST_DIR"
install -m755 "$WORK/librust_pty_arm64_musl_patched.so" "$DIST_DIR/"
install -m755 "$WORK/shim.so" "$DIST_DIR/"
echo "[4/4] 产物校验"
ORIG_SZ=$(stat -c%s "$ORIG_SO")
PATCHED_SZ=$(stat -c%s "$DIST_DIR/librust_pty_arm64_musl_patched.so")
[[ "$ORIG_SZ" == "$PATCHED_SZ" ]] || { echo "ERR: 补丁前后长度不同 ($ORIG_SZ vs $PATCHED_SZ)" >&2; exit 1; }
echo "$PATCHED_SHA256  $DIST_DIR/librust_pty_arm64_musl_patched.so" | sha256sum -c - \
	|| { echo "ERR: 补丁成品 sha256 与验证台基准不符（补丁应为确定性逐字节复现）" >&2; exit 1; }

echo
echo "OK: 产物在 $DIST_DIR"
sha256sum "$DIST_DIR/librust_pty_arm64_musl_patched.so" "$DIST_DIR/shim.so"
echo "orig: $ORIG_SZ bytes -> patched: $PATCHED_SZ bytes (equal-length)"
echo "部署路径契约: <prefix>/lib/opencode1/pty/{librust_pty_arm64_musl_patched.so,shim.so}"
echo "              launcher 检测到该文件即注入 BUN_PTY_LIB（向后兼容：缺省不注入）"
