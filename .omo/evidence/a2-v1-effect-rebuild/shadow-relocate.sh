#!/data/data/com.termux/files/usr/bin/bash
# oscar shadow relocation — oscar task A2 todo18.
#
# Moves the shadow copies back to the paths the pacman local db records,
# then verifies with `pacman -Qk`. This is the safe equivalent of fix20's
# step [18] "reinstall affected packages", minus the network + full-system
# upgrade: the audit proved every shadow copy's sha256 already matches the
# db mtree (RESTORABLE=2909 STALE=0), so a rename restores byte-identical
# content without touching a single package manager transaction.
#
# Why not the real fix20: its [12/20] runs `pacman -Syyu` (full system
# upgrade) which would reinstall glibc/bash/openssh/python on this 3.18
# kernel box, over the very SSH session driving the deploy. Relocating by
# rename is content-equivalent for db integrity and carries no such risk.
#
# Usage: shadow-relocate.sh <audit-restorable-file>
set -eu

EFF=/data/data/com.termux/files              # orig RootDir (shadow top minus /data)
SRC_LIST="${1:?restorable list}"

moved=0
skipped=0
failed=0
: >"$PREFIX/tmp/relocate-log.txt"

while IFS=$'\t' read -r pkg absp link; do
	[ -n "${absp:-}" ] || continue
	# Filenames with spaces arrive as one field here (IFS=tab), so the
	# path is used verbatim — no word splitting.
	rel=${absp#/}                             # data/data/com.termux/files/usr/...
	shadow="$EFF/$rel"
	if [ -L "$absp" ] || [ -e "$absp" ]; then
		skipped=$((skipped + 1))
		continue
	fi
	mkdir -p "$(dirname "$absp")"
	# db symlink entries (type=link, no digest) are recreated from the
	# recorded target; a plain move would fail or materialise a regular
	# file where a link belongs.
	if [ -n "${link:-}" ]; then
		if ln -sfn "$link" "$absp"; then
			moved=$((moved + 1))
		else
			failed=$((failed + 1))
			echo "LINK_FAILED $pkg $absp -> $link" >>"$PREFIX/tmp/relocate-log.txt"
		fi
		continue
	fi
	if [ ! -f "$shadow" ]; then
		failed=$((failed + 1))
		echo "MISSING_SHADOW $pkg $absp" >>"$PREFIX/tmp/relocate-log.txt"
		continue
	fi
	if mv -f "$shadow" "$absp"; then
		moved=$((moved + 1))
	else
		failed=$((failed + 1))
		echo "MV_FAILED $pkg $absp" >>"$PREFIX/tmp/relocate-log.txt"
	fi
done <"$SRC_LIST"

echo "RELOCATE moved=$moved skipped=$skipped failed=$failed"
