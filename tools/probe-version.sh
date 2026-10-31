#!/data/data/com.termux/files/usr/bin/bash
# tools/probe-version.sh — run the full per-version criteria on a real device.
#
# Answers one question: "does THIS package actually work on THAT phone?"
# Install -> --version -> serve 200 -> TUI frame -> keystroke roundtrip ->
# 15 s survival -> crash/degradation markers. Verdict rules live in
# scripts/lib/probe-lib.sh so they can be unit-tested without a device.
#
#   tools/probe-version.sh --device u0_a115@192.168.2.128 --kind v2 --ver 2.0.32
#   tools/probe-version.sh --device u0_a115@192.168.2.128 --kind v2 \
#       --range 2.0.32..2.0.32 --list 2.1.0,2.1.4 --restore 2.1.4
#   tools/probe-version.sh ... --kind v1 --list 1.18.33,1.19.3 --drop-other
#
# Exit: 0 every probe PASS · 1 any FAIL/MISSING · 2 usage/transport error.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/probe-lib.sh
source "$REPO_ROOT/scripts/lib/probe-lib.sh"

DEVICE=""; SSH_PORT=8022; KIND=""; VERS=""; DEB_DIR="$REPO_ROOT/packing/dpkg-native"
WAIT=30; RESTORE=""; DROP_OTHER=0; JSON_OUT=""; DRY=0; ALLOW_MISSING=0; TIMEOUT=900

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "probe-version: ERROR: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
	case "$1" in
	--device) DEVICE="${2:-}"; shift 2 ;;
	--ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
	--kind) KIND="${2:-}"; shift 2 ;;
	--ver) VERS="$VERS ${2:-}"; shift 2 ;;
	--list) VERS="$VERS $(printf '%s' "${2:-}" | tr ',' ' ')"; shift 2 ;;
	--range) VERS="$VERS $(probe_expand_range "${2:-}")" || exit 2; shift 2 ;;
	--deb-dir) DEB_DIR="${2:-}"; shift 2 ;;
	--wait) WAIT="${2:-}"; shift 2 ;;
	--restore) RESTORE="${2:-}"; shift 2 ;;
	--json) JSON_OUT="${2:-}"; shift 2 ;;
	--drop-other) DROP_OTHER=1; shift ;;
	--allow-missing) ALLOW_MISSING=1; shift ;;
	--dry-run) DRY=1; shift ;;
	-h|--help) usage ;;
	*) die "unknown argument: $1" ;;
	esac
done

[ -n "$DEVICE" ] || die "--device is required"
case "$KIND" in v1|v2) ;; *) die "--kind must be v1 or v2" ;; esac
VERS="$(printf '%s\n' $VERS | sed '/^$/d' | sort -u -V)"
[ -n "$VERS" ] || die "give at least one version (--ver/--list/--range)"

# accept-new, not strict: lab devices change IP far more often than host keys,
# and pinning an IP in known_hosts turns every DHCP move into "host key
# verification failed". Identity is still verified out-of-band (kernel/model).
SSH_BASE=(ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$DEVICE")
SCP_BASE=(scp -P "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

remote() { "${SSH_BASE[@]}" "$@"; }

remote "true" 2>/dev/null || die "cannot reach $DEVICE over ssh (port $SSH_PORT)"

# Ship the device-side probe once per run.
if [ "$DRY" -eq 0 ]; then
	"${SCP_BASE[@]}" "$REPO_ROOT/tools/probe/device-probe.sh" \
		"$DEVICE:/data/data/com.termux/files/usr/tmp/device-probe.sh" >/dev/null 2>&1 ||
		die "cannot copy device-probe.sh to $DEVICE"
	remote 'chmod +x /data/data/com.termux/files/usr/tmp/device-probe.sh' || die "chmod failed"
fi

# Old v1 packages (<=1.19.3) still ship the seccomp shim to lib/opencode — the v2
# slot — so they refuse to install while v2 is present. --drop-other removes the
# other generation for the duration and puts it back afterwards.
OTHER_PKG=""; [ "$KIND" = v1 ] && OTHER_PKG="opencode" || OTHER_PKG="opencode1"
OTHER_BACKUP=""
if [ "$DROP_OTHER" -eq 1 ]; then
	OTHER_BACKUP="$(remote "dpkg -l 2>/dev/null | awk '/^ii  ${OTHER_PKG} /{print \$3}'" | head -1)"
	if [ "$DRY" -eq 0 ]; then
		remote "dpkg -r $OTHER_PKG >/dev/null 2>&1" || die "cannot remove $OTHER_PKG"
		echo "==> removed $OTHER_PKG (backup copy of its .deb needed for --restore)"
	fi
fi

rows=""; failures=0; json_items=""
for V in $VERS; do
	pkg="$(probe_pkg_path "$DEB_DIR" "$KIND" "$V")"
	if [ -z "$pkg" ]; then
		if [ "$ALLOW_MISSING" -eq 1 ]; then
			printf '%-8s %s\n' "$V" "MISSING (skipped)"
			rows="$rows$V|-|-|-|-|-|MISSING: no package in $DEB_DIR\n"
			continue
		fi
		printf '%-8s %s\n' "$V" "MISSING package in $DEB_DIR"
		rows="$rows$V|-|-|-|-|-|FAIL: missing package\n"
		failures=$((failures + 1))
		continue
	fi

	if [ "$DRY" -eq 1 ]; then
		echo "would probe $KIND $V  ($(basename "$pkg"), $(stat -c%s "$pkg" 2>/dev/null || stat -f%z "$pkg") B)"
		continue
	fi

	"${SCP_BASE[@]}" "$pkg" "$DEVICE:/data/data/com.termux/files/usr/tmp/probe-$V.deb" >/dev/null 2>&1 ||
		die "cannot copy $(basename "$pkg") to $DEVICE"

	kv="$(timeout "$TIMEOUT" "${SSH_BASE[@]}" "/data/data/com.termux/files/usr/tmp/device-probe.sh $KIND $V /data/data/com.termux/files/usr/tmp/probe-$V.deb $WAIT" 2>&1)"
	verdict="$(printf '%s\n' "$kv" | probe_verdict)"

	get() { printf '%s\n' "$kv" | sed -n "s/^$1=//p" | head -1; }
	version="$(get version)"; serve="$(get serve)"; tui="$(get tui_bytes)"
	echoed="$(get echoed)"; alive="$(get alive15)"

	printf '%-8s %-22s serve=%-4s tui=%-6s echo=%-3s alive=%-4s %s\n' \
		"$V" "$version" "$serve" "$tui" "$echoed" "$alive" "$verdict"
	printf '%s\n' "$kv" | grep -E '^  [|!] ' | sed 's/^/         /'

	status="PASS"; case "$verdict" in FAIL*) status="FAIL"; failures=$((failures + 1)) ;; esac
	rows="$rows$V|$version|$serve|$tui|$echoed|$alive|$verdict\n"
	json_items="$json_items${json_items:+,}{\"version\":\"$V\",\"reported\":\"$version\",\"serve\":\"$serve\",\"tui_bytes\":\"$tui\",\"echoed\":\"$echoed\",\"alive15\":\"$alive\",\"verdict\":\"$verdict\"}"
done

# Put the other generation back, then optionally restore a known-good build.
if [ "$DROP_OTHER" -eq 1 ] && [ "$DRY" -eq 0 ]; then
	backup_pkg="$(probe_pkg_path "$DEB_DIR" "$( [ "$KIND" = v1 ] && echo v2 || echo v1 )" "$OTHER_BACKUP")"
	if [ -n "$backup_pkg" ]; then
		"${SCP_BASE[@]}" "$backup_pkg" "$DEVICE:/data/data/com.termux/files/usr/tmp/restore-other.deb" >/dev/null 2>&1
		remote 'dpkg -i /data/data/com.termux/files/usr/tmp/restore-other.deb >/dev/null 2>&1; rm -f /data/data/com.termux/files/usr/tmp/restore-other.deb'
		echo "==> restored $OTHER_PKG $OTHER_BACKUP"
	else
		echo "probe-version: WARNING: no package found for $OTHER_PKG $OTHER_BACKUP — reinstall it manually" >&2
	fi
fi

if [ -n "$RESTORE" ] && [ "$DRY" -eq 0 ]; then
	pkg="$(probe_pkg_path "$DEB_DIR" "$KIND" "$RESTORE")"
	[ -n "$pkg" ] || die "restore target $KIND $RESTORE not found in $DEB_DIR"
	"${SCP_BASE[@]}" "$pkg" "$DEVICE:/data/data/com.termux/files/usr/tmp/restore.deb" >/dev/null 2>&1
	remote 'dpkg -i /data/data/com.termux/files/usr/tmp/restore.deb >/dev/null 2>&1; rm -f /data/data/com.termux/files/usr/tmp/restore.deb'
	echo "==> restored $KIND $RESTORE"
fi

if [ -n "$JSON_OUT" ]; then
	printf '{"kind":"%s","device":"%s","probed_at":"%s","results":[%s]}\n' \
		"$KIND" "$DEVICE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$json_items" >"$JSON_OUT"
	echo "==> json: $JSON_OUT"
fi

[ "$failures" -eq 0 ] || { echo "probe-version: $failures version(s) FAILED" >&2; exit 1; }
echo "probe-version: all probed versions PASS"
