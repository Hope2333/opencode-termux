#!/usr/bin/env bash
# install.sh — install the watcher binary into $PREFIX/bin (Termux convention).
# Idempotent: skips when the same version is already installed, overwrites on
# version change. Self-checks with `watcher --help` after install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BIN_SRC="${SCRIPT_DIR}/watcher"

usage() {
    cat <<'USAGE'
usage: install.sh [--prefix DIR] [--bin PATH]

  --prefix DIR  install prefix (default: $PREFIX, i.e. /data/data/com.termux/files/usr)
  --bin PATH    source watcher binary (default: <script dir>/watcher)
  -h, --help    show this help and exit
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --bin)    BIN_SRC="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# fail-fast: source binary must exist and be executable
if [[ ! -x "$BIN_SRC" ]]; then
    echo "install.sh: error: source binary not found or not executable: $BIN_SRC" >&2
    exit 1
fi

# source must support --version (version gate)
SRC_VERSION="$("$BIN_SRC" --version 2>/dev/null | head -n1)" || {
    echo "install.sh: error: source binary does not support --version: $BIN_SRC" >&2
    exit 1
}

DEST="${PREFIX}/bin/watcher"
mkdir -p "${PREFIX}/bin"

# idempotency: same version already installed -> skip; different -> overwrite
if [[ -x "$DEST" ]]; then
    DEST_VERSION="$("$DEST" --version 2>/dev/null | head -n1 || true)"
    if [[ -n "$DEST_VERSION" && "$DEST_VERSION" == "$SRC_VERSION" ]]; then
        echo "install.sh: watcher already installed at $DEST ($SRC_VERSION), skipping"
        exit 0
    fi
    echo "install.sh: replacing $DEST ($DEST_VERSION) with $SRC_VERSION"
fi

install -m 755 "$BIN_SRC" "$DEST"

# post-install self-check
if ! "$DEST" --help >/dev/null 2>&1; then
    echo "install.sh: error: post-install self-check failed: $DEST --help" >&2
    exit 1
fi

echo "install.sh: installed watcher $SRC_VERSION -> $DEST"
