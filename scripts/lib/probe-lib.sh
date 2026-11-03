#!/data/data/com.termux/files/usr/bin/bash
# scripts/lib/probe-lib.sh — pure helpers for tools/probe-version.sh.
#
# Sourced by the CLI and by tests/unit/probe-lib.bats. No network, no device:
# everything here is string/arithmetic so the verdict rules can be unit-tested
# without an Android phone attached.

# probe_ver_key <ver> — zero-padded sort key so shell `sort` orders 2.0.32 < 2.1.0.
probe_ver_key() {
	local v="$1" maj min pat
	IFS=. read -r maj min pat <<<"$v"
	printf '%03d%03d%03d\n' "${maj:-0}" "${min:-0}" "${pat:-0}"
}

# probe_ver_lt <a> <b> — true when a < b.
probe_ver_lt() {
	[ "$(probe_ver_key "$1")" -lt "$(probe_ver_key "$2")" ]
}

# probe_expand_range <spec> — newline-separated version list.
#   "2.0.32..2.2.2"  expands within ONE major.minor only; crossing minors is an
#                    error because upstream skips patches (2.0.32 then 2.1.0),
#                    so a synthetic 2.1.-1 would be a lie.
#   "2.0.32,2.1.0"   explicit list, order preserved.
probe_expand_range() {
	local spec="$1" a b maj_a min_a maj_b min_b maj min pat
	case "$spec" in
	*..*)
		a="${spec%%..*}"; b="${spec##*..}"
		IFS=. read -r maj_a min_a _ <<<"$a"
		IFS=. read -r maj_b min_b _ <<<"$b"
		if [ "$maj_a.$min_a" != "$maj_b.$min_b" ]; then
			echo "probe: range '$spec' crosses a minor version — list the versions explicitly" >&2
			return 1
		fi
		pat="${a##*.}"
		while :; do
			printf '%s.%s.%s\n' "$maj_a" "$min_a" "$pat"
			[ "$pat" = "${b##*.}" ] && break
			pat=$((pat + 1))
			# bail out instead of looping forever on a malformed end
			[ "$pat" -gt 999 ] && return 1
		done
		;;
	*)
		printf '%s\n' "$spec" | tr ',' '\n' | sed '/^$/d'
		;;
	esac
}

# probe_pkg_path <deb-dir> <kind> <ver> — path if present, empty otherwise.
probe_pkg_path() {
	local dir="$1" kind="$2" ver="$3" base p best="" best_rev=0 rev
	if [ "$kind" = v1 ]; then base="opencode1_${ver}"; else base="opencode_${ver}"; fi
	# Plain (`<base>_aarch64.deb`, implicitly rev 1) or repack
	# (`<base>-<rev>_aarch64.deb`). Probe the HIGHEST revision: after a build fix
	# the repack is the artifact under test, and silently probing the stale plain
	# file would test the wrong bytes.
	for p in "$dir/$base"_aarch64.deb "$dir/$base"-*_aarch64.deb; do
		[ -f "$p" ] || continue
		case "$p" in
		*"-$base"*) : ;;
		esac
		rev="$(printf '%s' "$p" | sed -n 's/.*-\([0-9]\+\)_aarch64\.deb$/\1/p')"
		[ -n "$rev" ] || rev=1
		if [ "$rev" -ge "$best_rev" ]; then best="$p"; best_rev="$rev"; fi
	done
	[ -n "$best" ] && printf '%s\n' "$best"
}

# probe_verdict — read `key=value` lines on stdin, print "PASS" or "FAIL: ...".
#
# Rules (all must hold):
#   install=ok        dpkg accepted the package
#   version=<expected>  binary reports the version we asked for
#   serve=200         HTTP server answers on /
#   pty=ok            a terminal can be created over the API (bionic dlopen gate)
#   tui_bytes>=800    a real TUI frame was captured (a CLI fallback is ~0-307B)
#   echoed>=1         typed text came back on screen (input path alive)
#   alive15=YES       still running 15s after the keystroke
#   crash=0 degrade=0 no panic/SIGSEGV and no legacy-kernel downgrade banner
probe_verdict() {
	local kv key val
	local install="" version="" expected="" serve="" pty="" tui_bytes="" echoed="" alive15="" crash="" degrade=""
	while IFS='=' read -r key val; do
		case "$key" in
		install) install="$val" ;;
		version) version="$val" ;;
		expected) expected="$val" ;;
		serve) serve="$val" ;;
		pty) pty="$val" ;;
		tui_bytes) tui_bytes="$val" ;;
		echoed) echoed="$val" ;;
		alive15) alive15="$val" ;;
		crash) crash="$val" ;;
		degrade) degrade="$val" ;;
		esac
	done

	[ "$install" = ok ] || { echo "FAIL: install (${install:-no result})"; return 0; }
	if [ -n "$expected" ] && [ "$version" != "$expected" ]; then
		echo "FAIL: version reported '$version', expected '$expected'"; return 0
	fi
	[ "$serve" = 200 ] || { echo "FAIL: serve (${serve:-none})"; return 0; }
	# pty=ok is mandatory: without it the TUI renders but no terminal can ever
	# be created (POST /api/pty -> ERR_DLOPEN_FAILED on bionic). A probe that
	# does not report pty at all fails loudly instead of silently passing.
	[ -n "$pty" ] || { echo "FAIL: pty (missing)"; return 0; }
	[ "$pty" = ok ] || { echo "FAIL: pty ($pty)"; return 0; }
	[ "${tui_bytes:-0}" -ge 800 ] 2>/dev/null || { echo "FAIL: tui (${tui_bytes:-0} B)"; return 0; }
	[ "${echoed:-0}" -ge 1 ] 2>/dev/null || { echo "FAIL: input echo"; return 0; }
	[ "$alive15" = YES ] || { echo "FAIL: not alive after 15s"; return 0; }
	[ "${crash:-0}" -eq 0 ] 2>/dev/null || { echo "FAIL: crash markers"; return 0; }
	[ "${degrade:-0}" -eq 0 ] 2>/dev/null || { echo "FAIL: legacy-kernel degradation"; return 0; }
	echo "PASS"
}
