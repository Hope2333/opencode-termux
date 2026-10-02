#!/data/data/com.termux/files/usr/bin/bash
# F2 driver: opencode-compressed 2.0.12 grafted-unpacked runtime, sandbox full-chain
# usage: MODE=main|ctrl bash f2-driver.sh
set -u
MODE=${MODE:-main}
PROMPT=${PROMPT:-reply with exactly: ok}
F=/data/local/tmp/f2
P=$F/prefix/usr
TS=$F/f2-$MODE.typescript
PROG=$F/f2-$MODE.progress.log
TMO=${TMO:-240}
X=$F/xdg
if [ "$MODE" = ctrl ]; then BIN=/data/local/tmp/f2/runtime-1-upx; else BIN=$P/lib/opencode/runtime/opencode; fi

mkdir -p $X/config/opencode $X/data/opencode $X/home $X/tmp $X/state $X/cache
cat > $X/config/opencode/opencode.json <<'JSONEOF'
{"model": "opencode/longcat-2.0-free", "small_model": "opencode/longcat-2.0-free", "agent": {"build": {"model": "opencode/longcat-2.0-free"}, "plan": {"model": "opencode/longcat-2.0-free"}, "general": {"model": "opencode/longcat-2.0-free"}}}
JSONEOF
printf '{"port": 49377}\n' > $X/config/opencode/service.json

export TERM=xterm-256color
ENVARGS="env HOME=$X/home TMPDIR=$X/tmp XDG_CONFIG_HOME=$X/config XDG_DATA_HOME=$X/data XDG_STATE_HOME=$X/state XDG_CACHE_HOME=$X/cache TERM=$TERM LD_LIBRARY_PATH=$P/lib/opencode:$P/lib/opencode/pty"

echo "== F2 $MODE start $(date -u +%FT%TZ) bin=$BIN prompt='$PROMPT' tmo=$TMO =="
rm -f "$TS" "$PROG"

( for i in $(seq 1 60); do
    echo "$(date +%s) $(wc -c < "$TS" 2>/dev/null || echo 0)" >> "$PROG"
    sleep 5
  done ) &
SAMPLER=$!

(
  stable=0; prev=-1
  for i in $(seq 1 12); do
    sleep 5
    sz=$(wc -c < "$TS" 2>/dev/null || echo 0)
    echo "$(date +%s) boot $sz" >> "$PROG"
    if [ "$sz" -gt 5000 ] && [ "$sz" -eq "$prev" ]; then stable=$((stable+1)); else stable=0; fi
    prev=$sz
    [ $stable -ge 2 ] && break
  done
  echo "$(date +%s) SENDING_PROMPT" >> "$PROG"
  printf '%s\r' "$PROMPT"
  for i in $(seq 1 28); do
    sleep 5
    sz=$(wc -c < "$TS" 2>/dev/null || echo 0)
    echo "$(date +%s) resp $sz" >> "$PROG"
  done
  printf '\x03'; sleep 2
  printf '\x03'; sleep 5
) | script -qec "$ENVARGS timeout $TMO '$BIN'" "$TS"
RC=$?

kill $SAMPLER 2>/dev/null
echo "== F2 $MODE end rc=$RC $(date -u +%FT%TZ) =="
echo "ts_bytes=$(wc -c < "$TS" 2>/dev/null || echo 0)"
echo "crash_kw=$(grep -ci 'bun\.report\|SIGSEGV\|Segmentation\|AddressSanitizer' "$TS" 2>/dev/null)"
exit $RC
