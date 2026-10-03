#!/bin/bash
# t11-snap6.sh — 提取 location services 代码段（serve runtime JS 区）+ press3 kit 对照
echo "== T11 SNAP6 $(date -u +%FT%TZ) =="
python3 - <<'PYEOF'
import re
serve = '/data/data/com.termux/files/usr/lib/opencode/runtime/opencode'
data = open(serve,'rb').read()
def dump(name, start, end):
    txt = re.sub(rb'[^\x20-\x7e\n\t]', b'.', data[start:end]).decode('ascii','replace')
    print(f"\n##### {name} [{start}:{end}] #####")
    print(txt)
# code region around "booting location services" message (96077082) and LocationService (96076465)
dump("locsvc-code", 96074000, 96086000)
# second cluster: workspaceID 96118573 region
dump("wsid-region", 96115000, 96121000)
PYEOF
echo "--- press3 kit runtime hits ---"
python3 - <<'PYEOF'
import re, os
p='/mnt/sdcard_ext4/apps/a2todo9/kit/runtime/opencode-v1-1.18.32-beta103-press3'
data=open(p,'rb').read()
print("size", len(data))
for needle in [b"location services", b"LocationService", b"workspaceID", b"fetching index"]:
    hits=[m.start() for m in re.finditer(re.escape(needle), data)]
    print(f"needle={needle.decode()} hits={len(hits)} at {hits[:8]}")
PYEOF
echo "== SNAP6 END =="
