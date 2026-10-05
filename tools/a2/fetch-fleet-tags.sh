#!/data/data/com.termux/files/usr/bin/bash
# fetch-fleet-tags.sh — one-shot: single upstream clone + per-tag shallow fetch.
# Written for task-30 fleet build (v1 1.18.30-34 + v2 2.0.0-2.0.22).
#
# Why per-tag shallow fetch instead of `git clone --depth=1 --branch <tag>`:
# a single clone dir reused across all 28 versions (task instruction: "单份上游
# clone + 逐版 git checkout <tag>"). Each tag is fetched as its own shallow
# commit, so `git checkout <tag>` never needs history and the .git stays small
# (no 2.7GB full-history pack on a 17G-free disk).
set -uo pipefail

SRC="${SRC:-${TMPDIR:-/data/data/com.termux/files/usr/tmp}/a2-src/opencode-fleet}"
REMOTE="${REMOTE:-https://github.com/anomalyco/opencode}"

TAGS_V1="v1.18.30 v1.18.31 v1.18.32 v1.18.33 v1.18.34"
TAGS_V2="v2.0.0 v2.0.1 v2.0.2 v2.0.3 v2.0.4 v2.0.5 v2.0.6 v2.0.7 v2.0.8 v2.0.9 v2.0.10 v2.0.11 v2.0.12 v2.0.13 v2.0.14 v2.0.15 v2.0.16 v2.0.17 v2.0.18 v2.0.19 v2.0.20 v2.0.21 v2.0.22"

mkdir -p "$(dirname "$SRC")"
if [[ ! -d "$SRC/.git" ]]; then
	rm -rf "$SRC"
	git init -q "$SRC"
	git -C "$SRC" remote add origin "$REMOTE"
fi

fetch_one() {
	local t="$1" i
	for i in 1 2 3; do
		if timeout 600 git -C "$SRC" fetch -q --depth=1 origin "refs/tags/${t}:refs/tags/${t}" 2>&1; then
			echo "OK ${t}"
			return 0
		fi
		echo "retry ${t} (${i})"
		sleep $((i * 5))
	done
	echo "FAIL ${t}"
	return 1
}

FAILED=""
echo "=== fetching v1 tags (5) ==="
for t in $TAGS_V1; do fetch_one "$t" || FAILED="$FAILED $t"; done
echo "=== fetching v2 tags (23) ==="
for t in $TAGS_V2; do fetch_one "$t" || FAILED="$FAILED $t"; done

echo "=== result ==="
echo "have: $(git -C "$SRC" tag -l 'v1.18.3*' | wc -l) v1 tags, $(git -C "$SRC" tag -l 'v2.0.*' | wc -l) v2 tags"
[[ -n "$FAILED" ]] && echo "FAILED:$FAILED"
du -sh "$SRC" "$SRC/.git"
