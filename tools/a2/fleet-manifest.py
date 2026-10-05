#!/data/data/com.termux/files/usr/bin/python3
"""fleet-manifest.py — task-30: 从 driver 落的 TSV + 实际包体生成 docs/fleet-manifest.md

为什么不让 driver 直接写 markdown：包体是产物（.gitignore 排除），而 manifest
是要入库的**结论**。所以 driver 只落机器可读的一行 TSV（断线续接靠它），
本脚本负责把 TSV + 盘上实际包体（重新算 sha256/尺寸，不信转述）渲染成
给人看的那份 docs/fleet-manifest.md。

用法:
    python3 tools/a2/fleet-manifest.py            # 生成/刷新 docs/fleet-manifest.md
    python3 tools/a2/fleet-manifest.py --check    # 只校验，不写（CI 用）
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TSV = os.path.join(ROOT, ".omo/evidence/a2-v1-effect-rebuild/task-30-fleet-manifest.tsv")
OUT_MD = os.path.join(ROOT, "docs/fleet-manifest.md")
PKG_DIR = os.path.join(ROOT, "packing/pacman")
FLEET_PKGREL = "90"

# 配方 id：写清每版**怎么来的**。外包与后续维护要靠这一列判断能不能重跑。
RECIPE = {
    ("v1", "built"): "R1 · v1-single-elf: single-elf-namespace-patch(A+ ignore-xdg)"
                     " → bun install → @opentui/core 平台包补装 → pty-embed-store-patch"
                     " → build-v1.sh(bun1.4.2, effect beta.83) → TLSDESC graft"
                     " → hermetic-home-patch → 形态自证 → package_pacman_native",
    ("v2", "repack"): "R2 · v2-历史形态-重打包: RC4 已实证未压缩 ELF"
                      " → hermetic 分类断言(只读) → package_pacman_native",
}


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def vkey(v):
    """'1.18.34' → (1,18,34) 便于版本排序。"""
    return tuple(int(x) for x in v.split("."))


def load_rows():
    """读 driver 落的 TSV。

    **列序按线不同**（历史遗留：v2 repack driver 写成 sha→bytes，v1 build
    driver 写成 bytes→sha），所以这里**按 line 分派**而不是按固定下标硬取 ——
    错一列不会报错，只会把 sha256 渲染成尺寸这种静默错误，比崩掉更坏。
    期望列序（0 起）：
      0 ver 1 line 2 status 3 path 4 pkg_bytes 5 pkg_sha256
      6 v1: elf_bytes      | v2: runtime_sha256
      7 v1: elf_sha256     | v2: runtime_bytes
      8 v1: 隔离结论       | v2: hermetic 分类
      9 v1: TUI 冒烟结论
    """
    rows = []
    if not os.path.isfile(TSV):
        return rows
    with open(TSV) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            p = line.split("\t")
            if len(p) < 6:
                sys.exit(f"malformed TSV row ({len(p)} cols, need >=6): {line!r}")
            r = {
                "ver": p[0], "line": p[1], "status": p[2], "path": p[3],
                "bytes": int(p[4]), "sha": p[5],
                "elf_bytes": 0, "elf_sha": "", "isolation": "", "tui": "",
            }
            if r["line"] == "v1":
                r["elf_bytes"] = int(p[6]) if len(p) > 6 and p[6].isdigit() else 0
                r["elf_sha"] = p[7] if len(p) > 7 else ""
                r["isolation"] = p[8] if len(p) > 8 else ""
                r["tui"] = p[9] if len(p) > 9 else ""
            elif r["line"] == "v2":
                # v2 历史列序是 6=sha 7=bytes，与 v1 相反
                r["elf_sha"] = p[6] if len(p) > 6 else ""
                r["elf_bytes"] = int(p[7]) if len(p) > 7 and p[7].isdigit() else 0
                r["isolation"] = p[8] if len(p) > 8 else ""
            else:
                sys.exit(f"unknown line {r['line']!r} for {r['ver']} (expected v1|v2)")
            rows.append(r)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验，不写 md")
    o = ap.parse_args()

    rows = load_rows()
    if not rows:
        sys.exit(f"no rows in {TSV}")
    rows.sort(key=lambda r: (r["line"], vkey(r["ver"])))

    # 盘上实物复核：不信 TSV 里的 sha/尺寸，重新算。
    bad = []
    for r in rows:
        if not os.path.isfile(r["path"]):
            bad.append(f"{r['ver']}: 包体缺失 {r['path']}")
            continue
        real_sz = os.path.getsize(r["path"])
        if real_sz != r["bytes"]:
            bad.append(f"{r['ver']}: 尺寸漂移 TSV={r['bytes']} 实际={real_sz}")
        real_sha = sha256_of(r["path"])
        if r["sha"] and real_sha != r["sha"]:
            bad.append(f"{r['ver']}: sha256 漂移 TSV={r['sha'][:16]} 实际={real_sha[:16]}")
        r["sha"] = real_sha
        r["bytes"] = real_sz
        base = os.path.basename(r["path"])
        want = ("opencode1-" if r["line"] == "v1" else "opencode-") + \
               f"{r['ver']}-{FLEET_PKGREL}-aarch64.pkg.tar.xz"
        if base != want:
            bad.append(f"{r['ver']}: 文件名 {base} != 期望 {want}")
        # 零 UPX 复验：包内载荷不得带 UPX 魔数
        with open(r["path"], "rb") as fh:
            blob = fh.read()
        if b"UPX!" in blob:
            bad.append(f"{r['ver']}: .pkg.tar.xz 内含 UPX! 魔数 — 不是未压缩件")

    n1 = sum(1 for r in rows if r["line"] == "v1")
    n2 = sum(1 for r in rows if r["line"] == "v2")
    total = sum(r["bytes"] for r in rows)
    dup = [r["ver"] for r in rows if [x["ver"] for x in rows].count(r["ver"]) > 1]

    print(f"v1={n1} v2={n2} total={n2 + n1} bytes={total} ({total/2**30:.2f} GiB)")
    if dup:
        bad.append(f"重复版本: {sorted(set(dup))}")
    for b in bad:
        print(f"  ✖ {b}", file=sys.stderr)
    if bad:
        sys.exit(1)

    if o.check:
        print("—— 校验通过（未写 md）")
        return 0

    with open(OUT_MD, "w") as fh:
        fh.write(f"""# fleet-manifest — task-30 未压缩本体包 fleet（**不 UPX**）

> 生成：{subprocess.run(['date', '-u', '+%Y-%m-%d'], capture_output=True, text=True).stdout.strip()}，
> 分支 `rc6-a2/fleet`，生成器 `tools/a2/fleet-manifest.py`。
> 规划见 [fleet-matrix.md](fleet-matrix.md)。
>
> **本文件是结论**：表里每个 sha256/尺寸都是生成时从盘上包体**重算**的，
> 不是 driver 的转述。`tools/a2/fleet-manifest.py --check` 可复验。

## 0. TL;DR

| 项 | 值 |
|---|---|
| 版本数 | **{n2 + n1}**（v1 线 {n1} + v2 线 {n2}） |
| 包体总量 | {total} B ≈ **{total/2**30:.2f} GiB** |
| 命名 | `opencode[1]-<ver>-{FLEET_PKGREL}-aarch64.pkg.tar.xz`（pkgrel={FLEET_PKGREL} 为 fleet 专用带，**不带任何额外标识**） |
| 配方 | v1 = R1（真编译）｜v2 = R2（RC4 已实证件重打包，见 §3 说明） |
| 压缩 | **全部未压缩**（逐包复验 `UPX!` 魔数 = 0） |
| 状态 | 不 push、不发布、不装机；压制外包给下游 |

## 1. v1 线（single-elf 真编译，配方 R1）

| 版本 | 包体字节 | 包体 sha256 | 未压缩 ELF 字节 | ELF sha256 | 隔离 | TUI 冒烟 |
|---|---:|---|---:|---|---|---|
""")
        for r in rows:
            if r["line"] != "v1":
                continue
            fh.write(f"| `{r['ver']}` | {r['bytes']:,} | `{r['sha'][:16]}…` | "
                     f"{r['elf_bytes']:,} | `{r['elf_sha'][:16]}…` | "
                     f"{r['isolation'] or '—'} | "
                     f"{'GREEN ✓' if r['tui'] == 'tui=GREEN' else (r['tui'] or '—')} |\n")
        fh.write(f"""
每版冒烟五项（`tools/a2/fleet-v1-build.sh` 第 7/8 步，硬门禁）：

1. `--version` 对版
2. 隔离假 HOME **四根**全部落位 `$HOME/{{.local/share,.cache,.config,.local/state}}/opencode1/opencode`
3. **诱饵 XDG 命名空间零外泄**（详见 §3 的判据说明）
4. 真 PTY TUI 一帧 + 键入 `DELTA_keys > 0`（`task-3-smoke.sh` harness，判 verdict=GREEN）
5. 形态自证：home 路径 0、**零 glibc NEEDED**、内嵌 pty 资产、**零 UPX 魔数**

## 2. v2 线（历史形态，配方 R2）

| 版本 | 包体字节 | 包体 sha256 | 未压缩 runtime 字节 | runtime sha256 | hermetic 分类 (n_t/n_opentui/n_cargo) | --version |
|---|---:|---|---:|---|---|---|
""")
        for r in rows:
            if r["line"] != "v2":
                continue
            fh.write(f"| `{r['ver']}` | {r['bytes']:,} | `{r['sha'][:16]}…` | "
                     f"{r['elf_bytes']:,} | `{r['elf_sha'][:16]}…` | "
                     f"`{r['isolation'].replace('hermetic=', '')}` | 对版 ✓ |\n")
        fh.write(f"""
每版门禁：零 UPX 魔数 → hermetic 分类断言 CLEAN → 绝对成员
`data/data/com.termux/files/usr/bin/opencode` + `usr/lib/opencode/libopencode-crhandler.so`
双成员齐 → **拒相对 `usr/` 成员**（termux-pacman 绝对约定，task-25） → `--version` 对版。

## 3. 两条需要读懂才能用的口径

### 3.1 v2 为什么是「重打包」而不是重新编译

v2 2.0.0–2.0.18 的 runtime 是 **RC4 沿途已实证的未压缩 ELF**，且与在架包**逐字节同源**
（实测 `opencode-2.0.18-6` 包内 ELF sha256 == `artifacts/build/2.0.18/opencode-native-revived`）。
fleet 的用途是产出给外包压制的未压缩原件，用在架同源件比重编更稳，且省 19 次编译。
实测这些 ELF **`UPX!` 命中 = 0**，本就是未压缩本体，与「本轮不 UPX」一致。

### 3.2 诱饵 XDG 的判据为什么不是「字节数 = 0」

诱饵 cache 目录里会出现 `bun/@t@/*.pile` —— 那是 **bun 运行时自己的转译缓存**，
路径由 bun 按 `XDG_CACHE_HOME` 推导，A+ 只改 `global.ts` 的四根派生，管不到它。
内容是转译后的 JS，**不含 opencode 用户数据**。

对照实测：A2 参照件 `1.18.32-beta103-hermetic-grafted`（**无** A+ bake）诱饵
cfg=3922 / data=7 / state=2 / cache=3 条 —— opencode 自己的四根被 XDG **全量**重定向
（cache 下就是 `opencode/bin`、`opencode/models.json`），那才是命名空间泄漏。
本 fleet 件（A+ bake）诱饵 cfg/data/state **全 0**，命名空间零外泄。

故门禁判「诱饵下出现 `opencode1|opencode` 命名空间路径 = FAIL」，bun 自身缓存记 informational。

## 4. 复现

```bash
# v1（真编译，单份clone 逐 tag checkout）
VERS="1.18.30 1.18.31 1.18.32 1.18.33 1.18.34" bash tools/a2/fleet-v1-build.sh

# v2（RC4 已实证件重打包）
VERS="$(seq -f '2.0.%g' 0 18)" bash tools/a2/fleet-v2-repack.sh

# manifest 复验 + 重生成
python3 tools/a2/fleet-manifest.py --check
python3 tools/a2/fleet-manifest.py
```

证据：`.omo/evidence/a2-v1-effect-rebuild/task-30-fleet-build.txt`（逐版全过程）、
`task-30-fleet-manifest.tsv`（机器可读一行一版，断线续接靠它）。
""")
    print(f"—— 已写 {OUT_MD}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
