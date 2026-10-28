#!/data/data/com.termux/files/usr/bin/bash
# build-pins.sh — per-version dependency pins for the v2 native build (B line).
#
# The table itself now lives in build/matrix/pins.sh (single source of truth):
#   pty     <- packages/cli/package.json  dependencies["@opencode-ai/pty"]
#   opentui <- root package.json          workspaces.catalog["@opentui/core"]
#   lib     -> which bionic libopentui build to deploy
#   ffi     -> which FFI symbol profile the deployed library must satisfy
#
# Unknown versions are a hard error. The previous `*) OPENTUI_VER=0.5.14`
# fallback silently paired a new source tree with a two-minor-old opentui
# (docs-reorg-maint E1c). PTY_VER / OPENTUI_VER in the environment still win,
# for debug builds.

_BUILD_PINS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT_PINS="$(cd "$_BUILD_PINS_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$_REPO_ROOT_PINS/build/matrix/pins.sh"

resolve_dep_pins() {
	local ver="${1:-}"
	local row pty opentui lib ffi
	[[ -n "$ver" ]] || { echo "Error: resolve_dep_pins: version required" >&2; return 1; }

	if ! row="$(matrix_pins_for "$ver")"; then
		echo "Error: unknown VER=$ver — add its row to build/matrix/pins.sh (pty: packages/cli/package.json; opentui: root package.json workspaces.catalog)" >&2
		return 1
	fi
	read -r pty opentui lib ffi <<<"$row"

	printf 'PTY_VER=%s OPENTUI_VER=%s\n' "${PTY_VER:-$pty}" "${OPENTUI_VER:-$opentui}"
}

# Full matrix resolution for the bionic build: pins + renderer library + FFI profile.
# Prints KEY=VALUE lines so callers can eval or grep without parsing prose.
resolve_pin_matrix() {
	local ver="${1:-}"
	local row pty opentui lib ffi so
	[[ -n "$ver" ]] || { echo "Error: resolve_pin_matrix: version required" >&2; return 1; }

	if ! row="$(matrix_pins_for "$ver")"; then
		echo "Error: unknown VER=$ver — add its row to build/matrix/pins.sh" >&2
		return 1
	fi
	read -r pty opentui lib ffi <<<"$row"
	so="$(matrix_libopentui_path "$_REPO_ROOT_PINS" "$lib")"
	[[ -n "$so" ]] || so=""

	printf 'PTY_VER=%s\n' "${PTY_VER:-$pty}"
	printf 'OPENTUI_VER=%s\n' "${OPENTUI_VER:-$opentui}"
	printf 'LIBOPENTUI_NAME=%s\n' "$lib"
	printf 'LIBOPENTUI_SO=%s\n' "$so"
	printf 'FFI_PROFILE=%s\n' "$ffi"
}
