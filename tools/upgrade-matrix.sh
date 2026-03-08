#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

TARGET_HOST="${TARGET_HOST:-192.168.1.22}"
TARGET_PORT="${TARGET_PORT:-8022}"
TARGET_USER="${TARGET_USER:-u0_a258}"
TARGET_HOME="/data/data/com.termux/files/home"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ODIR="${ODIR:-$REPO_DIR/packing/deb}"
VERS="${VERS:-}"
PKG_NAME="${PKG_NAME:-opencode}"

log() { printf '[upgrade-matrix] %s\n' "$*"; }
die() {
	printf '[upgrade-matrix] ERROR: %s\n' "$*" >&2
	exit 1
}

expand_versions() {
	local token base start end i
	local out=()
	for token in $VERS; do
		if [[ "$token" =~ ^([0-9]+\.[0-9]+)\.\[([0-9]+)-([0-9]+)\]$ ]]; then
			base="${BASH_REMATCH[1]}"
			start="${BASH_REMATCH[2]}"
			end="${BASH_REMATCH[3]}"
			for ((i = start; i <= end; i++)); do out+=("$base.$i"); done
		else
			out+=("$token")
		fi
	done
	printf '%s\n' "${out[@]}"
}

find_deb() {
	local ver="$1"
	local c
	for c in \
		"$ODIR/${PKG_NAME}_${ver}_aarch64.deb" \
		"$ODIR/${PKG_NAME}_${ver}_arm64.deb" \
		"$REPO_DIR/packaging/dpkg/${PKG_NAME}_${ver}_aarch64.deb"; do
		[[ -f "$c" ]] && {
			printf '%s' "$c"
			return 0
		}
	done
	return 1
}

validate_deb_payload() {
	local deb_file="$1"
	local listing
	listing="$(dpkg-deb -c "$deb_file" 2>/dev/null || true)"
	[[ -n "$listing" ]] || die "cannot read deb payload: $deb_file"
	if ! printf '%s\n' "$listing" | grep -q '/usr/lib/opencode/runtime/opencode$'; then
		die "invalid deb payload (missing /usr/lib/opencode/runtime/opencode): $deb_file"
	fi
}

ssh_exec() {
	local cmd="$1"
	sshpass -p 0 ssh -o StrictHostKeyChecking=no -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "bash -s" <<EOF
$cmd
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	cat <<EOF
Usage:
  VERS='1.2.8 1.2.9 1.2.10' tools/upgrade-matrix.sh
  VERS='1.1.[1-20]' ODIR=/path/to/debs tools/upgrade-matrix.sh
EOF
	exit 0
fi

[[ -n "$VERS" ]] || die "VERS must be set"
command -v sshpass >/dev/null 2>&1 || die "missing sshpass"

versions=()
mapfile -t versions < <(expand_versions)
[[ ${#versions[@]} -gt 0 ]] || die "no versions expanded"

debs=()
remote_names=()
for v in "${versions[@]}"; do
	d="$(find_deb "$v" || true)"
	[[ -n "$d" ]] || die "missing cached deb for version $v under ODIR=$ODIR"
	validate_deb_payload "$d"
	debs+=("$d")
	remote_names+=("$TARGET_HOME/$(basename "$d")")
done

for d in "${debs[@]}"; do
	log "copying cached artifact: $d"
	sshpass -p 0 scp -P "$TARGET_PORT" -o StrictHostKeyChecking=no "$d" "$TARGET_USER@$TARGET_HOST:$TARGET_HOME/"
done

first_name="${remote_names[0]}"
last_name="${remote_names[${#remote_names[@]} - 1]}"
logfile="$TARGET_HOME/${PKG_NAME}-upgrade-matrix-$(date +%Y%m%d-%H%M%S).log"

ssh_exec "set -euo pipefail; dpkg --audit >/dev/null 2>&1 || true; apt -f install -y >/dev/null 2>&1 || true; exec > >(tee -a $logfile) 2>&1; echo LOG=$logfile; echo === baseline install ===; apt install -y $first_name; $PKG_NAME --version || true"
ssh_exec "set -euo pipefail; hr=/data/data/com.termux/files/usr/lib/opencode/tools/run-system-skills.sh; if [[ -x \"\$hr\" ]]; then OPENCODE_HOOK_STRICT=0 OPENCODE_HOOK_ENABLE_NETWORK=0 \"\$hr\" post_install || true; fi"

for n in "${remote_names[@]}"; do
	ssh_exec "set -euo pipefail; echo === upgrade/install $(basename "$n") ===; apt install -y $n; $PKG_NAME --version || true; $PKG_NAME run hi >/dev/null 2>&1 || true"
	ssh_exec "set -euo pipefail; hr=/data/data/com.termux/files/usr/lib/opencode/tools/run-system-skills.sh; if [[ -x \"\$hr\" ]]; then OPENCODE_HOOK_STRICT=0 OPENCODE_HOOK_ENABLE_NETWORK=0 \"\$hr\" post_upgrade || true; fi"
done

ssh_exec "set -euo pipefail; echo === downgrade latest to first ===; apt install -y $first_name; $PKG_NAME --version || true; echo === reinstall latest ===; apt install -y --reinstall $last_name; $PKG_NAME --version || true; echo === final state ===; dpkg -l | grep -E '^(ii|hi)\\s+($PKG_NAME|glibc|openssl-glibc|glibc-runner)' || true; echo MATRIX_DONE"

log "matrix complete; remote log: $logfile"
