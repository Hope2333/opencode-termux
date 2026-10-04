echo 5C_LOG:
L=/mnt/sdcard_ext4/apps/a2todo5b/sbx-5c-press2-r1/data/opencode/log/opencode.log
ls -la $(dirname $L) 2>/dev/null
tail -25 "$L" 2>/dev/null
echo PRESS2A_LOG_NOW:
tail -3 /mnt/sdcard_ext4/apps/a2todo9/sbx-press2a/data/opencode/log/opencode.log 2>/dev/null
echo PRESS2A_STILL_ALIVE:
for p in /proc/[0-9]*/cmdline; do c=$(tr '\0' ' ' < $p 2>/dev/null); case "$c" in *beta103-press2*) echo "  ${p#/proc/}";; esac; done
echo SERVE_LOG_FULL_TODAY:
grep "2026-10-03" /data/data/com.termux/files/home/.local/share/opencode/log/opencode.log 2>/dev/null | head -10
