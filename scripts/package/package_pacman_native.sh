#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode-native pacman provider (transplant revival line).
#
# Provides the `opencode` command from artifacts/transplant/<ver>/opencode-native-revived.
# Stable mainline provider; conflicts with the glibc appendix package (`opencode-wrapper`);
# conflicts with it (installing one replaces the other).
# Native constraints: zero glibc deps, Android API >= 28, full TUI (stable mainline since 27/28).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGER_NAME="${PACKAGER_NAME:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
PKGREL="${PKGREL:-1}"
TRANSPLANT_ROOT="${TRANSPLANT_ROOT:-$ROOT_DIR/artifacts/transplant}"

command -v makepkg >/dev/null 2>&1 || {
	echo "Error: makepkg not found" >&2
	exit 1
}

# Version: explicit VERSION wins, else resolve the single transplant build.
if [[ -z "${VERSION:-}" ]]; then
	shopt -s nullglob
	_builds=("$TRANSPLANT_ROOT"/*)
	shopt -u nullglob
	if [[ ${#_builds[@]} -eq 0 ]]; then
		echo "Error: no transplant builds under $TRANSPLANT_ROOT (run: make transplant VER=<x>)" >&2
		exit 1
	fi
	if [[ ${#_builds[@]} -gt 1 ]]; then
		echo "Error: multiple transplant builds found; set VERSION=<x> explicitly:" >&2
		printf '  %s\n' "${_builds[@]}" >&2
		exit 1
	fi
	VERSION="$(basename "${_builds[0]}")"
fi

# v1 (1.x) packages are renamed opencode1 (coexist with v2); v2 keeps `opencode`.
case "$VERSION" in
	1.*) PKG_NAME="opencode1" ;;
	*)   PKG_NAME="opencode" ;;
esac

# hook_enabled NAME DEFAULT-GLOB — packaging hook registry resolver (Makefile:
# HOOKS_ENABLE / HOOKS_DISABLE / HOOK_*_VERSIONS). HOOKS_DISABLE wins over
# HOOKS_ENABLE; otherwise the hook's default version-glob decides.
hook_enabled() {
	case " ${HOOKS_DISABLE:-} " in *" $1 "*) return 1 ;; esac
	case " ${HOOKS_ENABLE:-} " in *" $1 "*) return 0 ;; esac
	case "${VERSION:-}" in $2) return 0 ;; *) return 1 ;; esac
}
# task-tui-common-fix: prefer opencode-native-tui (post-TUI-swap product,
# seccomp-hardened) with revived as fallback; OPENCODE_NATIVE_BIN still wins.
NATIVE_BIN="${OPENCODE_NATIVE_BIN:-$TRANSPLANT_ROOT/$VERSION/opencode-native-tui}"
[[ -x "$NATIVE_BIN" ]] || NATIVE_BIN="$TRANSPLANT_ROOT/$VERSION/opencode-native-revived"
[[ -x "$NATIVE_BIN" ]] || {
	echo "Error: missing native runtime $NATIVE_BIN (run: make transplant VER=$VERSION)" >&2
	exit 1
}

cd "$ROOT_DIR/packing/pacman"
rm -rf "$ROOT_DIR/packing/pacman/pkg" "$ROOT_DIR/packing/pacman/src"

TMP_MAKEPKG_CONF="$ROOT_DIR/packing/pacman/.makepkg-opencode-native.conf"
TMP_PKGBUILD="$ROOT_DIR/packing/pacman/.PKGBUILD.opencode-native.tmp"
cleanup() {
	rm -f "$TMP_MAKEPKG_CONF" "$TMP_PKGBUILD"
}
trap cleanup EXIT

cp /data/data/com.termux/files/usr/etc/makepkg.conf "$TMP_MAKEPKG_CONF"
printf "\nPACKAGER=%q\n" "$PACKAGER_NAME" >>"$TMP_MAKEPKG_CONF"

cp "$ROOT_DIR/packing/pacman/PKGBUILD.native" "$TMP_PKGBUILD"
sed -i "s/^pkgver=.*/pkgver=$VERSION/" "$TMP_PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=$PKGREL/" "$TMP_PKGBUILD"
sed -i "s/^pkgname=.*/pkgname=$PKG_NAME/" "$TMP_PKGBUILD"

# v1 (opencode1) upgrade chain: old v1 opencode (<2.0.0) upgrades into this family
if [[ "$PKG_NAME" == "opencode1" ]]; then
    sed -i "s/^replaces=.*/replaces=('opencode<2.0.0' 'opencode-compressed<2.0.0')/" "$TMP_PKGBUILD"
    sed -i "s/^conflicts=.*/conflicts=('opencode<2.0.0' 'opencode1-compressed' 'opencode1-wrapper' 'opencode1-wrapper-standalone')/" "$TMP_PKGBUILD"
    OPENCODE_BIN_NAME="opencode1"
else
    sed -i "s/^replaces=.*/replaces=()/" "$TMP_PKGBUILD"
    sed -i "s/^conflicts=.*/conflicts=()/" "$TMP_PKGBUILD"
    OPENCODE_BIN_NAME="opencode"
fi

# v12.0: write the install script (.INSTALL) consumed by makepkg's install= var.
cat > "$ROOT_DIR/packing/pacman/opencode.install" <<'OINST'
# v12.0: pacman-side install hook, mirroring deb postinst (package_deb_native.sh).
# $PKG_NAME is injected as an env var into makepkg; post_install reads it to tell
# v1 (opencode1) from v2 (opencode) installs and run the data migration exactly once.
post_install() {
    echo ""
    if [ "$PKG_NAME" = "opencode1" ]; then
        echo "OpenCode1 (v1 family) installed - coexists with v2 opencode."
        CFG_DIR="$(printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode")"
        # Feature detection FIRST (v12.2): `check` prints the detected state
        # and exits 0 when every skip condition is met — only then does
        # isolate run, and unsilenced so the operator sees every action.
        if { [ -e "$CFG_DIR" ] || [ -d "${CFG_DIR}1" ]; } && command -v migrate-to-opencode1.sh >/dev/null 2>&1; then
            if migrate-to-opencode1.sh check; then
                echo "Feature check: nothing to migrate — skipped (already isolated / no v1-era data / plugins clean)."
            elif migrate-to-opencode1.sh isolate; then
                echo "Migrated: v1 config now under opencode1/opencode (nested), plugins auto-patched (see detected-state above)."
            else
                echo "Migration not completed (see detected-state above); data left untouched."
            fi
        else
            echo "No legacy v1 config found (or already isolated); nothing to migrate."
        fi
    else
        echo "OpenCode v2 (mainline) installed - coexists with v1 opencode1."
        echo "Usage: opencode --version"
    fi
}

post_upgrade() {
    post_install
}
OINST

# v12.0 bake: .INSTALL runs at pacman-install time where $PKG_NAME does NOT
# exist (makepkg env injection is build-time only) — replace the runtime
# test with the build-time literal so each family package prints its own
# branch unconditionally.
sed -i "s/if \[ \"\$PKG_NAME\" = \"opencode1\"/if [ \"$PKG_NAME\" = \"opencode1\"/" "$ROOT_DIR/packing/pacman/opencode.install"
grep -qF "if [ \"$PKG_NAME\" = \"opencode1\"" "$ROOT_DIR/packing/pacman/opencode.install" || {
    echo "Error: .INSTALL PKG_NAME bake failed" >&2; exit 1; }

# stale-serve-kill hook (issue #17): gated by the packaging hook registry —
# default scope v2 native 2.0.[0-3] only; HOOKS_ENABLE / HOOKS_DISABLE override.
if hook_enabled stale-serve-kill "2.0.[0-3]"; then
  cat >> "$ROOT_DIR/packing/pacman/opencode.install" <<'OINST_HOOK'
# stale-serve-kill (issue #17): an upgrade replaces the binary while an old
# `serve` daemon may still hold the background-service socket -> the new TUI
# times out waiting for it. Kill only THIS package binary's serve processes.
stop_stale_serve() {
    if [ "$PKG_NAME" = "opencode1" ]; then
        SRV="$PREFIX/lib/opencode1/runtime/opencode"
    else
        SRV="$PREFIX/bin/opencode"
    fi
    pkill -f "^$SRV( |$)" 2>/dev/null && echo "Stopped stale serve processes (pre-upgrade instances)." || true
}
OINST_HOOK
  sed -i 's/^post_install() {/post_install() {\n    stop_stale_serve/' "$ROOT_DIR/packing/pacman/opencode.install"
  grep -q 'stop_stale_serve' "$ROOT_DIR/packing/pacman/opencode.install" || {
    echo "Error: .INSTALL stale-serve-kill bake failed" >&2; exit 1; }
fi

# stale-runtime-quarantine: conservative rename-backup of an unowned, same-arch
# stale runtime at $PREFIX/lib/opencode/runtime/opencode (pre-v12.1 v1-era
# leftover). NEVER rm user files; the owner decides deletion.
cat >> "$ROOT_DIR/packing/pacman/opencode.install" <<'OINST_STALE'
quarantine_stale_runtime() {
    STALE="$PREFIX/lib/opencode/runtime/opencode"
    [ -f "$STALE" ] || return 0
    command -v file >/dev/null 2>&1 || return 0
    pacman -Qo "$STALE" >/dev/null 2>&1 && return 0
    case "$(file -b "$STALE")" in
        *ELF*aarch64*|*aarch64*ELF*)
            BAK="$STALE.stale-$(date +%Y%m%d)"
            if mv -n "$STALE" "$BAK" 2>/dev/null && [ ! -f "$STALE" ]; then
                echo "Quarantined unowned stale runtime: $STALE -> $BAK"
                echo "(no pacman package owns it; delete manually if unneeded)"
            fi
            ;;
    esac
}
OINST_STALE
sed -i 's/^post_install() {/post_install() {\n    quarantine_stale_runtime/' "$ROOT_DIR/packing/pacman/opencode.install"
grep -q 'quarantine_stale_runtime' "$ROOT_DIR/packing/pacman/opencode.install" || {
    echo "Error: .INSTALL stale-runtime-quarantine bake failed" >&2; exit 1; }

PKG_NAME="$PKG_NAME" OPENCODE_NATIVE_BIN="$NATIVE_BIN" OPENCODE_BIN_NAME="$OPENCODE_BIN_NAME" REPO_ROOT="$ROOT_DIR" makepkg --config "$TMP_MAKEPKG_CONF" -f --noconfirm -p "$TMP_PKGBUILD"

echo "Native pacman package created under: $ROOT_DIR/packing/pacman"
rm -f "$ROOT_DIR/packing/pacman/opencode.install"

# --- Convention guard (phase0 reversal): packages MUST use the absolute member
# convention data/data/com.termux/files/usr/... — relative usr/ members resolve
# to /usr on a standard termux-pacman machine (RootDir=/) and the transaction
# fails with "Partition / is mounted read only".
BUILT_PKG=$(ls "$ROOT_DIR/packing/pacman/${PKG_NAME}-${VERSION}-${PKGREL}-aarch64.pkg.tar.xz" 2>/dev/null || true)
if [[ -n "$BUILT_PKG" ]]; then
    REL_PAYLOAD=$(bsdtar -tf "$BUILT_PKG" | grep -E '^usr/' | head -1 || true)
    if [[ -n "$REL_PAYLOAD" ]]; then
        echo "FATAL: convention guard triggered — found relative usr/ member: $REL_PAYLOAD" >&2
        echo "Ensure PKGBUILD stages to \$pkgdir/data/data/com.termux/files/usr/ (absolute convention), not \$pkgdir/usr/." >&2
        exit 1
    fi
    ABS_PAYLOAD=$(bsdtar -tf "$BUILT_PKG" | grep -E '^data/data/com.termux/files/usr/' | head -1 || true)
    if [[ -z "$ABS_PAYLOAD" ]]; then
        echo "FATAL: convention guard triggered — no data/data/com.termux/files/usr/ members found" >&2
        exit 1
    fi
    echo "Convention guard: OK (absolute data/data/com.termux/files/usr/ members, no relative usr/)"
fi
