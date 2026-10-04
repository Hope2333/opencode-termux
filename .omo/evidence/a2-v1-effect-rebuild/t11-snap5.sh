#!/bin/bash
# t11-snap5.sh — 全量定位 location services / fetching index 代码（serve runtime + press3 kit runtime）
echo "== T11 SNAP5 $(date -u +%FT%TZ) =="
ls -la /mnt/sdcard_ext4/apps/a2todo9/kit/runtime/ /mnt/sdcard_ext4/apps/a2todo9/kit/opencode 2>/dev/null | head
python3 - <<'PYEOF'
import re
TARGETS = {
  'serve': '/data/data/com.termux/files/usr/lib/opencode/runtime/opencode',
  'kit3':  '/mnt/sdcard_ext4/apps/a2todo9/kit/runtime/opencode',
}
import os
for name, path in TARGETS.items():
    if not os.path.exists(path):
        # try dir listing
        print(f"### {name}: {path} MISSING"); continue
    data = open(path,'rb').read()
    print(f"\n########## {name} {path} size={len(data)} ##########")
    for needle in [b"location services", b"fetching index", b"index.json", b"workspaceID", b"LocationService"]:
        hits = [m.start() for m in re.finditer(re.escape(needle), data)]
        print(f"needle={needle.decode()} hits={len(hits)} at {hits[:8]}")
PYEOF
echo "== SNAP5 END =="
