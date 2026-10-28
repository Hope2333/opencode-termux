#!/data/data/com.termux/files/usr/bin/bash
# build/matrix/pins.sh — SINGLE SOURCE OF TRUTH for per-version build pins.
#
# Consumers:
#   scripts/lib/build-pins.sh   (resolve_dep_pins / resolve_pin_matrix)
#   scripts/build-bionic.sh     (deploys the matching bionic libopentui + FFI gate)
#
# Why this file exists: previously the version→opentui table lived inside
# build-pins.sh while the version→libopentui.so mapping was a separate hardcoded
# if/elif inside build-bionic.sh. The two drifted, and 2.1.4 shipped the 0.5.x
# renderer library against 0.6.8 JS (TUI died with ot_scene_set_hooks missing).
# One table, four columns, no second place to forget.
#
# Columns (space separated, printed by matrix_pins_for):
#   pty      upstream @opencode-ai/pty version
#   opentui  upstream workspaces.catalog["@opentui/core"] version
#   lib      bionic renderer build name:
#              tlsdesc          -> artifacts/transplant/opentui-bionic-tlsdesc/
#              opentui-<ver>    -> artifacts/transplant/opentui-bionic-<ver>/
#              missing          -> not built yet; builds MUST hard-fail
#   ffi      FFI symbol profile: legacy (0.5.x direct surface) | ot_ctx (0.6.x ot_* ABI)
#
# Unknown versions return 1 — never fall back to a default pin.

matrix_pins_for() {
	local ver="${1:-}"
	[[ -n "$ver" ]] || return 1
	case "$ver" in
		# Ranges below are read from the upstream tag itself (verified by
		# tools/matrix-check.sh against gh api, 2026-10-26). The old single
		# `2.0.0-2.0.24 -> 0.5.14 / pty 0.2.0` row was an unchecked carry-over:
		# upstream actually shipped 0.5.10 (pty 0.1.13) until 2.0.16.
		2.0.0|2.0.[1-9]|2.0.1[0-6]) printf '0.1.13 0.5.10 tlsdesc legacy\n' ;;
		2.0.1[7-9]|2.0.20) printf '0.1.13 0.5.12 tlsdesc legacy\n' ;;
		2.0.2[12]) printf '0.1.13 0.5.14 tlsdesc legacy\n' ;;
		2.0.2[34]) printf '0.2.0 0.5.14 tlsdesc legacy\n' ;;
		2.0.25) printf '0.2.0 0.5.16 tlsdesc legacy\n' ;;
		2.0.2[6-9]|2.0.3[0-2]) printf '0.2.0 0.5.17 tlsdesc legacy\n' ;;
		2.1.[0-3]) printf '0.3.1 0.6.6 missing ot_ctx\n' ;;
		2.1.4) printf '0.3.1 0.6.8 opentui-0.6.8 ot_ctx\n' ;;
		*) return 1 ;;
	esac
}

# Enumerate every registered version (used by tools/matrix-check.sh).
# Ranges are expanded explicitly so callers never have to parse case patterns.
matrix_versions() {
	local major minor
	for minor in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 \
		25 26 27 28 29 30 31 32; do
		printf '2.0.%s\n' "$minor"
	done
	for minor in 0 1 2 3 4; do
		printf '2.1.%s\n' "$minor"
	done
}

# Resolve a lib name to an absolute .so path (empty when the build is missing).
matrix_libopentui_path() {
	local repo_root="$1" name="${2:-}"
	case "$name" in
		tlsdesc) printf '%s\n' "$repo_root/artifacts/transplant/opentui-bionic-tlsdesc/libopentui.so" ;;
		missing|"") printf '\n' ;;
		*) printf '%s\n' "$repo_root/artifacts/transplant/opentui-bionic-${name#opentui-}/libopentui.so" ;;
	esac
}

# FFI profile → symbols that MUST be exported by the deployed renderer library.
# legacy: 0.5.x direct bindings. ot_ctx: 0.6.x renamed everything into the
# ot_* context ABI; upstream 0.6.8's glibc build exports ZERO of the legacy names.
matrix_ffi_syms() {
	case "${1:-}" in
		legacy)
			printf '%s\n' cancelKittyImageTransport editBufferSetTabWidth getBufferWidthMethod \
				getKittyImageTransport imageCreateFromPixels imageUpdatePixels pollKittyImageTransport \
				processKittyImageReply setKittyImageTransport pthread_tryjoin_np
			;;
		ot_ctx)
			printf '%s\n' ot_scene_set_hooks ot_session_set_kitty_image_transport \
				ot_session_cancel_kitty_image_transport ot_session_get_kitty_image_transport \
				ot_session_poll_kitty_image_transport ot_session_process_kitty_image_reply \
				ot_session_start_kitty_file_probe pthread_tryjoin_np
			;;
		*) return 1 ;;
	esac
}
