#!/data/data/com.termux/files/usr/bin/bash
# build-pins.sh — per-version dependency pins for the v2 native build (B line).
#
# Values are read from the upstream tag itself (2026-10-23):
#   pty     <- packages/cli/package.json  dependencies["@opencode-ai/pty"]
#   opentui <- root package.json          workspaces.catalog["@opentui/core"]
#
# Unknown versions are a hard error. The previous `*) OPENTUI_VER=0.5.14`
# fallback silently paired a new source tree with a two-minor-old opentui
# (docs-reorg-maint E1c). PTY_VER / OPENTUI_VER in the environment still win,
# for debug builds.

resolve_dep_pins() {
	local ver="${1:-}"
	local pty opentui
	[[ -n "$ver" ]] || { echo "Error: resolve_dep_pins: version required" >&2; return 1; }

	case "$ver" in
		2.0.0|2.0.[1-9]|2.0.1[0-9]|2.0.2[0-4]) opentui="0.5.14" ;;
		2.0.25) opentui="0.5.16" ;;
		2.0.2[6-9]|2.0.3[0-2]) opentui="0.5.17" ;;
		2.1.[0-3]) opentui="0.6.6" ;;
		2.1.4) opentui="0.6.8" ;;
		*)
			echo "Error: unknown VER=$ver — add its upstream pins to scripts/lib/build-pins.sh (pty: packages/cli/package.json; opentui: root package.json workspaces.catalog)" >&2
			return 1
			;;
	esac

	case "$ver" in
		2.0.*) pty="0.2.0" ;;
		2.1.*) pty="0.3.1" ;;
		*)
			echo "Error: unknown VER=$ver — no pty pin line" >&2
			return 1
			;;
	esac

	printf 'PTY_VER=%s OPENTUI_VER=%s\n' "${PTY_VER:-$pty}" "${OPENTUI_VER:-$opentui}"
}
