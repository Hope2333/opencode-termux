#!/data/data/com.termux/files/usr/bin/bash
# compat-collect.sh — oldkernel-compat T5: crash records -> ledger-entry drafts.
#
# Scans ~/.local/share/opencode*/compat-crashes/*.log (field records written by
# the launcher crash trap, see scripts/opencode1-launcher.sh and
# scripts/opencode-launcher.sh) and emits one .omo/compat-ledger.jsonl-schema
# draft per record as a single jsonl line on stdout (pipeable through jq).
#
# Unknown schema fields stay null — observed facts only, nothing is guessed;
# the full stderr tail lives in the evidence file itself (recorded verbatim by
# the trap). Human review turns a draft into a real ledger entry by filling
# id/first_bad/last_good/verdict from reproducible experiments.
#
# Usage: bash scripts/compat/compat-collect.sh | jq .
set -euo pipefail

shopt -s nullglob
_logs=("$HOME"/.local/share/opencode*/compat-crashes/*.log)
if [ "${#_logs[@]}" -eq 0 ]; then
	echo "compat-collect: no crash records under ~/.local/share/opencode*/compat-crashes/" >&2
	exit 0
fi

for _log in "${_logs[@]}"; do
	_product='' _ts='' _uname='' _kmajor='' _ver='' _crc='' _in_tail=0
	# record format: "key: value" header lines, then a "---" marker followed
	# by the verbatim stderr tail (not parsed).
	while IFS= read -r _line; do
		[ "$_in_tail" -eq 1 ] && continue
		case "$_line" in
			---*) _in_tail=1 ;;
			product:*) _product="${_line#product: }" ;;
			timestamp:*) _ts="${_line#timestamp: }" ;;
			uname_r:*) _uname="${_line#uname_r: }" ;;
			kernel_major:*) _kmajor="${_line#kernel_major: }" ;;
			runtime_version:*) _ver="${_line#runtime_version: }" ;;
			crash_rc:*) _crc="${_line#crash_rc: }" ;;
		esac
	done < "$_log"
	# symptom: factual summary derived from observed record fields only
	_symptom="TUI SIGSEGV (rc=${_crc:-unknown}) on kernel ${_uname:-unknown}, runtime ${_ver:-unknown}"
	_sig="$(grep -ihm1 -E 'bun\.report|opentui' "$_log" 2>/dev/null | head -c 120 || true)"
	_notes="collected from crash record: product=${_product:-unknown} kernel_major=${_kmajor:-unknown} timestamp=${_ts:-unknown} signature=${_sig:-none}"
	jq -n -c \
		--arg symptom "$_symptom" \
		--arg evidence "$_log" \
		--arg notes "$_notes" '
		{
			id: null,
			match: { kernel_max: null, opentui_min: null, symptom: $symptom },
			first_bad: null,
			last_good: null,
			verdict: null,
			evidence: $evidence,
			repro: null,
			upstream: null,
			notes: $notes
		}'
done
