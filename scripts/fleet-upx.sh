#!/usr/bin/env bash
# fleet-upx.sh — Distributed UPX compression across multiple nodes
# Usage: fleet-upx.sh VER=1.18.21 NODES="miao@host1 miao@host2" [-p <password>]
# Features: NODE_PASSWORD env / -p, sshpass -e, xz -9 outbound, opportunistic dispatch, local verify
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE="$REPO/.omo/evidence/task-fleet-upx.log"

# Parse args
VER=""; NODES=""; STATUS_MODE=0; NODE_PASSWORD=""
while [ $# -gt 0 ]; do
    case "$1" in
        VER=*) VER="${1#VER=}" ;;
        NODES=*) NODES="${1#NODES=}" ;;
        -p) shift; NODE_PASSWORD="${1:-}" ;;
        --status) STATUS_MODE=1 ;;
    esac
    shift
done

# Resolve password: -p override > NODE_PASSWORD env > fail fast
if [ -z "$NODE_PASSWORD" ]; then
    echo "Error: password required. Use -p <password> or set NODE_PASSWORD env."
    exit 1
fi
export SSHPASS="$NODE_PASSWORD"

if [ "$STATUS_MODE" -eq 1 ]; then
    echo "Fleet status probe:"
    for node in $NODES; do
        if sshpass -e ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$node" "echo OK" 2>/dev/null; then
            echo "  $node: reachable"
        else
            echo "  $node: UNREACHABLE"
        fi
    done
    exit 0
fi

if [ -z "$VER" ] || [ -z "$NODES" ]; then
    echo "Usage: fleet-upx.sh VER=x.y.z NODES=\"host1 host2\" [-p <password>]"
    echo "       fleet-upx.sh --status NODES=\"host1 host2\" [-p <password>]"
    exit 1
fi

mkdir -p "$(dirname "$EVIDENCE")"
echo "=== fleet-upx VER=$VER $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$EVIDENCE"
echo "NODES=$NODES" >> "$EVIDENCE"

# Source binary
SRC="$REPO/artifacts/transplant/$VER/opencode-native-tui"
if [ ! -f "$SRC" ]; then
    SRC="$REPO/artifacts/transplant/$VER/opencode-native-revived"
fi
if [ ! -f "$SRC" ]; then
    echo "Error: no source binary for $VER"
    echo "FAIL no-source" >> "$EVIDENCE"
    exit 1
fi

SRC_SHA=$(sha256sum "$SRC" | cut -d' ' -f1)
SRC_SIZE=$(stat -c%s "$SRC")
echo "Source: $SRC (sha=${SRC_SHA:0:16}, ${SRC_SIZE}B)"

# Compress for transfer
COMPRESSED="${TMPDIR:-/tmp}/opencode-$VER-native.xz"
xz -9 -f -c "$SRC" > "$COMPRESSED"
COMP_SIZE=$(stat -c%s "$COMPRESSED")
echo "Compressed: ${COMP_SIZE}B (ratio $(awk "BEGIN{printf \"%.1f\", $COMP_SIZE*100/$SRC_SIZE}")%)"

# Dispatch to nodes (opportunistic)
declare -A NODE_RESULTS
for node in $NODES; do
    echo "Dispatching to $node..."
    # Transfer
    if ! sshpass -e scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "$COMPRESSED" "$node:/tmp/opencode-$VER-native.xz" 2>/dev/null; then
        echo "  $node: transfer failed"
        NODE_RESULTS[$node]="FAIL-transfer"
        continue
    fi

    # Decompress + UPX on remote
    REMOTE_CMD="cd /tmp && xz -d -f opencode-$VER-native.xz && upx --best opencode-$VER-native && upx -t opencode-$VER-native && sha256sum opencode-$VER-native"
    if RESULT=$(sshpass -e ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "$node" "$REMOTE_CMD" 2>/dev/null); then
        REMOTE_SHA=$(echo "$RESULT" | tail -1 | cut -d' ' -f1)
        echo "  $node: OK sha=${REMOTE_SHA:0:16}"
        NODE_RESULTS[$node]="OK sha=$REMOTE_SHA"
    else
        echo "  $node: UPX failed"
        NODE_RESULTS[$node]="FAIL-upx"
    fi

    # Fetch back
    REMOTE_UPX="/tmp/opencode-$VER-native-upx"
    LOCAL_UPX="$REPO/artifacts/transplant/$VER/opencode-$VER-fleet-upx"
    if sshpass -e scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "$node:$REMOTE_UPX" "$LOCAL_UPX" 2>/dev/null; then
        # Verify
        LOCAL_SHA=$(sha256sum "$LOCAL_UPX" | cut -d' ' -f1)
        UPX_SIZE=$(stat -c%s "$LOCAL_UPX")
        if upx -t "$LOCAL_UPX" 2>/dev/null; then
            echo "  $local: verified sha=${LOCAL_SHA:0:16} size=${UPX_SIZE}B"
            echo "FLEET-OK node=$node sha=$LOCAL_SHA size=$UPX_SIZE" >> "$EVIDENCE"
        else
            echo "  $local: upx -t failed"
            echo "FLEET-FAIL node=$node upx-test-failed" >> "$EVIDENCE"
        fi
    else
        echo "  $local: fetch failed"
        echo "FLEET-FAIL node=$node fetch-failed" >> "$EVIDENCE"
    fi
done

# Cleanup
rm -f "$COMPRESSED"

echo ""
echo "Fleet results:"
for node in "${!NODE_RESULTS[@]}"; do
    echo "  $node: ${NODE_RESULTS[$node]}"
done
