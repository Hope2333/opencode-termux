#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode DEB provider (transplant revival line, native mainline).
#
# This package IS the plain `opencode` name (inherited by the native mainline
# per the 27/28 package-rename decision). Built from
# artifacts/transplant/<ver>/opencode-native-revived; conflicts with the glibc
# appendix package (opencode-wrapper) and the compressed transitional package
# (opencode-compressed): installing one replaces the other.
#
# Native line constraints (documented in the package description):
#   - zero glibc runtime dependencies (pure Bionic)
#   - requires Android API >= 28
#   - full TUI via bionic libopentui.so (W10a deep smoke 5/5); zero glibc runtime deps

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
MAINTAINER="${MAINTAINER:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
TRANSPLANT_ROOT="${TRANSPLANT_ROOT:-$ROOT_DIR/artifacts/transplant}"

command -v dpkg-deb >/dev/null 2>&1 || {
	echo "Error: dpkg-deb not found" >&2
	exit 1
}
if [[ -z "${ARCH_DEB:-}" ]]; then
	ARCH_DEB="$(dpkg --print-architecture 2>/dev/null || echo aarch64)"
fi

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
# task-tui-common-fix: prefer opencode-native-tui (post-TUI-swap product,
# seccomp-hardened by seccomp-harden) with revived as fallback.
NATIVE_BIN="$TRANSPLANT_ROOT/$VERSION/opencode-native-tui"
[[ -x "$NATIVE_BIN" ]] || NATIVE_BIN="$TRANSPLANT_ROOT/$VERSION/opencode-native-revived"
[[ -x "$NATIVE_BIN" ]] || {
	echo "Error: missing native runtime $NATIVE_BIN (run: make transplant VER=$VERSION)" >&2
	exit 1
}

# v1 (1.x) packages are renamed opencode1 (coexist with v2); v2 keeps `opencode`.
case "$VERSION" in
	1.*) PKG_NAME="opencode1"; PKG_CONFLICTS="opencode1-wrapper, opencode1-compressed, opencode1-wrapper-standalone"; PKG_REPLACES="opencode (<< 2.0.0)" ;;
	*)   PKG_NAME="opencode";  PKG_CONFLICTS="opencode-wrapper"; PKG_REPLACES="" ;;
esac

# hook_enabled NAME DEFAULT-GLOB — packaging hook registry resolver (Makefile:
# HOOKS_ENABLE / HOOKS_DISABLE / HOOK_*_VERSIONS). HOOKS_DISABLE wins over
# HOOKS_ENABLE; otherwise the hook's default version-glob decides.
hook_enabled() {
	case " ${HOOKS_DISABLE:-} " in *" $1 "*) return 1 ;; esac
	case " ${HOOKS_ENABLE:-} " in *" $1 "*) return 0 ;; esac
	case "${VERSION:-}" in $2) return 0 ;; *) return 1 ;; esac
}

DEB_ROOT="$ROOT_DIR/packing/dpkg-native/work"
OUT_DIR="$ROOT_DIR/packing/dpkg-native"
OUT_FILE="$OUT_DIR/${PKG_NAME}_${VERSION}_${ARCH_DEB}.deb"

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX/bin" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"

if [[ "$VERSION" == 1.* ]]; then BIN_NAME="opencode1"; LIB_DIR="opencode1"; else BIN_NAME="opencode"; LIB_DIR="opencode"; fi
[[ -f "$ROOT_DIR/scripts/opencode1-launcher.sh" ]] || {
	echo "Error: scripts/opencode1-launcher.sh missing (v1 launcher source)" >&2; exit 1; }
if [[ "$VERSION" == 1.* ]]; then
	# v12.1: v1 layered — bare runtime under lib/opencode1/runtime/ (DT_RUNPATH
	# $ORIGIN/../lib/opencode resolved via the launcher's LD_LIBRARY_PATH) +
	# the XDG-isolating launcher at bin/opencode1. v2 stays bin-direct.
	install -D -m755 "$NATIVE_BIN" "$DEB_ROOT$PREFIX/lib/opencode1/runtime/opencode"
	install -D -m755 "$ROOT_DIR/scripts/opencode1-launcher.sh" "$DEB_ROOT$PREFIX/bin/opencode1"
else
	install -m755 "$NATIVE_BIN" "$DEB_ROOT$PREFIX/bin/$BIN_NAME"
fi
# v12.0: the postinst migration branch needs migrate-to-opencode1.sh on the
# user's PATH — ship it alongside (v1 packages only; v2 branch never calls it).
if [[ "$VERSION" == 1.* ]]; then
	install -m755 "$ROOT_DIR/scripts/migrate-to-opencode1.sh" "$DEB_ROOT$PREFIX/bin/migrate-to-opencode1.sh"
	echo "Packaged migrate-to-opencode1.sh (v1 migration helper)"
fi

# W11: ship the self-activating seccomp shim when the binary references it
# (DT_NEEDED libopencode-crhandler.so). It must land in $PREFIX/lib/opencode/
# to satisfy the binary's DT_RUNPATH $ORIGIN/../lib/opencode.
if grep -aqF libopencode-crhandler.so "$NATIVE_BIN"; then
	SHIM_SO="$(dirname "$NATIVE_BIN")/libopencode-crhandler.so"
	if [[ ! -f "$SHIM_SO" ]]; then
		echo "Error: hardened binary references libopencode-crhandler.so but $SHIM_SO is missing" >&2
		echo "       (run: make seccomp-harden VER=$VERSION)" >&2
		exit 1
	fi
	# shim dir is pinned to lib/opencode (the binary's DT_RUNPATH
	# $ORIGIN/../lib/opencode) — renaming the dir with the opencode1
	# package rename broke CANNOT LINK for any hardened v1 build (#23-adjacent).
	mkdir -p "$DEB_ROOT$PREFIX/lib/opencode"
	install -m644 "$SHIM_SO" "$DEB_ROOT$PREFIX/lib/opencode/libopencode-crhandler.so"
	echo "Packaging seccomp shim: $SHIM_SO -> $PREFIX/lib/opencode/"
else
	echo "Note: binary is not seccomp-hardened; shipping without libopencode-crhandler.so"
fi

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION${DEB_REV:-}
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Section: utils
Priority: optional
Depends:
Conflicts: $PKG_CONFLICTS
Replaces: opencode1-wrapper-standalone${PKG_REPLACES:+, $PKG_REPLACES}
Description: OpenCode native bionic mainline (stable since 27/28). Full TUI via bionic libopentui.so (W10a deep smoke 5/5). Zero glibc dependencies.
EOF

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
POSTINST
# stale-serve-kill hook (issue #17): gated by the packaging hook registry —
# default scope v2 native 2.0.[0-3] only; HOOKS_ENABLE / HOOKS_DISABLE override.
if hook_enabled stale-serve-kill "2.0.[0-3]"; then
  cat >>"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST_HOOK'
# Stale-service cleanup: an upgrade replaces the binary while an old `serve`
# daemon may still hold the background-service socket -> the new TUI times
# out waiting for it. Kill only THIS package binary's serve processes; the
# other generation's runtime path differs and is never matched.
P="$(printf '%s' "${DPKG_MAINTSCRIPT_PACKAGE:-}")"
case "$P" in
  opencode)  SRV="$PREFIX/bin/opencode" ;;
  opencode1) SRV="$PREFIX/lib/opencode1/runtime/opencode" ;;
  *)         SRV="" ;;
esac
if [ -n "$SRV" ] && pgrep -f "^$SRV( |$)" >/dev/null 2>&1; then
  pkill -f "^$SRV( |$)" 2>/dev/null || true
  echo "Stopped stale $(basename "$SRV") serve processes (pre-upgrade instances)."
fi
POSTINST_HOOK
fi
cat >>"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
# stale-runtime-quarantine: $PREFIX/lib/opencode/runtime/opencode may be a
# pre-v12.1 v1-era leftover (e.g. a June 1.17.9) that no current package owns.
# Conservative rename-backup ONLY if all hold: file exists, unowned
# (dpkg -S finds no package), and same-arch (aarch64 ELF) as this runtime.
# NEVER rm user files; the owner (user) decides deletion.
STALE="$PREFIX/lib/opencode/runtime/opencode"
if [ -f "$STALE" ] && command -v file >/dev/null 2>&1; then
  if ! dpkg -S "$STALE" >/dev/null 2>&1; then
    case "$(file -b "$STALE")" in
      *ELF*aarch64*|*aarch64*ELF*)
        BAK="$STALE.stale-$(date +%Y%m%d)"
        if mv -n "$STALE" "$BAK" 2>/dev/null && [ ! -f "$STALE" ]; then
          echo "Quarantined unowned stale runtime: $STALE -> $BAK"
          echo "(no dpkg package owns it; delete manually if unneeded)"
        fi
        ;;
    esac
  fi
fi

# v1 (opencode1) or v2 (opencode) install hook.
# v1: auto-migrate any pre-v2-era config under ~/.config/opencode (etc.) into
#     the opencode1-isolated dirs, exactly once, never clobbering existing
#     opencode1 data. Requires scripts/migrate-to-opencode1.sh to be on PATH.
CFG_DIR="$(printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode")"
case "${PKG_NAME:-$DPKG_MAINTSCRIPT_PACKAGE}" in
  opencode1)
    echo "OpenCode1 (v1 family) installed — coexists with v2 opencode."
    # Feature detection FIRST (v12.2): `check` prints the detected state and
    # exits 0 when every skip condition is met — only then does isolate run,
    # and unsilenced so the operator sees detected-state and every action.
    if { [ -e "$CFG_DIR" ] || [ -d "${CFG_DIR}1" ]; } && command -v migrate-to-opencode1.sh >/dev/null 2>&1; then
      if migrate-to-opencode1.sh check; then
        echo "Feature check: nothing to migrate — skipped (already isolated / no v1-era data / plugins clean)."
      elif migrate-to-opencode1.sh isolate; then
        echo "Migrated: v1 config now under opencode1/opencode (nested), plugins auto-patched (see detected-state above)."
      else
        echo "Migration not completed (see detected-state above); data left untouched."
        # v2 guard may have blocked the plain->nested move. If v1-era leftovers
        # still live at the plain roots, surface the explicit recovery path.
        if { [ -f "${HOME}/.local/share/opencode/opencode.db" ] || [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/opencode" ]; } \
           && [ ! -e "${HOME}/.local/share/opencode1/opencode/opencode.db" ] \
           && command -v migrate-to-opencode1.sh >/dev/null 2>&1; then
          echo "NOTE: v1-era data still at the plain opencode/ roots and the opencode1"
          echo "      nested roots are empty. If those plain dirs hold v1 leftovers you"
          echo "      want opencode1 to see, run:  migrate-to-opencode1.sh isolate --take-plain"
          echo "      (skipped automatically because a v2 opencode package is installed)."
        fi
      fi
    else
      echo "No legacy v1 config found (or already isolated); nothing to migrate."
    fi
    ;;
  opencode)
    echo "OpenCode v2 (mainline) installed — coexists with v1 opencode1."
    ;;
esac
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "Native DEB package created: $OUT_FILE"
