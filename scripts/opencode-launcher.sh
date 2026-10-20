#!/data/data/com.termux/files/usr/bin/bash
# opencode launcher — v2 compressed family (opencode-compressed).
#
# Derived from scripts/opencode1-launcher.sh (v1 family) with two v2-era
# removals:
# - No XDG re-root: the v2 compressed variant is the SAME generation as the
#   v2 native mainline, so it shares the plain roots (~/.config/opencode).
#   The XDG_*_HOME isolation is a cross-generation (v1-vs-v2) measure only.
# - No per-generation service-port injection: with same-generation mutual
#   exclusion (Conflicts: opencode) there is at most one v2 provider
#   installed, so the stock default port 49374 is correct. The 49376
#   port-split is a cross-generation coexistence measure, not needed here.
#
# Kept from the v1 launcher:
# - LD_LIBRARY_PATH covering the layered runtime (lib/opencode/runtime/) and
#   the shim root (lib/opencode/): the UPX stub maps segments under
#   /memfd:upx where DT_RUNPATH $ORIGIN resolution dies, so the dynamic
#   linker needs the explicit path to libopencode-crhandler.so.
# - BUN_PTY_LIB injection (optional asset, backward compatible): when the
#   package ships the patched musl librust_pty (bun-pty 0.4.11 splice — see
#   tools/bun-pty-splice/ and docs/compressed-line.md), point bun-pty's
#   probe at it. Absent asset = no export, graceful degradation.
set -euo pipefail
P="${PREFIX:-/data/data/com.termux/files/usr}"
export LD_LIBRARY_PATH="$P/lib/opencode:$P/lib/opencode/pty${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ -f "$P/lib/opencode/pty/librust_pty_arm64_musl_patched.so" ]; then
	export BUN_PTY_LIB="$P/lib/opencode/pty/librust_pty_arm64_musl_patched.so"
fi

OC_RT="$P/lib/opencode/runtime/opencode"
if [ ! -x "$OC_RT" ]; then
	echo "opencode: runtime not found under $P/lib/opencode/runtime" >&2
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
# bare `opencode` starts the TUI. Absent marker = A 档 package: the T4
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
# written to ~/.local/share/opencode/compat-crashes/<ts>.log (v2 plain data
# root) for scripts/compat/compat-collect.sh. Non-139 exits or feature-less
# crashes produce no record (noise control). TERM/HUP/INT reaching the
# launcher are forwarded to the runtime pid — exec-era signal semantics kept.
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
		_oc_dir="$HOME/.local/share/opencode/compat-crashes"
		_oc_log="$_oc_dir/$(date +%Y%m%d-%H%M%S)-$$.log"
		if mkdir -p "$_oc_dir" 2>/dev/null && {
			printf 'product: opencode\n'
			printf 'timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			printf 'uname_r: %s\n' "$(uname -r)"
			printf 'kernel_major: %s\n' "$(uname -r | cut -d. -f1)"
			printf 'runtime_version: %s\n' "${_oc_ver:-unknown}"
			printf 'crash_rc: %s\n' "$_oc_rc"
			printf -- '--- stderr tail (last 50 lines) ---\n'
			tail -n 50 "$_oc_err"
		} > "$_oc_log" 2>/dev/null; then
			echo "opencode: SIGSEGV crash record written: $_oc_log" >&2
		else
			rm -f "$_oc_log" 2>/dev/null || true
		fi
	fi
	rm -f "$_oc_err" 2>/dev/null || true
	exit "$_oc_rc"
fi
# CLI subcommands / meta flags / trap-infrastructure failure: previous exec path
exec "$OC_RT" ${_oc_args[@]+"${_oc_args[@]}"}