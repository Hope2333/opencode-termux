#!/data/data/com.termux/files/usr/bin/bash
# build/matrix/pins.sh — GENERATED FILE. DO NOT EDIT.
#
# Source of truth: build/matrix/pins.yaml
# Regenerate:      tools/matrix-render.sh
# Drift check:     tools/matrix-render.sh --check   (also run by matrix-check)
#
# Consumers:
#   scripts/lib/build-pins.sh   (resolve_dep_pins / resolve_pin_matrix)
#   scripts/build-bionic.sh     (deploys the matching bionic libopentui + FFI gate)
#   tools/matrix-check.sh       (schema + upstream drift + deliberate upgrades)
#
# Columns printed by matrix_pins_for: pty opentui lib ffi effect
# Unknown versions return 1 — never fall back to a default pin.

matrix_pins_for() {
	local ver="${1:-}"
	[[ -n "$ver" ]] || return 1
	case "$ver" in
		2.0.0) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.1) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.2) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.3) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.4) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.5) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.6) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.7) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.8) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.9) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.10) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.11) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.12) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.13) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.14) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.15) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.16) printf '0.1.13 0.5.10 tlsdesc legacy -\n' ;;
		2.0.17) printf '0.1.13 0.5.12 tlsdesc legacy -\n' ;;
		2.0.18) printf '0.1.13 0.5.12 tlsdesc legacy -\n' ;;
		2.0.19) printf '0.1.13 0.5.12 tlsdesc legacy -\n' ;;
		2.0.20) printf '0.1.13 0.5.12 tlsdesc legacy -\n' ;;
		2.0.21) printf '0.1.13 0.5.14 tlsdesc legacy -\n' ;;
		2.0.22) printf '0.1.13 0.5.14 tlsdesc legacy -\n' ;;
		2.0.23) printf '0.2.0 0.5.14 tlsdesc legacy -\n' ;;
		2.0.24) printf '0.2.0 0.5.14 tlsdesc legacy -\n' ;;
		2.0.25) printf '0.2.0 0.5.16 tlsdesc legacy -\n' ;;
		2.0.26) printf '0.2.0 0.5.17 tlsdesc legacy -\n' ;;
		2.0.27) printf '0.2.0 0.5.17 tlsdesc legacy -\n' ;;
		2.0.28) printf '0.2.0 0.5.17 tlsdesc legacy -\n' ;;
		2.0.29) printf '0.2.0 0.5.17 tlsdesc legacy -\n' ;;
		2.0.30) printf '0.2.0 0.5.17 tlsdesc legacy -\n' ;;
		2.0.31) printf '0.2.0 0.5.17 tlsdesc legacy -\n' ;;
		2.0.32) printf '0.2.0 0.5.17 tlsdesc legacy -\n' ;;
		2.1.0) printf '0.3.1 0.6.6 opentui-0.6.8 ot_ctx -\n' ;;
		2.1.1) printf '0.3.1 0.6.6 opentui-0.6.8 ot_ctx -\n' ;;
		2.1.2) printf '0.3.1 0.6.6 opentui-0.6.8 ot_ctx -\n' ;;
		2.1.3) printf '0.3.1 0.6.6 opentui-0.6.8 ot_ctx -\n' ;;
		2.1.4) printf '0.3.1 0.6.8 opentui-0.6.8 ot_ctx -\n' ;;
		1.19.4) printf 'none 0.4.5 tlsdesc legacy 4.0.0-beta.103\n' ;;
		*) return 1 ;;
	esac
}

# Enumerate every registered version (used by tools/matrix-check.sh).
matrix_versions() {
	printf '%s\n' \
		2.0.0 2.0.1 2.0.2 2.0.3 \
		2.0.4 2.0.5 2.0.6 2.0.7 \
		2.0.8 2.0.9 2.0.10 2.0.11 \
		2.0.12 2.0.13 2.0.14 2.0.15 \
		2.0.16 2.0.17 2.0.18 2.0.19 \
		2.0.20 2.0.21 2.0.22 2.0.23 \
		2.0.24 2.0.25 2.0.26 2.0.27 \
		2.0.28 2.0.29 2.0.30 2.0.31 \
		2.0.32 2.1.0 2.1.1 2.1.2 \
		2.1.3 2.1.4 1.19.4
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
