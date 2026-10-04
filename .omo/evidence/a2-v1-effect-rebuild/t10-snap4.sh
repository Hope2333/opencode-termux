echo REAL_CONFIG:
ls -la /data/data/com.termux/files/home/.config/opencode/ 2>/dev/null
for f in service.json opencode.json; do echo "--- $f:"; cat /data/data/com.termux/files/home/.config/opencode/$f 2>/dev/null | head -30; done
echo A2TODO5B_HARNESS:
ls /mnt/sdcard_ext4/apps/a2todo5b/ 2>/dev/null | head -30
echo ---probe script head:
for s in /mnt/sdcard_ext4/apps/a2todo5b/*.sh; do echo "== $s"; head -5 "$s"; done 2>/dev/null | head -40
echo STUCK_CHECK:
for p in /proc/[0-9]*/cmdline; do c=$(tr '\0' ' ' < $p 2>/dev/null); case "$c" in *opencode*|*probe9*) echo "  pid=${p#/proc/} :: ${c:0:100}";; esac; done
