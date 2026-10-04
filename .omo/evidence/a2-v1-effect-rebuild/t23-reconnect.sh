#!/data/data/com.termux/files/usr/bin/bash
cd /data/data/com.termux/files/home/develop/opencode-termux/.omo/evidence/a2-v1-effect-rebuild
LOG=t23-reconnect.log
: > $LOG
for i in $(seq 1 40); do
  ts=$(date +%H:%M:%S)
  out=$(echo 'uname -a' | ./t23-ossh.sh 2>&1 | head -1)
  echo "$ts attempt=$i :: $out" >> $LOG
  case "$out" in
    *Linux*) echo "$ts RECOVERED" >> $LOG; exit 0;;
  esac
  sleep 30
done
echo "GAVE_UP" >> $LOG
exit 1
