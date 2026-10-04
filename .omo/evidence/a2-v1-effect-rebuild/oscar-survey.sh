#!/data/data/com.termux/files/usr/bin/bash
# oscar pre/post install survey for the v1 press5 pacman deploy (A2 todo18).
# Usage: oscar-survey.sh <pre|post>
# Prints: pacman.conf RootDir, installed opencode* packages, the v1 file tree
# the package owns, and the shadow (double-path) subtree state.
set -u
PHASE="${1:?pre|post}"

echo "===== PHASE=$PHASE TS=$(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
echo "--- kernel/identity ---"
uname -a
echo "PREFIX=$PREFIX"

echo "--- pacman.conf RootDir ---"
grep -nE '^[[:space:]]*#?[[:space:]]*RootDir' "$PREFIX/etc/pacman.conf" || echo "(no RootDir line)"

echo "--- installed opencode* packages ---"
pacman -Q 2>/dev/null | grep -i opencode || echo "(none)"

echo "--- package db version dir ---"
ls -1 "$PREFIX/var/lib/pacman/local/" 2>/dev/null | grep -i opencode || echo "(none)"

echo "--- v1 install tree (pacman-owned) ---"
pacman -Ql opencode1-compressed 2>/dev/null || echo "(opencode1-compressed not installed)"

echo "--- on-disk opencode1 bin/lib ---"
ls -la "$PREFIX/bin/opencode1" 2>/dev/null || echo "(no bin/opencode1)"
ls -la "$PREFIX/lib/opencode1/" 2>/dev/null || echo "(no lib/opencode1/)"

echo "--- shadow (double-path) subtree: \$PREFIX/data/... ---"
if [ -e "$PREFIX/data" ]; then
	echo "SHADOW_PRESENT=$PREFIX/data"
	find "$PREFIX/data" -maxdepth 6 -type d 2>/dev/null | head -30
	echo "--- shadow file count / bytes ---"
	find "$PREFIX/data" -type f 2>/dev/null | wc -l
	du -sh "$PREFIX/data" 2>/dev/null
	echo "--- shadow real (non-empty) files under data/com.termux/files/usr ---"
	find "$PREFIX/data/com.termux/files/usr" -type f 2>/dev/null | head -20
	echo "shadow_usr_file_count=$(find "$PREFIX/data/com.termux/files/usr" -type f 2>/dev/null | wc -l)"
else
	echo "SHADOW_ABSENT=$PREFIX/data (no shadow subtree)"
fi

echo "--- alternate shadow candidate: \$PREFIX/../data ---"
ALT="$(dirname "$PREFIX")/data"
if [ -e "$ALT" ]; then
	echo "ALT_SHADOW_PRESENT=$ALT"
	echo "alt_usr_file_count=$(find "$ALT/com.termux/files/usr" -type f 2>/dev/null | wc -l)"
else
	echo "ALT_SHADOW_ABSENT=$ALT"
fi

echo "--- files1 legacy container (must NOT touch) ---"
ls -d /data/data/com.termux/files1 2>/dev/null && echo "(files1 exists — leave alone)" || echo "(no files1)"

echo "--- v1 user data (opencode1 isolation roots) ---"
for d in "$HOME/.config/opencode1" "$HOME/.local/share/opencode1" "$HOME/.cache/opencode1" "$HOME/.local/state/opencode1"; do
	if [ -d "$d" ]; then echo "DATA $d ($(find "$d" -type f 2>/dev/null | wc -l) files)"; else echo "DATA_MISSING $d"; fi
done

echo "===== END PHASE=$PHASE ====="
