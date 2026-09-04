#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Rebuild 26 pacman packages from existing deb payloads with fixed PKGBUILDs.
# Native: packing/dpkg-native/opencode_<V>_aarch64.deb → extract bin/opencode + crhandler
# Glibc: packing/dpkg/opencode-glibc_<V>_aarch64.deb → extract staged prefix tree
# KEY FIX: $pkgdir/usr/ (relative) not $pkgdir$prefix (absolute) → no double prefix.
#
# NOTE: Termux makepkg creates empty data/data/com.termux/files/ directory stubs
# (terdir) inside every package. These are harmless. Verification checks that
# usr/bin/opencode exists and no actual PAYLOAD files (bin/lib) exist under data/.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGER_NAME="${PACKAGER_NAME:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
PKGREL="${PKGREL:-1}"
WORKDIR="$ROOT_DIR/artifacts/rebuild-work"
LOGFILE="${LOGFILE:-$ROOT_DIR/.omo/evidence/task-pkgbuild-prefix-fix.log}"
VERSIONS=(1.18.15 1.18.16 1.18.17 1.18.18 1.18.19 1.18.20 1.18.21 1.18.22 1.18.23 1.18.24 1.18.25 1.18.26 1.18.27)

N_PASS=0; N_FAIL=0; G_PASS=0; G_FAIL=0

log() { echo "$@" | tee -a "$LOGFILE"; }
mkdir -p "$WORKDIR" "$(dirname "$LOGFILE")"

TMP_MAKEPKG_CONF="$WORKDIR/.makepkg.conf"
cp /data/data/com.termux/files/usr/etc/makepkg.conf "$TMP_MAKEPKG_CONF"
printf "\nPACKAGER=%q\n" "$PACKAGER_NAME" >>"$TMP_MAKEPKG_CONF"

# Helper: run makepkg from a temp build dir with PKGBUILD in CWD
run_makepkg() {
    local bld="$1" src="$2" ver="$3"; shift 3
    rm -rf "$bld"; mkdir -p "$bld"
    sed -e "s/^pkgver=.*/pkgver=$ver/" -e "s/^pkgrel=.*/pkgrel=$PKGREL/" "$src" > "$bld/PKGBUILD"
    (cd "$bld" && env "$@" makepkg --config "$TMP_MAKEPKG_CONF" -f --noconfirm 2>&1)
}

# Helper: verify package has usr/bin/opencode (and no data/ payload files)
verify_pkg() {
    local pkg="$1" expected_name="$2"
    if [[ ! -f "$pkg" ]]; then echo "NO_OUTPUT"; return 1; fi
    local usr_count data_payload
    usr_count=$(bsdtar -tf "$pkg" | grep -c "^usr/bin/${expected_name}$" || true)
    data_payload=$(bsdtar -tf "$pkg" | grep -E '^data/.*/(bin|lib)/' | head -1 || true)
    if [[ "$usr_count" -ge 1 && -z "$data_payload" ]]; then
        echo "OK"; return 0
    else
        echo "BAD usr=$usr_count data=$data_payload"; return 1
    fi
}

# ==================== NATIVE REBUILD ====================
log ""
log "=== PHASE: NATIVE REBUILD ($(date)) ==="
NATIVE_TEMPLATE="$ROOT_DIR/packing/pacman/PKGBUILD.native"

for V in "${VERSIONS[@]}"; do
    DEB="$ROOT_DIR/packing/dpkg-native/opencode_${V}_aarch64.deb"
    STAGE="$WORKDIR/n-$V"
    [[ ! -f "$DEB" ]] && { log "N${V}-SKIP deb not found"; continue; }
    log -n "N${V} extract... "
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    dpkg-deb -x "$DEB" "$STAGE" 2>/dev/null
    PAYLOAD="$STAGE/data/data/com.termux/files/usr"
    [[ ! -f "$PAYLOAD/bin/opencode" ]] && { log "FAIL missing bin/opencode"; ((N_FAIL++)) || true; continue; }
    ARTIFACT_DIR="$STAGE/artifact"; mkdir -p "$ARTIFACT_DIR"
    cp "$PAYLOAD/bin/opencode" "$ARTIFACT_DIR/opencode-native-revived"; chmod 755 "$ARTIFACT_DIR/opencode-native-revived"
    [[ -f "$PAYLOAD/lib/opencode/libopencode-crhandler.so" ]] && { cp "$PAYLOAD/lib/opencode/libopencode-crhandler.so" "$ARTIFACT_DIR/"; log -n "crhandler ok... "; }

    BLD="$WORKDIR/bld-n-$V"
    if run_makepkg "$BLD" "$NATIVE_TEMPLATE" "$V" \
       "OPENCODE_NATIVE_BIN=$ARTIFACT_DIR/opencode-native-revived" "REPO_ROOT=$ROOT_DIR" >/dev/null 2>&1; then
        OUTPKG=$(ls "$BLD/opencode-${V}-${PKGREL}-aarch64.pkg.tar.xz" 2>/dev/null || true)
        RESULT=$(verify_pkg "$OUTPKG" "opencode" 2>/dev/null || true)
        if [[ "$RESULT" == "OK" ]]; then
            mv "$OUTPKG" "$ROOT_DIR/packing/pacman/"
            log "N${V}-OK"
            ((N_PASS++)) || true
        else
            log "N${V}-FAIL $RESULT"; ((N_FAIL++)) || true
        fi
    else
        log "N${V}-FAIL makepkg failed"; ((N_FAIL++)) || true
    fi
    rm -rf "$STAGE" "$BLD"
done

# ==================== GLIBC REBUILD ====================
log ""
log "=== PHASE: GLIBC REBUILD ($(date)) ==="
GLIBC_TEMPLATE="$ROOT_DIR/packing/pacman/PKGBUILD"

for V in "${VERSIONS[@]}"; do
    DEB="$ROOT_DIR/packing/dpkg/opencode-glibc_${V}_aarch64.deb"
    STAGE="$WORKDIR/g-$V"
    [[ ! -f "$DEB" ]] && { log "G${V}-SKIP deb not found"; continue; }
    log -n "G${V} extract... "
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    dpkg-deb -x "$DEB" "$STAGE" 2>/dev/null
    PAYLOAD="$STAGE/data/data/com.termux/files/usr"
    STAGED_PREFIX="$STAGE/staged"
    [[ ! -f "$PAYLOAD/bin/opencode" ]] && { log "FAIL missing bin/opencode"; ((G_FAIL++)) || true; continue; }
    mkdir -p "$STAGED_PREFIX"; cp -a "$PAYLOAD/." "$STAGED_PREFIX/"

    BLD="$WORKDIR/bld-g-$V"
    if run_makepkg "$BLD" "$GLIBC_TEMPLATE" "$V" \
       "STAGED_PREFIX=$STAGED_PREFIX" "REPO_ROOT=$ROOT_DIR" >/dev/null 2>&1; then
        OUTPKG=$(ls "$BLD/opencode-glibc-${V}-${PKGREL}-aarch64.pkg.tar.xz" 2>/dev/null || true)
        RESULT=$(verify_pkg "$OUTPKG" "opencode" 2>/dev/null || true)
        if [[ "$RESULT" == "OK" ]]; then
            mv "$OUTPKG" "$ROOT_DIR/packing/pacman/"
            log "G${V}-OK"
            ((G_PASS++)) || true
        else
            log "G${V}-FAIL $RESULT"; ((G_FAIL++)) || true
        fi
    else
        log "G${V}-FAIL makepkg failed"; ((G_FAIL++)) || true
    fi
    rm -rf "$STAGE" "$BLD"
done

# ==================== SUMMARY ====================
log ""
log "=== REBUILD SUMMARY ==="
log "Native: $N_PASS pass / $N_FAIL fail"
log "Glibc:  $G_PASS pass / $G_FAIL fail"
log "Total:  $((N_PASS+G_PASS)) pass / $((N_FAIL+G_FAIL)) fail"
[[ $N_FAIL -eq 0 && $G_FAIL -eq 0 ]] && log "REBUILD-OK $((N_PASS+G_PASS))/$((N_PASS+G_PASS+N_FAIL+G_FAIL))" \
    || log "REBUILD-PARTIAL N=$N_PASS/$((N_PASS+N_FAIL)) G=$G_PASS/$((G_PASS+G_FAIL))"
rm -rf "$WORKDIR"
