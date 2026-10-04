#!/data/data/com.termux/files/usr/bin/bash
# scripts/package/package_pacman_standalone.sh — build the opencode-wrapper-standalone pacman package
# Pure-addition standalone package: frozen single version for rollback only.
# Coexists with `opencode` (native) and `opencode-wrapper` (no Conflicts on the
# literal name `opencode`). Uses PKGBUILD.standalone.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix-standalone}"
PACKAGER_NAME="${PACKAGER_NAME:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
PKGREL="${PKGREL:-1}"

# Standalone staged prefix must use the independent lib prefix.
[[ -x "$STAGED_PREFIX/lib/opencode-wrapper/runtime/opencode" ]] || {
	echo "Error: missing OpenCode standalone runtime" >&2
	exit 1
}
[[ -x "$STAGED_PREFIX/bin/opencode-wrapper" ]] || {
	echo "Error: missing standalone staged launcher" >&2
	exit 1
}

# Version: use explicit VERSION if set, else read from runtime
if [[ -z "${VERSION:-}" ]]; then
	if ! VERSION="$("$STAGED_PREFIX/lib/opencode-wrapper/runtime/opencode" --version)"; then
		echo "Error: staged runtime version check failed" >&2
		exit 1
	fi
fi
[[ -n "$VERSION" ]] || {
	echo "Error: unable to determine version" >&2
	exit 1
}

cd "$ROOT_DIR/packing/pacman"
rm -rf "$ROOT_DIR/packing/pacman/pkg" "$ROOT_DIR/packing/pacman/src"

TMP_MAKEPKG_CONF="$ROOT_DIR/packing/pacman/.makepkg-opencode-standalone.conf"
TMP_PKGBUILD="$ROOT_DIR/packing/pacman/.PKGBUILD.standalone.tmp"
cleanup() {
	rm -f "$TMP_MAKEPKG_CONF" "$TMP_PKGBUILD"
}
trap cleanup EXIT

cp /data/data/com.termux/files/usr/etc/makepkg.conf "$TMP_MAKEPKG_CONF"
printf "\nPACKAGER=%q\n" "$PACKAGER_NAME" >>"$TMP_MAKEPKG_CONF"

cp "$ROOT_DIR/packing/pacman/PKGBUILD.standalone" "$TMP_PKGBUILD"
sed -i "s/^pkgver=.*/pkgver=$VERSION/" "$TMP_PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=$PKGREL/" "$TMP_PKGBUILD"

STAGED_PREFIX="$STAGED_PREFIX" REPO_ROOT="$ROOT_DIR" makepkg --config "$TMP_MAKEPKG_CONF" -f --noconfirm -p "$TMP_PKGBUILD"

echo "Pacman package created under: $ROOT_DIR/packing/pacman"

# --- Convention guard (phase0 reversal): packages MUST use the absolute member
# convention data/data/com.termux/files/usr/... — relative usr/ members resolve
# to /usr on a standard termux-pacman machine (RootDir=/) and the transaction
# fails with "Partition / is mounted read only".
BUILT_PKG=$(ls "$ROOT_DIR/packing/pacman/"*-standalone-* 2>/dev/null || ls "$ROOT_DIR/packing/pacman/"*-compressed-* 2>/dev/null || true)
if [[ -n "$BUILT_PKG" ]]; then
    REL_PAYLOAD=$(bsdtar -tf "$BUILT_PKG" | grep -E '^usr/(bin|lib)/' | head -1 || true)
    if [[ -n "$REL_PAYLOAD" ]]; then
        echo "FATAL: convention guard triggered — found relative usr/ member: $REL_PAYLOAD" >&2
        echo "Ensure PKGBUILD stages to \$pkgdir/data/data/com.termux/files/usr/ (absolute convention), not \$pkgdir/usr/." >&2
        exit 1
    fi
    ABS_PAYLOAD=$(bsdtar -tf "$BUILT_PKG" | grep -E '^data/data/com.termux/files/usr/(bin|lib)/' | head -1 || true)
    if [[ -z "$ABS_PAYLOAD" ]]; then
        echo "FATAL: convention guard triggered — no data/data/com.termux/files/usr/ members found" >&2
        exit 1
    fi
    # B1 payload gate (ISSUS@001): launcher + non-empty runtime must both
    # ship, and no doubled directory (bin/bin, lib/lib, share/share).
    PAYLOAD_LIST=$(bsdtar -tf "$BUILT_PKG")
    grep -qx 'data/data/com.termux/files/usr/bin/opencode-wrapper' <<<"$PAYLOAD_LIST" || {
        echo "FATAL: package payload missing data/data/com.termux/files/usr/bin/opencode-wrapper launcher" >&2
        echo "$PAYLOAD_LIST" >&2
        exit 1
    }
    RT_SIZE=$(bsdtar -tvf "$BUILT_PKG" data/data/com.termux/files/usr/lib/opencode-wrapper/runtime/opencode 2>/dev/null | awk '{print $5}')
    [[ -n "$RT_SIZE" && "$RT_SIZE" -gt 0 ]] || {
        echo "FATAL: package payload missing/empty data/data/com.termux/files/usr/lib/opencode-wrapper/runtime/opencode" >&2
        echo "$PAYLOAD_LIST" >&2
        exit 1
    }
    NESTED=$(echo "$PAYLOAD_LIST" | grep -E '(^|/)(bin/bin|lib/lib|share/share)/' | head -1 || true)
    if [[ -n "$NESTED" ]]; then
        echo "FATAL: regression guard triggered — nested doubled directory in payload: $NESTED" >&2
        exit 1
    fi
    echo "Convention guard: OK (absolute members, launcher + runtime present, no relative usr/ or doubled dirs)"
fi
