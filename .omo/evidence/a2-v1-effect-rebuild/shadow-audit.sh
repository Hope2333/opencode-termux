#!/data/data/com.termux/files/usr/bin/bash
# Audit the oscar shadow subtree (/data/data/com.termux/files/data) against the
# pacman local db: for every db-recorded file of the affected packages, decide
#   RESTORABLE  = absent at the correct path, present in the shadow, sha256
#                 matches the db mtree  -> a pure move restores it
#   STALE       = present in the shadow but sha256 differs from the db
#                 (shadow holds an older/newer copy; a move would be wrong)
#   ABSENT      = in neither place
#   OK          = already present at the correct path
# Usage: shadow-audit.sh <affected-pkgs-file> [summary|detail]
set -u
# oscar shadow subtree: /data/data/com.termux/files/data
#
# Root cause recap: pacman.conf had RootDir = /data/data/com.termux/files
# (the "files" dir, i.e. $PREFIX's parent) while our packages carry the
# absolute-convention member `data/data/com.termux/files/usr/...`. pacman
# resolves members against RootDir, so they landed at
#   ORIG + member = /data/data/com.termux/files + data/data/com.termux/files/usr/...
# while the db recorded the member with a leading slash (= where the file
# belongs once RootDir falls back to "/").
#   correct path : $absp              (db record, leading slash)
#   shadow copy  : $ORIG$MEMBER       (member without leading slash)
S=/data/data/com.termux/files/data       # shadow top (= ORIG + /data)
EFF=/data/data/com.termux/files          # eff_root (shadow top minus /data)
LIST="${1:?affected pkgs file}"
MODE="${2:-summary}"
TAB=$(printf '\t')

# db mtree paths look like ./data/data/com.termux/files/usr/... ; the recorded
# absolute path is the same string with a leading slash.
#
# Entries come in two shapes and BOTH must be audited:
#   regular file: ... size=N ... sha256digest=<hex>   -> compare content
#   symlink:      ... type=link link=<target>          -> no digest at all;
#                  filtering on sha256digest alone silently drops every symlink,
#                  which is how 11 packages kept failing -Qk after the first
#                  relocation pass (doc/copyright, libexec/git-core/*, man/*).
#                  For links the audit records the link target so the relocate
#                  step can recreate an identical symlink.
db_paths() { # $1 = package name -> "abspath<TAB>sha256-or-LINK<TAB>linktarget"
	local d
	d=$(ls -d "$PREFIX/var/lib/pacman/local/$1-"* 2>/dev/null | head -1)
	[ -n "$d" ] || return 0
	gzip -dc "$d/mtree" 2>/dev/null | awk '
		/^#mtree/ { next }
		/ type=link / {
			p = $1; sub(/^\.\//, "", p)
			t = ""
			for (i = 2; i <= NF; i++)
				if ($i ~ /^link=/) { t = $i; sub(/^link=/, "", t) }
			print "/" p "\tLINK\t" t
			next
		}
		/sha256digest=/ {
			p = $1; sub(/^\.\//, "", p)
			s = ""
			for (i = 2; i <= NF; i++)
				if ($i ~ /^sha256digest=/) { s = $i; sub(/^sha256digest=/, "", s) }
			if (s != "") print "/" p "\t" s "\t"
		}'
}

tot=0; ok=0; restorable=0; stale=0; absent=0
: >"$PREFIX/tmp/audit-restorable.txt"
: >"$PREFIX/tmp/audit-stale.txt"
: >"$PREFIX/tmp/audit-absent.txt"

while read -r pkg; do
	[ -n "$pkg" ] || continue
	db_paths "$pkg" | while IFS="$TAB" read -r absp sum link; do
		case "$absp" in
			/data/data/com.termux/files/usr/*) ;;
			*) continue ;;
		esac
		rel=${absp#/}                          # data/data/com.termux/files/usr/...
		shadow="$EFF/$rel"                     # ORIG + member
		if [ -L "$absp" ] || [ -e "$absp" ]; then
			echo "OK	$pkg	$absp" >>"$PREFIX/tmp/audit-ok.txt"
			continue
		fi
		# symlink entries carry no digest: recreating from the db-recorded
		# target is exact, and the shadow copy (if any) only confirms it.
		if [ "$sum" = "LINK" ]; then
			if [ -e "$shadow" ] || [ -L "$shadow" ]; then
				echo "$pkg	$absp	$link" >>"$PREFIX/tmp/audit-restorable.txt"
			else
				echo "$pkg	$absp	$link" >>"$PREFIX/tmp/audit-absent.txt"
			fi
			continue
		fi
		if [ -f "$shadow" ]; then
			as=$(sha256sum "$shadow" | cut -d' ' -f1)
			if [ "$as" = "$sum" ]; then
				echo "$pkg	$absp" >>"$PREFIX/tmp/audit-restorable.txt"
			else
				echo "$pkg	$absp" >>"$PREFIX/tmp/audit-stale.txt"
			fi
		else
			echo "$pkg	$absp" >>"$PREFIX/tmp/audit-absent.txt"
		fi
	done
done <"$LIST"

for f in ok restorable stale absent; do
	case $f in
		ok) p="$PREFIX/tmp/audit-ok.txt" ;;
		*) p="$PREFIX/tmp/audit-$f.txt" ;;
	esac
	[ -f "$p" ] || : >"$p"
done

if [ "$MODE" = detail ]; then
	echo "--- RESTORABLE (move-safe) ---"; cat "$PREFIX/tmp/audit-restorable.txt"
	echo "--- STALE (content differs) ---"; cat "$PREFIX/tmp/audit-stale.txt"
	echo "--- ABSENT (nowhere) ---"; cat "$PREFIX/tmp/audit-absent.txt"
fi
printf 'OK=%s RESTORABLE=%s STALE=%s ABSENT=%s\n' \
	"$(wc -l <"$PREFIX/tmp/audit-ok.txt")" \
	"$(wc -l <"$PREFIX/tmp/audit-restorable.txt")" \
	"$(wc -l <"$PREFIX/tmp/audit-stale.txt")" \
	"$(wc -l <"$PREFIX/tmp/audit-absent.txt")"
