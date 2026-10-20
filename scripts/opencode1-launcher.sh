#!/data/data/com.termux/files/usr/bin/bash
# opencode1 launcher — dual-generation data isolation (v12.1).
#
# Why: the v1 runtime hardcodes the plain `opencode/` roots (live-fd verified;
# OPENCODE_CONFIG_DIR and friends are enumerated but NOT consumed). The four
# XDG_*_HOME exports re-root every path under an `opencode1/` isolation prefix;
# the runtime then appends its own `opencode/` suffix, landing in the NESTED
# layout migrate-to-opencode1.sh isolate maintains: <root>/opencode1/opencode/.
# v2 keeps the plain roots untouched — the two generations never share a dir.
#
# LD_LIBRARY_PATH covers DT_RUNPATH $ORIGIN/../lib/opencode after the runtime
# moves under lib/opencode1/runtime/; compressed additionally ships its shim in
# lib/opencode1/ — both roots are listed so every package layout resolves
# (absent dirs are harmless: the dynamic linker just skips them).
set -euo pipefail
P="${PREFIX:-/data/data/com.termux/files/usr}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/opencode1"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/opencode1"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/opencode1"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/opencode1"
export LD_LIBRARY_PATH="$P/lib/opencode:$P/lib/opencode1:$P/lib/opencode1/pty${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# service-port split (readiness fix, evidence: tools/opencode-readiness-fix/):
# both v2 generations default the managed service port to 0xc0de=49374, but the
# XDG isolation keeps their registration files apart — a plain-generation daemon
# squatting 49374 is invisible to this generation's discovery, so every
# `serve --service` contender dies of EADDRINUSE and the TUI handshake stalls
# until ensure()'s 120s deadline ("Timed out waiting for the background
# service"). Bootstrap a per-generation port (49376) in this generation's
# service config: absent file -> write one; existing file without a "port" key
# -> inject one (opencode writes pretty JSON whose first line is always "{").
# Best-effort: any failure falls back to the stock default port.
CFG_DIR="${XDG_CONFIG_HOME}/opencode"
CFG_FILE="${CFG_DIR}/service.json"
if [ ! -f "$CFG_FILE" ]; then
	mkdir -p "$CFG_DIR" 2>/dev/null || true
	printf '{"port": 49376}\n' > "$CFG_FILE" 2>/dev/null || true
elif ! grep -q '"port"' "$CFG_FILE" 2>/dev/null; then
	sed -i '1s/^{$/{\n  "port": 49376,/' "$CFG_FILE" 2>/dev/null || true
fi

# pty splice (optional asset, backward compatible): when the compressed package
# ships the patched musl librust_pty (bun-pty 0.4.11 splice — see
# tools/bun-pty-splice/ and docs/compressed-line.md), point bun-pty's
# BUN_PTY_LIB probe at it so the runtime dlopens the bionic-compatible build
# instead of failing on the inlined asset. Its DT_NEEDED shim.so resolves via
# the pty dir added to LD_LIBRARY_PATH above. Old packages without the asset
# are unaffected (no export).
if [ -f "$P/lib/opencode1/pty/librust_pty_arm64_musl_patched.so" ]; then
	export BUN_PTY_LIB="$P/lib/opencode1/pty/librust_pty_arm64_musl_patched.so"
fi

# epoll compat shim (optional asset, backward compatible): pre-#32490 bun
# builds (v1.4.0 34cbb9a40, as shipped in 1.18.32-4) call epoll_pwait2
# (syscall 441, kernel >= 5.1) via libc::syscall and crash on older kernels
# (oscar 3.18.140: TUI SIGSEGV ~4.4s, see task-v1rebuild.txt). The shim
# translates 441 -> epoll_pwait with a timespec->ms conversion. Injected via
# LD_PRELOAD ONLY when the package shipped the asset; packages built before
# the asset are unaffected (no export).
if [ -f "$P/lib/opencode1/libepoll-compat.so" ]; then
	export LD_PRELOAD="$P/lib/opencode1/libepoll-compat.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi

# runtime probe order: layered (native/compressed v12.1 layout) first, then the
# wrapper line's original staged layout. Sibling Conflicts (opencode1 vs
# opencode1-wrapper) guarantee at most one candidate exists per install.
OC_RT=""
for _rt in "$P/lib/opencode1/runtime/opencode" "$P/lib/opencode/runtime/opencode"; do
	if [ -x "$_rt" ]; then
		OC_RT="$_rt"
		break
	fi
done
if [ -z "$OC_RT" ]; then
	echo "opencode1: runtime not found under $P/lib/opencode1/runtime or $P/lib/opencode/runtime" >&2
	exit 127
fi

# ── oldkernel compat guard (A 档 CLI 兜底; OSC-001) ────────────────────────────
# Launcher is a product file: consumer machines (e.g. oscar) have no
# .omo/compat-ledger.jsonl, so the OSC-001 entry is inlined here (source of
# truth: .omo/compat-ledger.jsonl in the build repo).
#   OSC-001: kernel_max="3.x"  first_bad=1.18.35  verdict=graft-ok
#   symptom: opencode >= 1.18.35 (embedded OpenTUI 0.5.14+) TUI render path
#            SIGSEGV on kernel 3.x (oscar 3.18.140-mokee, pty rc=139 5/5)
# Trigger: kernel < 4.x AND runtime >= 1.18.35 -> bilingual warning, and the
# TUI-default scenario (no CLI subcommand) degrades to `serve` (CLI-usable;
# --print/serve semantics are provided by opencode itself). --force-tui skips
# the degradation entirely (B 档 graft hybrid users: TUI actually works there)
# and is stripped from the runtime argv either way. A `.grafted` marker next
# to the runtime (shipped by the T6 graft build, scripts/compat/
# compat-graft-build.sh) skips it the same way: B 档 hybrid installs run the
# TUI bare — no --force-tui needed.
# Kernel >= 4.x or runtime < 1.18.35: zero behavior change — the version
# probe below only runs when the kernel is old, so new kernels pay nothing.
_oc_force_tui=0
_oc_meta=0
_oc_args=()
for _a in "$@"; do
	case "$_a" in
	--force-tui) _oc_force_tui=1; continue ;;
	-h|--help|-v|--version) _oc_meta=1 ;;
	esac
	_oc_args+=("$_a")
done
# graft probe (follow-up fix): `.grafted` beside the runtime marks a B 档
# hybrid install (new CLI + donor 1.18.34 OpenTUI, OSC-001 verdict=graft-ok)
# whose TUI genuinely works on kernel 3.x — skip the degradation entirely so
# bare `opencode1` starts the TUI. Absent marker = A 档 package: the T4
# behavior below is unchanged.
_oc_grafted=0
if [ -f "$(dirname "$OC_RT")/.grafted" ]; then
	_oc_grafted=1
fi
if [ "$_oc_force_tui" -eq 0 ] && [ "$_oc_grafted" -eq 0 ] && [ "$(uname -r | cut -d. -f1)" -lt 4 ] 2>/dev/null; then
	_oc_ver="$("$OC_RT" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){2}' | head -n1 || true)"
	if [ -n "$_oc_ver" ] && [ "$(printf '%s\n%s\n' "$_oc_ver" 1.18.35 | sort -V | head -n1)" = 1.18.35 ]; then
		echo "opencode: 老内核 TUI 不兼容, 已降级 CLI 模式（可用 --force-tui 强试）" >&2
		echo "opencode: Legacy kernel detected: TUI disabled, running CLI mode (use --force-tui to force)" >&2
		if [ "$_oc_meta" -eq 0 ]; then
			_oc_sub=""
			for _a in "${_oc_args[@]}"; do
				case "$_a" in -*) ;; *) _oc_sub="$_a"; break ;; esac
			done
			case "$_oc_sub" in
			# explicit CLI subcommand -> pass through unchanged
			completion|acp|mcp|attach|run|debug|providers|auth|agent|upgrade|uninstall|serve|web|models|stats|export|import|github|pr|session|plugin|db) ;;
			# TUI-default scenario (no args, flags only, or project path):
			# degrade to headless serve, carrying long options only
			*)
				_oc_serve_args=()
				for _a in "${_oc_args[@]}"; do
					case "$_a" in --*) _oc_serve_args+=("$_a") ;; esac
				done
				exec "$OC_RT" serve ${_oc_serve_args[@]+"${_oc_serve_args[@]}"}
				;;
			esac
		fi
	fi
fi
# ── oldkernel crash trap (T5; OSC-001 动态取证) ───────────────────────────────
# TUI scenario (the runtime would start its interactive TUI: --force-tui, or
# no explicit CLI subcommand) no longer bare-execs. The runtime runs as a
# background job + wait (no job control in scripts -> same process group, tty
# foreground/interactivity unchanged; $! gives a pid for signal forwarding).
# stderr is captured to a temp file and replayed after exit — TUI stderr is
# crash output only, and alt-screen is already torn down by then. On SIGSEGV
# (rc=139) whose stderr carries a bun.report / OpenTUI signature, a field
# record (uname/kernel major/runtime version/timestamp/rc/stderr tail 50) is
# written to ~/.local/share/opencode1/compat-crashes/<ts>.log for
# scripts/compat/compat-collect.sh. Non-139 exits or feature-less crashes
# produce no record (noise control). TERM/HUP/INT reaching the launcher are
# forwarded to the runtime pid — exec-era signal semantics are preserved.
_oc_has_sub=0
for _a in "${_oc_args[@]}"; do
	case "$_a" in -*) ;; *) _oc_has_sub=1; break ;; esac
done
_oc_is_tui=0
if [ "$_oc_force_tui" -eq 1 ] || [ "$_oc_has_sub" -eq 0 ]; then
	_oc_is_tui=1
fi
if [ "$_oc_is_tui" -eq 1 ] && _oc_err="$(mktemp "${TMPDIR:-/tmp}/opencode-crash-stderr.XXXXXX" 2>/dev/null)"; then
	_oc_rc=0
	_oc_fwd() { [ -n "${_oc_pid:-}" ] && kill -"$1" "$_oc_pid" 2>/dev/null || true; }
	trap '_oc_fwd TERM' TERM
	trap '_oc_fwd HUP' HUP
	trap '_oc_fwd INT' INT
	"$OC_RT" ${_oc_args[@]+"${_oc_args[@]}"} 2> "$_oc_err" &
	_oc_pid=$!
	wait "$_oc_pid" || _oc_rc=$?
	trap - TERM HUP INT
	if [ -s "$_oc_err" ]; then cat "$_oc_err" >&2 || true; fi
	# crash record: SIGSEGV + bun.report/OpenTUI signature only (else silent)
	if [ "$_oc_rc" -eq 139 ] && grep -qiE 'bun\.report|opentui' "$_oc_err" 2>/dev/null; then
		_oc_ver="$("$OC_RT" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){2}' | head -n1 || true)"
		_oc_dir="$HOME/.local/share/opencode1/compat-crashes"
		_oc_log="$_oc_dir/$(date +%Y%m%d-%H%M%S)-$$.log"
		if mkdir -p "$_oc_dir" 2>/dev/null && {
			printf 'product: opencode1\n'
			printf 'timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			printf 'uname_r: %s\n' "$(uname -r)"
			printf 'kernel_major: %s\n' "$(uname -r | cut -d. -f1)"
			printf 'runtime_version: %s\n' "${_oc_ver:-unknown}"
			printf 'crash_rc: %s\n' "$_oc_rc"
			printf -- '--- stderr tail (last 50 lines) ---\n'
			tail -n 50 "$_oc_err"
		} > "$_oc_log" 2>/dev/null; then
			echo "opencode1: SIGSEGV crash record written: $_oc_log" >&2
		else
			rm -f "$_oc_log" 2>/dev/null || true
		fi
	fi
	rm -f "$_oc_err" 2>/dev/null || true
	exit "$_oc_rc"
fi
# CLI subcommands / meta flags / trap-infrastructure failure: previous exec path
exec "$OC_RT" ${_oc_args[@]+"${_oc_args[@]}"}