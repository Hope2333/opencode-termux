W=/mnt/sdcard_ext4/apps/a2todo9/sbx-press2a
echo SANDBOX_TREE:
find $W -maxdepth 4 -type d 2>/dev/null | head -20
echo LOG_FILES:
find $W -name "*.log" -o -name "log" -type d 2>/dev/null | head -10
for f in $(find $W -path "*log*" -name "*.log" 2>/dev/null | head -3); do echo "--- $f (tail 15):"; tail -15 "$f"; done
echo STATE_DIR:
find $W/state $W/data $W/cache -type f 2>/dev/null | head -20
echo DSTATE_VISIBLE:
for p in /proc/[0-9]*/stat; do s=$(awk '{print $3}' $p 2>/dev/null); [ "$s" = "D" ] && echo "  D: ${p} $(tr '\0' ' ' < ${p%stat}cmdline 2>/dev/null | head -c 80)"; done
echo SERVE_LOG_TAIL:
ls -t /data/data/com.termux/files/home/.local/share/opencode/log/ 2>/dev/null | head -3
L=$(ls -t /data/data/com.termux/files/home/.local/share/opencode/log/*.log 2>/dev/null | head -1); [ -n "$L" ] && tail -8 "$L"
