#!/usr/bin/env bash
# tools/maintain.sh — maintainer orchestration surface (upload fleet + cache clear engine)
#
# Modes:
#   --upload --tag TAG [--family compressed|glibc|native|both] [--versions V1,V2]
#            [--attempts N] [--nodes name,name] [--source auto|inbox|release]
#            [--dry-run] [--no-upload]
#       compressed family: multi-node UPX production reusing tools/fleet-push.py
#       semantics (its --tag/--attempts/--source contract), node-side tmux hardening,
#       resumable journal at artifacts/fleet-state.json.
#       glibc/native/both: simple sequential `gh release upload TAG --clobber`
#       from this machine (no fleet), consistent with scripts/push-stage.sh.
#   --nodes-init
#       Write artifacts/fleet-nodes.yaml template IF MISSING (never overwrites).
#   --clear [LAYERS=layer1,layer2] [CONFIRM=1] [DRY=1]
#       Cache-layer cleanup engine (shared with `make clear`).
#       No LAYERS  -> statistics only (non-destructive).
#       LAYERS=... -> destructive cleanup of exactly those layers; needs CONFIRM=1
#                     or an interactive y/N answer.
#   --sync-db
#       Refresh the unified hope2333.db.tar.gz on all 5 release CDNs (fetch the
#       CI-built db from the Pages fallback, sanity-check, clobber-upload).
#       Keeps "CDN-first, Pages-fallback" fresh without needing a CI PAT.
#
# Node config: artifacts/fleet-nodes.yaml (UNTRACKED — artifacts/ is git-ignored;
# never commit it: it carries credentials). Journal: artifacts/fleet-state.json
# (UNTRACKED, resumable per (node, version) status done/failed/pending).
#
# Safety: --dry-run prints every command that WOULD run (ssh/scp/tmux/gh) and
# never touches the network. tools/fleet-push.py is used as-is (never modified).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NODES_YAML="${MAINTAIN_NODES_YAML:-$REPO_ROOT/artifacts/fleet-nodes.yaml}"
STATE_JSON="${MAINTAIN_STATE_JSON:-$REPO_ROOT/artifacts/fleet-state.json}"
FLEET_PUSH="$REPO_ROOT/tools/fleet-push.py"
LAYERS_TSV="$REPO_ROOT/tools/clear-layers.tsv"
REPO_SLUG="${MAINTAIN_REPO:-Hope2333/opencode-termux}"
RBASE_SH='$HOME/opc-fleet'      # remote shell path (expanded node-side)
RBASE_REL="opc-fleet"           # scp destination relative to remote $HOME
POLL_SEC="${MAINTAIN_POLL_SEC:-20}"
TIMEOUT_SEC="${MAINTAIN_TIMEOUT_SEC:-7200}"
PKG_TMPL_VER="opencode-%s-1-aarch64.pkg.tar.xz"
ASSET_TMPL_VER="opencode-native-%s-upx.xz"

MODE="" TAG="" FAMILY="compressed" VERSIONS="" ATTEMPTS=3 NODES_FILTER=""
SOURCE="auto" NO_UPLOAD=0 DRY=0 LAYERS="" CONFIRM=0 AUTO_CLEAN=0

die() { echo "Error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
dry() { echo "DRY-RUN: $*"; }

usage() {
	cat <<'EOF'
tools/maintain.sh — maintainer orchestration surface

  --upload --tag TAG [--family compressed|glibc|native|both]
           [--versions V1,V2] [--attempts N] [--nodes name,name]
           [--source auto|inbox|release] [--dry-run] [--no-upload] [--auto-clean]
           (--auto-clean: after a successful upload, clean THIS build's local caches:
            npm/npx download-chain caches + build-side clear layers; packing/ untouched)
  --nodes-init
  --clear [LAYERS=a,b] [CONFIRM=1] [DRY=1]
  --sync-db
      Refresh unified hope2333.db.tar.gz on the 5 release CDNs (fetch the
      CI-built db from the Pages fallback, sanity-check >=8 entries, then
      clobber-upload; MiMoCode pinned to Push260829, others resolve latest).

Make wiring: make maintain-upload TAG=... [FAMILY=...] [VERSIONS=...] [DRY=1]
             make clear [LAYERS=...] [CONFIRM=1] [DRY=1]
EOF
}

# ─────────────────────────────── argument parsing ─────────────────────────────

while [ $# -gt 0 ]; do
	case "$1" in
	--upload) MODE="upload" ;;
	--nodes-init) MODE="nodes-init" ;;
	--clear) MODE="clear" ;;
	--sync-db) MODE="sync-db" ;;
	--auto-clean) AUTO_CLEAN=1 ;;
	--tag) TAG="${2:?--tag needs a value}"; shift ;;
	--tag=*) TAG="${1#*=}" ;;
	--family) FAMILY="${2:?--family needs a value}"; shift ;;
	--family=*) FAMILY="${1#*=}" ;;
	--versions) VERSIONS="${2:?--versions needs a value}"; shift ;;
	--versions=*) VERSIONS="${1#*=}" ;;
	--attempts) ATTEMPTS="${2:?--attempts needs a value}"; shift ;;
	--attempts=*) ATTEMPTS="${1#*=}" ;;
	--nodes) NODES_FILTER="${2:?--nodes needs a value}"; shift ;;
	--nodes=*) NODES_FILTER="${1#*=}" ;;
	--source) SOURCE="${2:?--source needs a value}"; shift ;;
	--source=*) SOURCE="${1#*=}" ;;
	--dry-run) DRY=1 ;;
	--no-upload) NO_UPLOAD=1 ;;
	LAYERS=*) LAYERS="${1#*=}" ;;
	CONFIRM=1) CONFIRM=1 ;;
	CONFIRM=0) CONFIRM=0 ;;
	DRY=1) DRY=1 ;;
	--help|-h) usage; exit 0 ;;
	*) usage >&2; die "unknown argument: $1" ;;
	esac
	shift
done
[ -n "$MODE" ] || { usage >&2; die "no mode given: use --upload, --nodes-init, --clear or --sync-db"; }
[ "$AUTO_CLEAN" = 0 ] || [ "$MODE" = "upload" ] || die "--auto-clean requires --upload (precondition: caches are only cleaned for a build this run uploaded)"

# ─────────────────────────────── nodes YAML parsing ───────────────────────────

parse_nodes() {
	# Emits records (unit-separator \x1f): name mode host port user auth slots enabled
	[ -f "$NODES_YAML" ] || die "node config missing: $NODES_YAML (run: tools/maintain.sh --nodes-init)"
	python3 - "$NODES_YAML" <<'PYEOF'
import re, sys

path = sys.argv[1]
cur = None
nodes = {}
order = []
with open(path) as f:
    for ln, raw in enumerate(f, 1):
        line = raw.rstrip("\n")
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if not line[0].isspace():
            cur = None                      # top-level key (nodes:)
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 2 and s.endswith(":"):
            cur = s[:-1]
            if not re.fullmatch(r"[A-Za-z0-9_-]+", cur):
                sys.exit(f"{path}:{ln}: bad node name {cur!r}")
            nodes[cur] = {}
            order.append(cur)
        elif indent >= 4 and cur and ":" in s:
            k, v = s.split(":", 1)
            nodes[cur][k.strip()] = v.strip().strip('"').strip("'")
        else:
            sys.exit(f"{path}:{ln}: cannot parse line: {line!r}")

for name in order:
    n = nodes[name]
    print("\x1f".join([name, n.get("mode", ""), n.get("host", ""), n.get("port", "22"),
                     n.get("user", ""), n.get("auth", ""), n.get("slots", "auto"),
                     n.get("enabled", "false")]))
PYEOF
}

ssh_prefix() { # host port user auth -> ssh command prefix (printf %q-safe)
	local host="$1" port="$2" user="$3" auth="$4"
	case "$auth" in
	sshpass:*) printf "sshpass -p %q ssh -p %s -o StrictHostKeyChecking=accept-new %s@%s" \
		"${auth#sshpass:}" "$port" "$user" "$host" ;;
	key:*) printf "ssh -i %q -p %s -o StrictHostKeyChecking=accept-new %s@%s" \
		"${auth#key:}" "$port" "$user" "$host" ;;
	*) die "node auth must be 'sshpass:PASSWORD' or 'key:/path/to/key' (got: ${auth:-<empty>})" ;;
	esac
}

scp_prefix() { # host port user auth -> scp command prefix (note scp uses -P)
	local host="$1" port="$2" user="$3" auth="$4"
	case "$auth" in
	sshpass:*) printf "sshpass -p %q scp -P %s -o StrictHostKeyChecking=accept-new" \
		"${auth#sshpass:}" "$port" ;;
	key:*) printf "scp -i %q -P %s -o StrictHostKeyChecking=accept-new" \
		"${auth#key:}" "$port" ;;
	*) die "node auth must be 'sshpass:PASSWORD' or 'key:/path/to/key'" ;;
	esac
}

sh_exec() { # ssh_prefix remote_cmd — run remote command as ONE safely-quoted arg
	if [ "$DRY" = 1 ]; then
		dry "$1 $(printf '%q' "$2")"
	else
		eval "$1 $(printf '%q' "$2")"
	fi
}

scp_exec() { # scp_prefix src dst
	if [ "$DRY" = 1 ]; then
		dry "$1 $(printf '%q' "$2") $(printf '%q' "$3")"
	else
		eval "$1 $(printf '%q' "$2") $(printf '%q' "$3")"
	fi
}

# ─────────────────────────────── state journal ────────────────────────────────

journal_set() { # tag node ver status [detail]
	python3 - "$STATE_JSON" "$1" "$2" "$3" "$4" "${5:-}" <<'PYEOF'
import datetime, json, os, sys

path, tag, node, ver, status, detail = sys.argv[1:7]
now = datetime.datetime.now().isoformat(timespec="seconds")
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
if data.get("tag") != tag:
    data = {"tag": tag, "created": now, "entries": {}}
data.setdefault("entries", {}).setdefault(node, {})[ver] = {
    "status": status, "detail": detail, "updated": now}
data["updated"] = now
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
os.replace(tmp, path)
PYEOF
}

journal_rows() { # tag -> TSV: node ver status detail
	[ -f "$STATE_JSON" ] || return 0
	python3 - "$STATE_JSON" "$1" <<'PYEOF'
import json, sys

data = json.load(open(sys.argv[1]))
if data.get("tag") != sys.argv[2]:
    raise SystemExit(0)
for node, vers in sorted(data.get("entries", {}).items()):
    for ver, e in sorted(vers.items()):
        print("\t".join([node, ver, e.get("status", ""), e.get("detail", "")]))
PYEOF
}

# ─────────────────────────────── node-side helpers ────────────────────────────

FLEET_RUN_SH='#!/bin/sh
# fleet-run.sh — gh-mode node job: run fleet-push.py under tmux, stamp per-version markers
# usage: fleet-run.sh TAG ATTEMPTS SLOTS REPO "VER1 VER2 ..."
set -u
TAG="$1"; ATT="$2"; SLOTS="$3"; REPO="$4"; VERS="$5"
BASE="$HOME/opc-fleet"
cd "$BASE" || exit 9
ARGS="--tag $TAG --attempts $ATT --source release"
[ "$SLOTS" != "auto" ] && ARGS="$ARGS --slots $SLOTS"
[ -n "$VERS" ] && ARGS="$ARGS --versions $VERS"
# shellcheck disable=SC2086
python3 "$BASE/fleet-push.py" $ARGS
rc=$?
for v in $VERS; do
  asset="opencode-native-${v}-upx.xz"
  if gh release view "$TAG" --repo "$REPO" --json assets -q ".assets[].name" 2>/dev/null | grep -qxF "$asset"; then
    : > "$BASE/state/$TAG.$v.done"
  else
    echo "rc=$rc asset-missing" > "$BASE/state/$TAG.$v.failed"
  fi
done
exit 0
'

UPX_JOB_SH='#!/bin/sh
# upx-job.sh — compute-mode node job: untar inbox pkg -> upx --best -> xz -9 -> out/
# usage: upx-job.sh TAG VER PKGNAME ASSETNAME
set -u
TAG="$1"; VER="$2"; PKG="$3"; ASSET="$4"
BASE="$HOME/opc-fleet"
R="$BASE/work/$VER"
mkdir -p "$R" "$BASE/out" "$BASE/state" "$BASE/logs"
rc=0
tar -xJf "$BASE/inbox/$PKG" -C "$R" || rc=2
B="$(find "$R" -type f -name opencode | head -1)"
[ -n "$B" ] || rc=2
if [ "$rc" -eq 0 ]; then
  upx --best -o "$R/packed.tmp" "$B" || rc=3
  if [ "$rc" -eq 0 ]; then
    xz -9 -c "$R/packed.tmp" > "$BASE/out/$ASSET" || rc=4
  fi
fi
if [ "$rc" -eq 0 ]; then
  sha256sum "$BASE/out/$ASSET" > "$BASE/state/$TAG.$VER.sha"
  : > "$BASE/state/$TAG.$VER.done"
else
  echo "rc=$rc" > "$BASE/state/$TAG.$VER.failed"
fi
rm -rf "$R"
exit 0
'

push_helper() { # ssh_prefix helper_name helper_content
	local sp="$1" name="$2" content="$3"
	if [ "$DRY" = 1 ]; then
		dry "cat $name | ($sp 'cat > $RBASE_SH/$name')"
	else
		printf '%s' "$content" | eval "$sp 'cat > $RBASE_SH/$name'"
	fi
}

# ─────────────────────────────── upload: simple path ──────────────────────────

collect_matches() { # varname glob...
	local -n out="$1"; shift
	local pat m
	for pat in "$@"; do
		for m in $pat; do
			[ -f "$m" ] && out+=("$m")
		done
	done
}

ensure_release() {
	if [ "$DRY" = 1 ]; then
		dry "gh release view $TAG --repo $REPO_SLUG   # if missing:"
		dry "gh release create $TAG --repo $REPO_SLUG --prerelease --title $TAG"
		return 0
	fi
	if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
		log "release $TAG exists"
	else
		log "release $TAG missing -> creating (prerelease)"
		gh release create "$TAG" --repo "$REPO_SLUG" --prerelease --title "$TAG"
	fi
}

upload_simple() {
	local family files_found=0
	local -a all=()
	for family in glibc native; do
		case "$FAMILY" in
		glibc) [ "$family" = glibc ] || continue ;;
		native) [ "$family" = native ] || continue ;;
		both) ;;
		esac
		if [ "$family" = glibc ]; then
			collect_matches all "$REPO_ROOT/packing/dpkg/opencode-glibc_*.deb" \
				"$REPO_ROOT/packing/pacman/opencode-glibc-*.pkg.*"
		else
			collect_matches all "$REPO_ROOT/packing/dpkg-native/opencode_*.deb" \
				"$REPO_ROOT/packing/pacman/opencode-[0-9]*.pkg.*"
		fi
	done
	[ "${#all[@]}" -gt 0 ] || die "no glibc/native package files found under packing/ (build first: make family-glibc / family-native)"
	ensure_release
	local f
	for f in "${all[@]}"; do
		log "upload $(basename "$f")"
		if [ "$DRY" = 1 ]; then
			dry "gh release upload $TAG $(printf '%q' "$f") --repo $REPO_SLUG --clobber"
		else
			gh release upload "$TAG" "$f" --repo "$REPO_SLUG" --clobber
		fi
	done
	log "simple upload complete: ${#all[@]} file(s) -> $TAG"
}

# ─────────────────────────────── upload: fleet path ───────────────────────────

resolve_versions() {
	# fills global array VERSIONS_ARR
	VERSIONS_ARR=()
	local v
	if [ -n "$VERSIONS" ]; then
		for v in $(echo "$VERSIONS" | tr ', ' '  '); do
			[ -n "$v" ] && VERSIONS_ARR+=("$v")
		done
	else
		if [ "$DRY" = 1 ]; then
			log "versions: (would discover from release $TAG assets: $PKG_TMPL_VER)"
			VERSIONS_ARR=("<discover-from-release>")
			return 0
		fi
		while IFS= read -r name; do
			case "$name" in
			opencode-*-1-aarch64.pkg.tar.xz)
				v="${name#opencode-}"; v="${v%-1-aarch64.pkg.tar.xz}"
				VERSIONS_ARR+=("$v")
				;;
			esac
		done < <(gh release view "$TAG" --repo "$REPO_SLUG" --json assets -q '.assets[].name' 2>/dev/null || true)
	fi
	[ "${#VERSIONS_ARR[@]}" -gt 0 ] || die "no versions resolved (pass --versions or check release assets of $TAG)"
}

resolve_pkg() { # ver -> prints local pkg path (downloads into fleet inbox if needed)
	local ver="$1"
	local pkg
	pkg="$(printf "$PKG_TMPL_VER" "$ver")"
	local cand
	for cand in "$REPO_ROOT/packing/pacman/$pkg" "$HOME/opc-fleet/inbox/$pkg"; do
		[ -f "$cand" ] && { echo "$cand"; return 0; }
	done
	[ "$SOURCE" = inbox ] && die "source=inbox but $pkg not found in packing/pacman or ~/opc-fleet/inbox"
	if [ "$DRY" = 1 ]; then
		dry "gh release download $TAG -p $pkg --repo $REPO_SLUG --dir ~/opc-fleet/inbox --clobber"
		echo "<download>/$pkg"
		return 0
	fi
	mkdir -p "$HOME/opc-fleet/inbox"
	gh release download "$TAG" -p "$pkg" --repo "$REPO_SLUG" --dir "$HOME/opc-fleet/inbox" --clobber
	[ -f "$HOME/opc-fleet/inbox/$pkg" ] || die "download failed: $pkg"
	echo "$HOME/opc-fleet/inbox/$pkg"
}

tmux_name() { # tag ver -> tmux-safe session name
	echo "fleet-$(echo "$1$2" | tr '.:' '__' | cut -c1-60)"
}

upload_fleet() {
	# 1) load + filter nodes
	local -a rows=()
	mapfile -t rows < <(parse_nodes)
	local -a names=() modes=() sshs=() scps=() slotss=()
	local r name mode host port user auth slots enabled sp cp
	for r in "${rows[@]}"; do
		IFS=$'\x1f' read -r name mode host port user auth slots enabled <<<"$r"
		case "$enabled" in true|True|1) ;; *) continue ;; esac
		[ -z "$NODES_FILTER" ] || case ",$NODES_FILTER," in *",$name,"*) ;; *) continue ;; esac
		case "$mode" in
		local) sp=""; cp="" ;;
		gh|compute)
			[ -n "$host" ] && [ -n "$user" ] && [ -n "$auth" ] || die "node $name: host/user/auth required for mode=$mode"
			sp="$(ssh_prefix "$host" "$port" "$user" "$auth")"
			cp="$(scp_prefix "$host" "$port" "$user" "$auth")"
			;;
		*) die "node $name: unknown mode '$mode' (local|gh|compute)" ;;
		esac
		names+=("$name"); modes+=("$mode"); sshs+=("$sp"); scps+=("$cp"); slotss+=("${slots:-auto}")
	done
	[ ${#names[@]} -gt 0 ] || die "no enabled nodes in $NODES_YAML (run --nodes-init, then edit + enable)"

	# 2) resolve versions + round-robin assignment across enabled nodes
	resolve_versions
	local -a assign_names=()
	declare -A ASSIGN=()
	local i=0 vi
	for vi in "${!VERSIONS_ARR[@]}"; do
		name="${names[$((vi % ${#names[@]}))]}"
		ASSIGN[$name]="${ASSIGN[$name]:-} ${VERSIONS_ARR[$vi]}"
	done
	for name in "${names[@]}"; do
		assign_names+=("$name")
	done

	# 3) journal: pending for every (node, version)
	for name in "${names[@]}"; do
		for v in ${ASSIGN[$name]:-}; do
			journal_set "$TAG" "$name" "$v" "pending"
		done
	done

	log "fleet plan: tag=$TAG family=compressed attempts=$ATTEMPTS source=$SOURCE nodes=[${names[*]}] versions=[${VERSIONS_ARR[*]}]"
	[ "$DRY" = 1 ] && log "dry-run: no ssh/scp/gh/tmux commands will be executed"

	# 4) dispatch per node
	declare -A RUNNING=()          # "node|ver" -> 1
	declare -A ATTEMPT=()
	local idx
	for idx in "${!names[@]}"; do
		name="${names[$idx]}"
		mode="${modes[$idx]}"
		sp="${sshs[$idx]}"
		cp="${scps[$idx]}"
		slots="${slotss[$idx]}"
		[ -n "${ASSIGN[$name]:-}" ] || continue
		case "$mode" in
		local)
			local args=(--tag "$TAG" --attempts "$ATTEMPTS" --source "$SOURCE")
			[ "$slots" != auto ] && args+=(--slots "$slots")
			args+=(--versions ${ASSIGN[$name]})
			log "node $name (local): python3 tools/fleet-push.py ${args[*]}"
			if [ "$DRY" = 1 ]; then
				dry "python3 $FLEET_PUSH ${args[*]}"
				for v in ${ASSIGN[$name]}; do journal_set "$TAG" "$name" "$v" "pending" "dry-run"; done
			else
				if python3 "$FLEET_PUSH" "${args[@]}"; then
					for v in ${ASSIGN[$name]}; do journal_set "$TAG" "$name" "$v" "done" "fleet-push exit 0"; done
				else
					rc=$?
					for v in ${ASSIGN[$name]}; do journal_set "$TAG" "$name" "$v" "failed" "fleet-push exit $rc"; done
				fi
			fi
			;;
		gh)
			sh_exec "$sp" "mkdir -p $RBASE_SH/inbox $RBASE_SH/out $RBASE_SH/state $RBASE_SH/logs"
			scp_exec "$cp" "$FLEET_PUSH" "$user@$host:$RBASE_REL/fleet-push.py"
			push_helper "$sp" "fleet-run.sh" "$FLEET_RUN_SH"
			local vers="${ASSIGN[$name]# }"
			local sess
			sess="$(tmux_name "$TAG" "$name")"
			sh_exec "$sp" "tmux kill-session -t $sess 2>/dev/null; tmux new-session -d -s $sess 'sh $RBASE_SH/fleet-run.sh $TAG $ATTEMPTS $slots $REPO_SLUG \"$vers\" > $RBASE_SH/logs/run.$TAG.log 2>&1'"
			for v in $vers; do RUNNING["$name|$v"]=1; ATTEMPT["$name|$v"]=1; done
			;;
		compute)
			sh_exec "$sp" "mkdir -p $RBASE_SH/inbox $RBASE_SH/out $RBASE_SH/state $RBASE_SH/logs $RBASE_SH/work"
			push_helper "$sp" "upx-job.sh" "$UPX_JOB_SH"
			# inputs are shipped lazily in the poll loop (slots-bounded)
			;;
		esac
	done

	# 5) poll loop for remote nodes (tmux-hardened; orchestrator polls markers)
	if [ "$DRY" = 1 ]; then
		for idx in "${!names[@]}"; do
			name="${names[$idx]}"; mode="${modes[$idx]}"; sp="${sshs[$idx]}"; cp="${scps[$idx]}"; slots="${slotss[$idx]}"
			case "$mode" in
			gh)
				for v in ${ASSIGN[$name]:-}; do
					dry "poll: $sp 'ls -1 $RBASE_SH/state/' -> $TAG.$v.{done,failed}"
				done
				;;
			compute)
				for v in ${ASSIGN[$name]:-}; do
					local pkg asset
					pkg="$(printf "$PKG_TMPL_VER" "$v")"
					asset="$(printf "$ASSET_TMPL_VER" "$v")"
					dry "resolve_pkg $v (local or gh release download)"
					dry "$cp <pkg> $user@$host:$RBASE_REL/inbox/"
					local sess
					sess="$(tmux_name "$TAG" "$v")"
					dry "$sp 'tmux kill-session -t $sess 2>/dev/null; tmux new-session -d -s $sess \"sh $RBASE_SH/upx-job.sh $TAG $v $pkg $asset >> $RBASE_SH/logs/$v.log 2>&1\"'"
					dry "poll: $sp 'ls -1 $RBASE_SH/state/' -> $TAG.$v.{done,failed}"
					dry "$cp $user@$host:$RBASE_REL/out/$asset packing/fleet/$asset"
					[ "$NO_UPLOAD" = 1 ] || dry "gh release upload $TAG packing/fleet/$asset --repo $REPO_SLUG --clobber"
				done
				;;
			esac
		done
		log "dry-run fleet plan complete (journal written with pending entries)"
		return 0
	fi

	trap 'echo; echo "Interrupted: journal preserved at $STATE_JSON — rerun the same command to resume."; exit 130' INT TERM
	local started=$SECONDS
	local progress=1
	while [ "$progress" = 1 ]; do
		progress=0
		local key
		for key in "${!RUNNING[@]}"; do
			[ -n "${RUNNING[$key]:-}" ] || continue
			local n="${key%%|*}" v="${key#*|}"
			# find node record
			local nidx=-1 j
			for j in "${!names[@]}"; do [ "${names[$j]}" = "$n" ] && nidx=$j; done
			[ "$nidx" -ge 0 ] || { RUNNING[$key]=""; continue; }
			sp="${sshs[$nidx]}"; cp="${scps[$nidx]}"; mode="${modes[$nidx]}"
			local markers
			markers="$(sh_exec "$sp" "ls -1 $RBASE_SH/state/ 2>/dev/null" || true)"
			local asset
			asset="$(printf "$ASSET_TMPL_VER" "$v")"
			if echo "$markers" | grep -qxF "$TAG.$v.done"; then
				if [ "$mode" = compute ]; then
					mkdir -p "$REPO_ROOT/packing/fleet"
					scp_exec "$cp" "$user@$host:$RBASE_REL/out/$asset" "$REPO_ROOT/packing/fleet/$asset"
					local sha
					sha="$(sha256sum "$REPO_ROOT/packing/fleet/$asset" | cut -d' ' -f1)"
					grep -qF "  $asset" "$REPO_ROOT/packing/fleet/SHA256SUMS.txt" 2>/dev/null || \
						echo "$sha  $asset" >> "$REPO_ROOT/packing/fleet/SHA256SUMS.txt"
					[ "$NO_UPLOAD" = 1 ] || gh release upload "$TAG" "$REPO_ROOT/packing/fleet/$asset" --repo "$REPO_SLUG" --clobber
					sh_exec "$sp" "rm -f $RBASE_SH/out/$asset"
					journal_set "$TAG" "$n" "$v" "done" "sha256=$sha"
				else
					journal_set "$TAG" "$n" "$v" "done" "uploaded by node"
				fi
				log "node $n version $v: DONE"
				RUNNING[$key]=""
				continue
			fi
			if echo "$markers" | grep -qxF "$TAG.$v.failed"; then
				local att="${ATTEMPT[$key]:-1}"
				if [ "$att" -lt "$ATTEMPTS" ]; then
					log "node $n version $v: failed (attempt $att/$ATTEMPTS) -> retrying"
					sh_exec "$sp" "rm -f $RBASE_SH/state/$TAG.$v.failed $RBASE_SH/state/$TAG.$v.done"
					local sess
					if [ "$mode" = compute ]; then
						local pkg
						pkg="$(printf "$PKG_TMPL_VER" "$v")"
						sess="$(tmux_name "$TAG" "$v")"
						sh_exec "$sp" "tmux kill-session -t $sess 2>/dev/null; tmux new-session -d -s $sess \"sh $RBASE_SH/upx-job.sh $TAG $v $pkg $asset >> $RBASE_SH/logs/$v.log 2>&1\""
					else
						local vers_all="${ASSIGN[$n]# }"
						sess="$(tmux_name "$TAG" "$n")"
						sh_exec "$sp" "tmux kill-session -t $sess 2>/dev/null; tmux new-session -d -s $sess 'sh $RBASE_SH/fleet-run.sh $TAG $ATTEMPTS $slots $REPO_SLUG \"$vers_all\" >> $RBASE_SH/logs/run.$TAG.log 2>&1'"
					fi
					ATTEMPT[$key]=$((att + 1))
				else
					journal_set "$TAG" "$n" "$v" "failed" "attempts exhausted ($ATTEMPTS)"
					log "node $n version $v: FAILED (attempts exhausted)"
					RUNNING[$key]=""
				fi
				continue
			fi
			# still running
			progress=1
		done
		# compute-mode: launch pending versions within node slots
		for idx in "${!names[@]}"; do
			name="${names[$idx]}"; mode="${modes[$idx]}"; sp="${sshs[$idx]}"; cp="${scps[$idx]}"; slots="${slotss[$idx]}"
			[ "$mode" = compute ] || continue
			[ -n "${ASSIGN[$name]:-}" ] || continue
			local running_count=0
			for key in "${!RUNNING[@]}"; do
				case "$key" in "$name|"*) [ -n "${RUNNING[$key]:-}" ] && running_count=$((running_count + 1)) ;; esac
			done
			[ "$slots" = auto ] && slots=2
			for v in ${ASSIGN[$name]}; do
				[ "$running_count" -lt "$slots" ] || break
				key="$name|$v"
				[ -n "${RUNNING[$key]:-}" ] && continue
				journal_set "$TAG" "$name" "$v" "running"
				local pkg asset sess
				pkg="$(printf "$PKG_TMPL_VER" "$v")"
				asset="$(printf "$ASSET_TMPL_VER" "$v")"
				local pkg_path
				pkg_path="$(resolve_pkg "$v")"
				scp_exec "$cp" "$pkg_path" "$user@$host:$RBASE_REL/inbox/"
				sess="$(tmux_name "$TAG" "$v")"
				sh_exec "$sp" "tmux kill-session -t $sess 2>/dev/null; tmux new-session -d -s $sess \"sh $RBASE_SH/upx-job.sh $TAG $v $pkg $asset >> $RBASE_SH/logs/$v.log 2>&1\""
				RUNNING[$key]=1; ATTEMPT[$key]=1
				running_count=$((running_count + 1))
				progress=1
			done
		done
		[ "$progress" = 1 ] || break
		if [ $((SECONDS - started)) -gt "$TIMEOUT_SEC" ]; then
			die "timeout after ${TIMEOUT_SEC}s — journal preserved at $STATE_JSON; rerun to resume"
		fi
		sleep "$POLL_SEC"
	done
	log "fleet run complete: journal at $STATE_JSON"
}

cmd_upload() {
	[ -n "$TAG" ] || die "--upload requires --tag TAG"
	case "$FAMILY" in
	compressed) upload_fleet ;;
	glibc|native|both) upload_simple ;;
	*) die "invalid --family '$FAMILY' (compressed|glibc|native|both)" ;;
	esac
	if [ "$AUTO_CLEAN" = 1 ]; then
		if [ "$NO_UPLOAD" = 1 ] || [ "$DRY" = 1 ]; then
			log "auto-clean skipped (dry-run/no-upload rehearsal)"
		else
			auto_clean
		fi
	fi
}

# ─────────────────────────────── nodes-init ───────────────────────────────────

cmd_nodes_init() {
	if [ -e "$NODES_YAML" ]; then
		die "refusing to overwrite existing $NODES_YAML"
	fi
	mkdir -p "$(dirname "$NODES_YAML")"
	cat > "$NODES_YAML" <<'EOF'
# artifacts/fleet-nodes.yaml — maintainer fleet node config
# UNTRACKED: artifacts/ is git-ignored. NEVER commit this file (credentials live here).
# Regenerate: tools/maintain.sh --nodes-init  (never overwrites an existing file)
#
# Per-node fields:
#   host:    hostname or IP (required for gh/compute modes)
#   port:    SSH port (default 22)
#   user:    SSH user
#   auth:    "sshpass:PASSWORD" (password via sshpass) or "key:/path/to/private_key"
#   mode:    gh      — node has gh auth; it fetches release assets itself, runs
#                      tools/fleet-push.py remotely (under tmux) and uploads results
#            compute — node only does UPX compute; the make machine ships inputs via
#                      scp, pulls outputs back, and performs all gh operations
#            local   — run tools/fleet-push.py directly on this machine
#   slots:   parallel slots on the node (integer or auto)
#   enabled: true / false
nodes:
  local:
    mode: local
    slots: auto
    enabled: true
  miao1:
    host: 192.168.1.20
    port: 22
    user: u0_a258
    auth: "sshpass:CHANGE_ME"
    mode: gh
    slots: 2
    enabled: false
  miao2:
    host: 192.168.1.21
    port: 22
    user: u0_a258
    auth: "key:/path/to/id_ed25519"
    mode: compute
    slots: 4
    enabled: false
EOF
	log "wrote $NODES_YAML (template; edit hosts/auth, then set enabled: true)"
}

# ─────────────────────────── auto-clean (post-upload) ────────────────────────

NPM_BUILD_LAYERS="npm-cacache npx-cache gh-download-cache tmp-smoke transplant-work compressed-work staged-trees makepkg-temp dpkg-work"

auto_clean() {
	# npm/npx download-chain caches (npm pack / npx during build)
	local npm_cache freed=0 b
	npm_cache="$(npm config get cache 2>/dev/null || true)"
	if [ -n "$npm_cache" ] && [ -e "$npm_cache" ]; then
		npm cache clean --force >/dev/null 2>&1 || true
	fi
	[ -e "$HOME/.npm/_npx" ] && rm -rf "$HOME/.npm/_npx"
	[ -e "$HOME/.npm/_cacache" ] && rm -rf "$HOME/.npm/_cacache"
	# build-side cache layers via the clear engine (packing/ deliverables untouched)
	load_layers
	local i
	for i in "${!L_NAME[@]}"; do
		case " $NPM_BUILD_LAYERS " in
		*" ${L_NAME[$i]} "*)
			b="$(layer_bytes "${L_KIND[$i]}" ${L_PATHS[$i]})"
			while IFS= read -r p; do
				[ -n "$p" ] && rm -rf "$p"
			done < <(layer_expand "${L_KIND[$i]}" ${L_PATHS[$i]})
			freed=$((freed + b))
			;;
		esac
	done
	log "auto-clean: freed $freed bytes (npm/npx caches + build cache layers); packing/ deliverables untouched"
}

# ─────────────────────────────── clear engine ─────────────────────────────────

human_bytes() {
	awk '{
		b = $1 + 0
		if (b >= 1073741824) printf "%.1fG", b / 1073741824
		else if (b >= 1048576) printf "%.1fM", b / 1048576
		else if (b >= 1024) printf "%.1fK", b / 1024
		else printf "%dB", b
	}'
}

layer_expand() { # kind paths... -> existing paths, one per line
	local kind="$1"; shift
	local p m base
	case "$kind" in
	dir|glob)
		for p in "$@"; do
			p="${p/#\~/$HOME}"
			for m in $p; do [ -e "$m" ] && echo "$m"; done
		done
		;;
	tmp)
		base="${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}"
		for p in "$@"; do
			for m in $base/$p; do [ -e "$m" ] && echo "$m"; done
		done
		;;
	transplant)
		local d f
		for d in "$REPO_ROOT"/artifacts/transplant/*/; do
			[ -d "$d" ] || continue
			for f in module-graph.bin opencode-native-revived *.pre-crhandler *.strip.so; do
				[ -e "$d$f" ] && echo "$d$f"
			done
		done
		;;
	esac
}

layer_bytes() { # kind paths... -> total bytes
	local kind="$1"; shift
	local total=0 p b
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		b="$(du -sb "$p" 2>/dev/null | cut -f1 || echo 0)"
		total=$((total + ${b:-0}))
	done < <(layer_expand "$kind" "$@")
	echo "$total"
}

load_layers() { # -> arrays L_NAME L_KIND L_PATHS L_DESC
	L_NAME=(); L_KIND=(); L_PATHS=(); L_DESC=()
	local line name kind paths desc
	while IFS=$'\t' read -r name kind paths desc; do
		[[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
		L_NAME+=("$name"); L_KIND+=("$kind"); L_PATHS+=("$paths"); L_DESC+=("$desc")
	done < "$LAYERS_TSV"
}

cmd_clear() {
	load_layers
	[ ${#L_NAME[@]} -gt 0 ] || die "layer index empty: $LAYERS_TSV"

	# resolve all paths relative to repo root (CWD may differ)
	cd "$REPO_ROOT"

	load_layers
	[ ${#L_NAME[@]} -gt 0 ] || die "layer index empty: $LAYERS_TSV"

	if [ -z "$LAYERS" ]; then
		# statistics only (non-destructive)
		echo "== clear: cache layer statistics (read-only; nothing deleted) =="
		local i total=0 b
		printf "%-18s %12s %8s  %s\n" "layer" "bytes" "human" "description"
		for i in "${!L_NAME[@]}"; do
			b="$(layer_bytes "${L_KIND[$i]}" ${L_PATHS[$i]})"
			total=$((total + b))
			printf "%-18s %12s %8s  %s\n" "${L_NAME[$i]}" "$b" "$(echo "$b" | human_bytes)" "${L_DESC[$i]}"
		done
		printf "%-18s %12s %8s\n" "TOTAL" "$total" "$(echo "$total" | human_bytes)"
		echo "nothing deleted. destructive run: make clear LAYERS=<layer[,layer...]> CONFIRM=1"
		echo "layers: ${L_NAME[*]}"
		return 0
	fi

	# validate requested layers
	local -a want
	mapfile -t want < <(echo "$LAYERS" | tr ', ' '  ' | tr -s ' ' '\n' | grep -v '^$' || true)
	[ ${#want[@]} -gt 0 ] || die "LAYERS is empty"
	local w i found
	declare -A SEL=()
	for w in "${want[@]}"; do
		found=0
		for i in "${!L_NAME[@]}"; do
			[ "${L_NAME[$i]}" = "$w" ] && { found=1; SEL[$w]=$i; break; }
		done
		[ "$found" = 1 ] || die "unknown layer '$w' (valid: ${L_NAME[*]})"
	done

	# confirm gate (skip in dry-run mode)
	if [ "$CONFIRM" != 1 ] && [ "$DRY" != 1 ]; then
		if [ -t 0 ]; then
			local total=0 b
			for w in "${!SEL[@]}"; do
				i="${SEL[$w]}"
				b="$(layer_bytes "${L_KIND[$i]}" ${L_PATHS[$i]})"
				total=$((total + b))
			done
			printf "About to DELETE layers: %s\nReclaimable: %s bytes\nProceed? [y/N] " "${want[*]}" "$total"
			local ans
			read -r ans
			case "$ans" in
			y|Y|yes|YES) ;;
			*) echo "aborted (nothing deleted)"; exit 1 ;;
			esac
		else
			die "refusing to delete without CONFIRM=1 (non-interactive)"
		fi
	fi

	# destructive pass
	local freed=0 b
	for w in "${want[@]}"; do
		i="${SEL[$w]}"
		b="$(layer_bytes "${L_KIND[$i]}" ${L_PATHS[$i]})"
		if [ "$DRY" = 1 ]; then
			while IFS= read -r p; do
				[ -n "$p" ] && dry "rm -rf $(printf '%q' "$p")"
			done < <(layer_expand "${L_KIND[$i]}" ${L_PATHS[$i]})
			printf "layer %-18s would free %12s bytes (%s)\n" "$w" "$b" "$(echo "$b" | human_bytes)"
			continue
		fi
		case "${L_KIND[$i]}" in
		transplant)
			local kept=0 kept_list=""
			while IFS= read -r p; do
				[ -n "$p" ] || continue
				rm -f "$p"
			done < <(layer_expand transplant)
			# report preserved files
			local d f
			for d in "$REPO_ROOT"/artifacts/transplant/*/; do
				[ -d "$d" ] || continue
				for f in opencode-native-tui libopencode-crhandler.so report.json; do
					if [ -e "$d$f" ]; then
						kept=$((kept + 1)); kept_list="$kept_list ${d#$REPO_ROOT/}$f"
					fi
				done
			done
			printf "layer %-18s freed %12s bytes (%s); preserved:%s\n" "$w" "$b" "$(echo "$b" | human_bytes)" "${kept_list:- (none present)}"
			;;
		*)
			while IFS= read -r p; do
				[ -n "$p" ] || continue
				rm -rf "$p"
			done < <(layer_expand "${L_KIND[$i]}" ${L_PATHS[$i]})
			printf "layer %-18s freed %12s bytes (%s)\n" "$w" "$b" "$(echo "$b" | human_bytes)"
			;;
		esac
		freed=$((freed + b))
	done
	log "clear complete: freed $freed bytes total across ${#want[@]} layer(s)"
}

# ─────────────────────────────── sync-db ──────────────────────────────────────
# Refresh the unified hope2333.db.tar.gz on all 5 release CDNs: fetch the
# CI-built db from the Pages fallback (canonical), sanity-check, clobber-upload.
# MiMoCode pinned to Push260829 (prerelease channel — GitHub forbids prerelease
# Latest); the other four resolve latest at runtime (future-proof vs tag churn).
cmd_sync_db() {
	local tmp n r t fail=0
	tmp="${TMPDIR:-/tmp}/hope2333.db.tar.gz"
	if [ "$DRY" = 1 ]; then
		dry "curl -fsSL 'https://hope2333.github.io/repo/Termux/pacman/hope2333.db.tar.gz' -> $tmp (expect >=8 entries)"
		dry "gh release upload <tag> -R Hope2333/<repo> $tmp --clobber  (5 repos: 4 latest-resolved + MiMoCode@Push260829)"
		return 0
	fi
	log "fetch unified db from Pages fallback"
	curl -fsSL "https://hope2333.github.io/repo/Termux/pacman/hope2333.db.tar.gz?v=$(date +%s)" -o "$tmp" \
		|| die "fetch unified db from Pages failed"
	n=$(tar -tzf "$tmp" 2>/dev/null | grep -c '/desc$' || true)
	[ "${n:-0}" -ge 8 ] || die "unified db looks wrong (entries=${n:-0}, expect >=8) — refusing to publish"
	log "unified db OK: ${n} entries, $(wc -c <"$tmp") bytes"
	local repos=(codegraph-termux opencode-termux freebuff-termux codebuff-termux)
	for r in "${repos[@]}"; do
		t=$(gh api "repos/Hope2333/$r/releases/latest" --jq .tag_name) \
			|| { echo "Error: resolve latest failed: $r" >&2; fail=1; continue; }
		if gh release upload "$t" -R "Hope2333/$r" "$tmp" --clobber >/dev/null 2>&1; then
			log "synced hope2333.db.tar.gz -> $r@$t"
		else
			echo "Error: sync failed -> $r@$t" >&2
			fail=1
		fi
	done
	t="Push260829"
	if gh release upload "$t" -R "Hope2333/MiMoCode-Termux" "$tmp" --clobber >/dev/null 2>&1; then
		log "synced hope2333.db.tar.gz -> MiMoCode-Termux@$t"
	else
		echo "Error: sync failed -> MiMoCode-Termux@$t" >&2
		fail=1
	fi
	rm -f "$tmp"
	[ "$fail" -eq 0 ] || die "sync-db finished with failures"
	log "sync-db complete: unified db refreshed on 5 release CDNs"
}

# ─────────────────────────────── dispatch ─────────────────────────────────────

case "$MODE" in
upload) cmd_upload ;;
nodes-init) cmd_nodes_init ;;
clear) cmd_clear ;;
sync-db) cmd_sync_db ;;
esac
