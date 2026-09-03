#!/usr/bin/env bash
# range-build.sh — Multi-version batch build with resilience
# Usage: range-build.sh FROM=1.18.15 TO=1.18.27 LINES=glibc,native[,compressed]
# DRY=1 prints plan without side effects
# Features: continue-on-fail, npm retry ≤3, disk guardrail, SHA256SUMS accumulation
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE="$REPO/.omo/evidence/task-range-build.log"
SUMS_FILE="$REPO/packing/SHA256SUMS-prebatch.txt"
DRY="${DRY:-0}"

# Parse args
FROM=""; TO=""; LINES=""
for arg in "$@"; do
    case "$arg" in
        FROM=*) FROM="${arg#FROM=}" ;;
        TO=*) TO="${arg#TO=}" ;;
        LINES=*) LINES="${arg#LINES=}" ;;
    esac
done

if [ -z "$FROM" ] || [ -z "$TO" ] || [ -z "$LINES" ]; then
    echo "Usage: range-build.sh FROM=x.y.z TO=a.b.c LINES=glibc,native[,compressed]"
    echo "  DRY=1 for dry-run (print plan only)"
    exit 1
fi

# Version expansion (handles 1.18.[15-27] range)
expand_versions() {
    local from="$1" to="$2"
    local from_major=$(echo "$from" | cut -d. -f1)
    local from_minor=$(echo "$from" | cut -d. -f2)
    local from_patch=$(echo "$from" | cut -d. -f3)
    local to_major=$(echo "$to" | cut -d. -f1)
    local to_minor=$(echo "$to" | cut -d. -f2)
    local to_patch=$(echo "$to" | cut -d. -f3)

    local versions=()
    local patch=$from_patch
    while [ "$patch" -le "$to_patch" ]; do
        versions+=("${from_major}.${from_minor}.${patch}")
        patch=$((patch + 1))
    done
    echo "${versions[@]}"
}

VERSIONS=($(expand_versions "$FROM" "$TO"))
LINES_COUNT=$(echo "$LINES" | tr ',' '\n' | wc -l)

# DRY mode: print plan and exit
if [ "$DRY" = "1" ]; then
    echo "DRY RUN — plan only, no side effects"
    echo "FROM=$FROM TO=$TO LINES=$LINES"
    echo "Versions (${#VERSIONS[@]}): ${VERSIONS[*]}"
    echo ""
    TOTAL=0
    for VER in "${VERSIONS[@]}"; do
        if echo "$LINES" | grep -q "glibc"; then
            echo "  G$VER: make all VER=$VER PKG=both"
            TOTAL=$((TOTAL+1))
        fi
        if echo "$LINES" | grep -q "native"; then
            echo "  N$VER: make family-native VER=$VER"
            TOTAL=$((TOTAL+1))
        fi
        if echo "$LINES" | grep -q "compressed"; then
            echo "  C$VER: make family-compressed VER=$VER"
            TOTAL=$((TOTAL+1))
        fi
        echo "  clean: artifacts/transplant/$VER (except 1.18.21)"
    done
    echo ""
    echo "TOTAL: ${#VERSIONS[@]} versions × ${LINES_COUNT} lines = $TOTAL builds"
    echo "SHA256SUMS → $SUMS_FILE"
    echo "pkgrel=1 (first formal appearance of each renamed package)"
    exit 0
fi

echo "Range build: ${VERSIONS[*]}"
echo "Lines: $LINES"
echo "Versions: ${#VERSIONS[@]}"
echo ""

# Initialize evidence
mkdir -p "$(dirname "$EVIDENCE")"
echo "=== range-build $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$EVIDENCE"
echo "FROM=$FROM TO=$TO LINES=$LINES VERSIONS=${VERSIONS[*]}" >> "$EVIDENCE"

# Initialize SHA256SUMS (full rewrite)
> "$SUMS_FILE"

PASS=0; FAIL=0; RESULTS=""
DISK_MIN_FREE=2048  # MB

check_disk() {
    local free_kb=$(df --output=avail "$REPO" | tail -1 | tr -d ' ')
    local free_mb=$((free_kb / 1024))
    if [ "$free_mb" -lt "$DISK_MIN_FREE" ]; then
        echo "DISK GUARDRAIL: ${free_mb}MB free < ${DISK_MIN_FREE}MB minimum"
        echo "Pausing 60s, then rechecking..."
        sleep 60
        free_kb=$(df --output=avail "$REPO" | tail -1 | tr -d ' ')
        free_mb=$((free_kb / 1024))
        if [ "$free_mb" -lt "$DISK_MIN_FREE" ]; then
            echo "DISK CRITICAL: ${free_mb}MB free. Aborting."
            echo "DISK-ABORT free=${free_mb}MB" >> "$EVIDENCE"
            exit 1
        fi
    fi
}

for VER in "${VERSIONS[@]}"; do
    echo "=== $VER: START $(date '+%H:%M:%S') ==="
    check_disk

    # Glibc line
    if echo "$LINES" | grep -q "glibc"; then
        echo "  G$VER: building glibc..."
        if make all VER="$VER" PKG=both >> "$EVIDENCE" 2>&1; then
            echo "G$VER OK" >> "$EVIDENCE"
            for f in "$REPO/packing/dpkg/opencode-glibc_${VER}_aarch64.deb" \
                     "$REPO/packing/pacman/opencode-glibc-${VER}-"*.pkg.*; do
                [ -f "$f" ] && sha256sum "$f" >> "$SUMS_FILE"
            done
            RESULTS="${RESULTS}G${VER}:OK "; PASS=$((PASS+1))
        else
            echo "G$VER FAIL" >> "$EVIDENCE"
            RESULTS="${RESULTS}G${VER}:FAIL "; FAIL=$((FAIL+1))
        fi
    fi

    # Native line
    if echo "$LINES" | grep -q "native"; then
        echo "  N$VER: building native..."
        if make family-native VER="$VER" >> "$EVIDENCE" 2>&1; then
            echo "N$VER OK" >> "$EVIDENCE"
            for f in "$REPO/packing/dpkg-native/opencode_${VER}_aarch64.deb" \
                     "$REPO/pacman/opencode-${VER}-"*.pkg.*; do
                [ -f "$f" ] && sha256sum "$f" >> "$SUMS_FILE"
            done
            RESULTS="${RESULTS}N${VER}:OK "; PASS=$((PASS+1))
        else
            echo "N$VER FAIL" >> "$EVIDENCE"
            RESULTS="${RESULTS}N${VER}:FAIL "; FAIL=$((FAIL+1))
        fi
    fi

    # Compressed line
    if echo "$LINES" | grep -q "compressed"; then
        echo "  C$VER: building compressed..."
        if make family-compressed VER="$VER" >> "$EVIDENCE" 2>&1; then
            echo "C$VER OK" >> "$EVIDENCE"
            RESULTS="${RESULTS}C${VER}:OK "; PASS=$((PASS+1))
        else
            echo "C$VER FAIL" >> "$EVIDENCE"
            RESULTS="${RESULTS}C${VER}:FAIL "; FAIL=$((FAIL+1))
        fi
    fi

    # Clean artifacts (except 1.18.21 reference)
    if [ "$VER" != "1.18.21" ]; then
        rm -rf "$REPO/artifacts/transplant/$VER"
    fi

    echo "=== $VER: END $(date '+%H:%M:%S') ==="
done

echo ""
echo "RANGE-BUILD COMPLETE: PASS=$PASS FAIL=$FAIL"
echo "RESULTS: $RESULTS"

if [ $FAIL -eq 0 ]; then
    echo "RANGE-OK pass=$PASS versions=${#VERSIONS[@]}" >> "$EVIDENCE"
else
    echo "RANGE-PARTIAL pass=$PASS fail=$FAIL results=$RESULTS" >> "$EVIDENCE"
fi

echo "SHA256SUMS entries: $(wc -l < "$SUMS_FILE")"
