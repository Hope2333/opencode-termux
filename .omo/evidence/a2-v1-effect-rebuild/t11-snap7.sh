#!/bin/bash
# t11-snap7.sh — rcMap 填充者 + contextEffect 体 + booting log 调用点
python3 - <<'PYEOF'
import re
serve='/data/data/com.termux/files/usr/lib/opencode/runtime/opencode'
data=open(serve,'rb').read()
hits=[m.start() for m in re.finditer(b'rcMap', data)]
print("rcMap hits:", len(hits), hits[:20])
boots=[m.start() for m in re.finditer(b'booting', data)]
print("booting hits:", len(boots), boots[:20])
PYEOF
echo "== SNAP7 END =="
