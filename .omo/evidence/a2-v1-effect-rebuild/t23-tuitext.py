import re
import sys

d = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
d = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", d)
d = re.sub(r"\x1b_G[^\x1b]*(\x07|\x1b\\)", "", d)
d = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", d)
d = re.sub(r"\x1b[()][A-Z0-9]", "", d)
d = re.sub(r"\x1b[=>]", "", d)

out = []
for ch in d:
    out.append(ch if (ch.isprintable() or ch in " \n") else " ")
txt = "".join(out)
txt = re.sub(r" +", " ", txt)

lines = [l.strip() for l in txt.split("\n") if l.strip()]
seen = set()
for l in lines:
    if l in seen:
        continue
    seen.add(l)
    print(l[:160])
    if len(seen) > 45:
        break
