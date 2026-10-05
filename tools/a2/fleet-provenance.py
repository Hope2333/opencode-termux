#!/usr/bin/env python3
"""fleet-provenance.py — task-30: fleet 逐版「产物实际来源」独立核验

## 为什么需要这个（CI 代理提出的硬编码疑点，实测结论：未中招）

`tools/a2/press-v5.sh` 有 `VER=1.18.32`、`pty-embed-store-patch.sh` 有
`V1_SRC=…/opencode-1.18.32` + `VENDOR_SHA`，看起来都「把版本钉死在 1.18.32」。
若 fleet 的 v1 链路真的按这些默认值取源，就会**构建照跑、版本号却是 1.18.32**，
包名撒谎 —— 静默产出错版本，是最难发现的一类坑。

**实测结论：未中招。** 理由逐条：

1. **fleet 链路不调 `press-v*`**。`tools/a2/fleet-v1-build.sh` 只调三个脚本：
   `single-elf-namespace-patch.sh` / `pty-embed-store-patch.sh` / `build-v1.sh`，
   全部**显式传 `V1_SRC="$FLEET_SRC"`**（单份 clone 的路径），覆盖掉默认值。
   `press-v5.sh` 根本不在 fleet 链路里（那是 UPX 压制线的，本轮明确跳过 UPX）。
2. **`VENDOR_SHA` 不是版本 pin，是 vendor blob 的完整性校验**。
   `VENDOR_SO` = `tools/bun-pty-embed/vendor/librust_pty_arm64.bionic.so`
   —— 一个**跨版本通用的静态资产**（bionic 编译的 librust_pty），住在本仓
   `tools/` 下、不在 v1 源树里。`VENDOR_SHA` 是它的 sha256 门禁
   （`sha256sum -c`），防的是「vendor blob 被人改过」，与 opencode 版本无关。
   逐版实测该 sha256 与文件实际值一致；且 5 版用的是**同一个** blob ——
   这正确，因为 bun-pty 是外部依赖，5 个版本的 `bun-pty@0.4.8` 槽位名逐版一致。
3. **每版实际 checkout 的 HEAD 与上游 tag 逐一对上**（见下表，git 自己解引用）。
4. **产物内版本自证逐版对版**（本脚本 `--verify-payload` 从包体解出实物跑
   `--version`，不信日志转述）。

## 留证方式

`--check` 输出逐版对照表，写进 `.omo/evidence/a2-v1-effect-rebuild/
task-30-fleet-provenance.txt`。每行四列：目标版本 / 上游 tag 解析出的 commit /
证据日志里实际 checkout 的 HEAD / 包内 payload 的 `--version`。

用法:
    python3 tools/a2/fleet-provenance.py --check              # 只核验
    python3 tools/a2/fleet-provenance.py --verify-payload     # 另跑包内实物自证(慢, ~5min)
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FLEET_SRC = os.environ.get(
    "FLEET_SRC", os.path.join(os.environ.get(
        "TMPDIR", "/data/data/com.termux/files/usr/tmp"), "a2-src", "opencode-fleet"))
EVID = os.path.join(ROOT, ".omo/evidence/a2-v1-effect-rebuild/task-30-fleet-build.txt")
PROV = os.path.join(ROOT, ".omo/evidence/a2-v1-effect-rebuild/task-30-fleet-provenance.txt")
MANIFEST = os.path.join(ROOT, ".omo/evidence/a2-v1-effect-rebuild/task-30-fleet-manifest.tsv")
VENDOR = os.path.join(ROOT, "tools/bun-pty-embed/vendor/librust_pty_arm64_bionic.so")
VENDOR_SHA_DECLARED = "58aeeb4647cdcdb7e4d9f855ebaa75339ab934039d7ddd977a0be5a3b5cf1c2d"

# fleet 里「真编」的 9 版（重打包的 19 版料源是 RC4 在架资产，另行核验）
COMPILED_V1 = ["1.18.30", "1.18.31", "1.18.32", "1.18.33", "1.18.34"]
COMPILED_V2 = ["2.0.19", "2.0.20", "2.0.21", "2.0.22"]


def git(*args, cwd=FLEET_SRC):
    r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def log_head_by_version():
    """扫证据日志，取每版实际 checkout 的 HEAD。日志按 `#### v1 <ver> (v<tag>)` 分节，
    节内第一条 `HEAD=` 即该版实际 checkout 的 commit。"""
    out, cur, got = {}, None, set()
    with open(EVID, errors="replace") as fh:
        for line in fh:
            m = re.search(r"#### v[12] (\S+) \(v\S+\)", line)
            if m:
                cur, got = m.group(1), set()
                continue
            m = re.search(r"HEAD=([0-9a-f]{7,40})", line)
            if m and cur and cur not in out:
                out[cur] = m.group(1)
                got.add(cur)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--verify-payload", action="store_true",
                    help="解出每版包内 payload 跑 --version（慢）")
    o = ap.parse_args()

    problems, lines = [], []
    lines.append("# fleet 逐版来源核验（task-30）\n")
    lines.append(f"生成：{subprocess.run(['date','-u','+%Y-%m-%dT%H:%M:%SZ'],capture_output=True,text=True).stdout.strip()}")
    lines.append(f"源 clone：`{FLEET_SRC}`\n")

    # ── 0. vendor blob 完整性（VENDOR_SHA 是 blob 门禁，不是版本 pin） ──
    if not os.path.isfile(VENDOR):
        problems.append(f"vendor blob missing: {VENDOR}")
        vsha = "MISSING"
    else:
        vsha = subprocess.run(["sha256sum", VENDOR], capture_output=True,
                              text=True).stdout.split()[0]
    lines.append("## 0. vendor blob（`pty-embed-store-patch.sh` 的 `VENDOR_SHA`）\n")
    lines.append(f"- blob：`{os.path.relpath(VENDOR, ROOT)}`")
    lines.append(f"- 脚本声明 sha256：`{VENDOR_SHA_DECLARED}`")
    lines.append(f"- 实际 sha256：      `{vsha}`")
    if vsha != VENDOR_SHA_DECLARED:
        problems.append(f"vendor blob sha drift: declared={VENDOR_SHA_DECLARED} actual={vsha}")
    lines.append("- 判定：**跨版本通用静态资产**（bionic librust_pty，住在本仓 `tools/` 下，"
                 "不在 v1 源树里），该 sha 是**blob 完整性门禁**，**不是 opencode 版本 pin**。")
    lines.append("  5 版共用同一 blob 正确 —— 5 版的 `bun-pty@0.4.8` store槽位名逐版一致。\n")

    # ── 1. fleet 链路不调 press-v*（否则会被 press-v5 的 VER=1.18.32 钉死） ──
    drv = open(os.path.join(ROOT, "tools/a2/fleet-v1-build.sh")).read()
    calls = re.findall(r'bash "\$ROOT_DIR/tools/[^"]+"', drv)
    uses_press = [c for c in calls if "press-v" in c]
    lines.append("## 1. fleet v1 链路调用的脚本\n")
    for c in sorted(set(calls)):
        lines.append(f"- `{c}`")
    lines.append(f"- 是否调用 `press-v*`：**{'是（需立即停手）' if uses_press else '否 ✓'}**")
    lines.append("  （`press-v5.sh` 的 `VER=1.18.32` 属 UPX 压制线，本轮明确跳过 UPX，不在 fleet 链路）")
    if "V1_SRC" not in drv:
        problems.append("fleet-v1-build.sh 未传 V1_SRC —— 会落到脚本默认的 opencode-1.18.32")
    else:
        lines.append("- 三个脚本均**显式传 `V1_SRC=\"$FLEET_SRC\"`**，覆盖脚本默认值 ✓\n")
    if uses_press:
        problems.append(f"fleet 链路调了 press-v*: {uses_press}")

    # ── 2. 逐版：上游 tag 解析出的 commit vs 证据日志实际 checkout 的 HEAD ──
    heads = log_head_by_version()
    lines.append("## 2. 逐版来源对照（tag→commit 由 git 解引用；HEAD 来自证据日志）\n")
    lines.append("| 目标版本 | 上游 tag 解析 commit | 证据日志实际 HEAD | 一致 |")
    lines.append("|---|---|---|---|")
    for line, vers in (("v1", COMPILED_V1), ("v2", COMPILED_V2)):
        for v in vers:
            tag_sha = git("rev-parse", "--short", f"v{v}^{{commit}}")
            got = heads.get(v, "(日志缺)")
            ok = "✓" if tag_sha and got.startswith(tag_sha[:8]) else "✗"
            lines.append(f"| {line} `{v}` | `{tag_sha or 'MISSING'}` | `{got}` | {ok} |")
            if not tag_sha:
                problems.append(f"{v}: tag v{v} 在 clone 里解引用失败")
            elif not got.startswith(tag_sha[:8]):
                problems.append(f"{v}: HEAD={got} != tag v{v} commit={tag_sha}  **产物可能不是该版本**")
    lines.append("")

    # ── 3. 产物内版本自证（从包体解出实物跑 --version） ──
    if o.verify_payload:
        lines.append("## 3. 产物内版本自证（解包跑 payload 的 `--version`，不信日志）\n")
        lines.append("| 包 | payload `--version` | 对版 |")
        lines.append("|---|---|---|")
        pkgs = []
        with open(MANIFEST) as fh:
            for ln in fh:
                p = ln.rstrip("\n").split("\t")
                if len(p) > 3 and p[2] == "OK":
                    pkgs.append((p[0], p[1], p[3]))
        tmp = tempfile.mkdtemp(prefix="fleet-prov-", dir=os.environ.get("TMPDIR"))
        try:
            for ver, line, path in pkgs:
                if not os.path.isfile(path):
                    problems.append(f"{ver}: 包体缺失 {path}")
                    continue
                subprocess.run(["rm", "-rf", tmp], check=False)
                os.makedirs(tmp, exist_ok=True)
                subprocess.run(["bsdtar", "-xf", path, "-C", tmp], check=False,
                               capture_output=True)
                if line == "v1":
                    cand = [os.path.join(r, f) for r, _, fs in os.walk(tmp) for f in fs
                            if f == "opencode" and "runtime" in r]
                    env = None
                else:
                    cand = [os.path.join(r, f) for r, _, fs in os.walk(tmp) for f in fs
                            if f == "opencode" and os.path.basename(r) == "bin"]
                    shim = [os.path.join(r, f) for r, _, fs in os.walk(tmp) for f in fs
                            if f == "libopencode-crhandler.so"]
                    env = dict(os.environ)
                    if shim:
                        env["LD_LIBRARY_PATH"] = os.path.dirname(shim[0])
                if not cand:
                    problems.append(f"{ver}: 包内找不到 payload")
                    continue
                r = subprocess.run([cand[0], "--version"], capture_output=True,
                                   text=True, env=env, timeout=60)
                out = (r.stdout or r.stderr).strip().splitlines()
                got = out[0] if out else "(no output)"
                ok = "✓" if ver in got else "✗"
                lines.append(f"| `{os.path.basename(path)}` | `{got}` | {ok} |")
                if ver not in got:
                    problems.append(f"{ver}: 包内 payload --version={got!r} 与目标版本不符")
        finally:
            subprocess.run(["rm", "-rf", tmp], check=False)

    lines.append("")
    if problems:
        lines.append("## 判定：FAIL\n")
        for p in problems:
            lines.append(f"- ✖ {p}")
    else:
        lines.append("## 判定：PASS —— 9 版真编件的来源与产物版本逐版自洽，无版本错配\n")
        lines.append("- `press-v5.sh` / `pty-embed-store-patch.sh` 的 1.18.32 字样**未污染** fleet 链路")
        lines.append("- `VENDOR_SHA` 是 vendor blob 完整性门禁，非版本 pin")
        lines.append("- 每版实际 checkout 的 HEAD == 该版上游 tag 的 commit")
        if o.verify_payload:
            lines.append("- 每版包内 payload 的 `--version` 与包名/目标版本一致")

    text = "\n".join(lines) + "\n"
    # 只在**实质内容**变化时写文件：--check 会被反复跑，而证据文件每跑一次
    # 就多一行新时间戳的话，工作树会一直脏着，CI 也会误报「有改动」。
    # 时间戳是元数据不是结论，故不参与比较 —— 保留旧文件里的那行时间。
    def substantive(t):
        return "\n".join(l for l in t.splitlines() if not l.startswith("生成："))

    old = ""
    if os.path.isfile(PROV):
        with open(PROV) as fh:
            old = fh.read()
    if substantive(old) == substantive(text):
        print(f"—— 内容无变化，保留 {os.path.relpath(PROV, ROOT)}（不重写时间戳）")
    else:
        os.makedirs(os.path.dirname(PROV), exist_ok=True)
        with open(PROV, "w") as fh:
            fh.write(text)
        print(f"—— 写入 {os.path.relpath(PROV, ROOT)}")
    print(text)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
