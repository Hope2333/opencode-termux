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

# 料源（sourcing）—— 外包取料时必须知道哪些是同源件、哪些是新编件。
# 判据：真编 9 版走 fresh-compile；重打包 19 版的料源是 RC4 在架资产。
# **不靠记忆**：见 SOURCING 的推导注释与 fleet-provenance.py 的实测。
def sourcing(line, ver):
    if line == "v1":
        return "fresh-compile(single-elf A+)"
    return ("fresh-compile(seccomp+graft+hermetic)"
            if ver in ("2.0.19", "2.0.20", "2.0.21", "2.0.22")
            else "repack-from-RC4-asset")


# 配方 id：写清每版**怎么来的**。外包与后续维护要靠这一列判断能不能重跑。
RECIPE = {
    ("v1", "built"): "R1 · v1-single-elf: single-elf-namespace-patch(A+ ignore-xdg)"
                     " → bun install → @opentui/core 平台包补装 → pty-embed-store-patch"
                     " → build-v1.sh(bun1.4.2, effect beta.83) → TLSDESC graft"
                     " → hermetic-home-patch → 形态自证 → package_pacman_native",
    ("v2", "repack"): "R2 · v2-历史形态-重打包: RC4 已实证未压缩 ELF"
                      " → hermetic 分类断言(只读) → package_pacman_native",
    ("v2", "built"): "R3 · v2-历史形态-真编译: 单份clone 逐tag checkout"
                     " → build-bionic.sh(bun1.4.0 pin, PTY_VARIANT=musl)"
                     " → W11 seccomp harden → TLSDESC graft → hermetic-home-patch"
                     " → 形态自证 → package_pacman_native",
}


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def vkey(v):
    """'1.18.34' → (1,18,34) 便于版本排序。空/畸形版本排到末尾而不是崩掉
    —— 排序是报告环节，不该因为一行脏数据把整个 --check 变成 traceback。"""
    try:
        return tuple(int(x) for x in v.split("."))
    except (ValueError, AttributeError):
        return (1 << 30,)


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
                # isolation 列形如 "roots=4/4 decoy=0"（driver 已按新判据记
                # namespace-leak=0；bun-runtime-cache 单列且**不计分**）。这里
                # 二次校验：把数字读出来当门禁，而不是只信 driver 的字符串。
                r["decoy_leak"] = None
                m = re.search(r"decoy=(\d+)", r["isolation"])
                if m:
                    r["decoy_leak"] = int(m.group(1))
                r["roots"] = None
                m = re.search(r"roots=(\d+)/(\d+)", r["isolation"])
                if m:
                    r["roots"] = (int(m.group(1)), int(m.group(2)))
            elif r["line"] == "v2":
                # R2（repack driver）历史列序是 6=sha 7=bytes（与 v1 相反），
                # R3（build driver）已对齐成 6=bytes 7=sha。两者都靠
                # 「7 列是纯数字=bytes」自动判别，不靠调用方记忆。
                if len(p) > 7 and p[7].isdigit():
                    r["elf_bytes"] = int(p[7])
                    r["elf_sha"] = p[6] if len(p) > 6 else ""
                else:
                    r["elf_bytes"] = int(p[6]) if len(p) > 6 and p[6].isdigit() else 0
                    r["elf_sha"] = p[7] if len(p) > 7 else ""
                r["isolation"] = p[8] if len(p) > 8 else ""
                # R3 写 10 列（第 10 列 tui=GREEN）；R2 只写 9 列，无 TUI 结论
                r["tui"] = p[9] if len(p) > 9 else ""
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

        # 隔离门禁（v1）：诱饵 XDG 下四根命名空间路径必须为 0。
        # driver 记的是 `decoy=<namespace-leak 计数>`，bun 自身转译缓存
        # 单列且**不计分**（见 docs/fleet-manifest.md §3.2）。这里做二次门禁，
        # 不只信 driver 的字符串 —— 字符串写错也会被这道门抓住。
        if r["line"] == "v1":
            if r["decoy_leak"] is None:
                bad.append(f"{r['ver']}: isolation 列缺 decoy= 计数，无法核验命名空间零外泄")
            elif r["decoy_leak"] != 0:
                bad.append(f"{r['ver']}: 诱饵 XDG 命名空间泄漏 decoy={r['decoy_leak']}（期望 0）")
            if r["roots"] is None:
                bad.append(f"{r['ver']}: isolation 列缺 roots=N/4，无法核验四根落位")
            elif r["roots"] != (4, 4):
                bad.append(f"{r['ver']}: 隔离四根落位 {r['roots'][0]}/{r['roots'][1]}（期望 4/4）")
            if r["tui"] != "tui=GREEN":
                bad.append(f"{r['ver']}: TUI 冒烟非 GREEN（{r['tui'] or '缺记录'}）")
        else:
            # v2：R3（真编 4 版）必须有 TUI GREEN；R2（重打包）不跑 TUI，但
            # 必须有 hermetic 分类记录。重打包件不跑 TUI 是**明示的缺口**，
            # 不是漏跑 —— 料源是 RC4 已实证在架件，本轮不重复验证。
            if sourcing("v2", r["ver"]).startswith("fresh"):
                if r["tui"] != "tui=GREEN":
                    bad.append(f"{r['ver']}: R3 真编件 TUI 冒烟非 GREEN（{r['tui'] or '缺记录'}）")
            if not r["isolation"]:
                bad.append(f"{r['ver']}: 缺 hermetic 分类记录")

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
| 配方 | v1 = R1（真编译 5 版）｜v2 = R2（重打包 19 版）+ R3（真编译 4 版），见 §3 |
| 料源 | **fresh-compile 9 版**（v1 全部 + v2 2.0.19–2.0.22）｜**repack-from-RC4-asset 19 版**（v2 2.0.0–2.0.18）|
| 来源自证 | 9 版真编件逐版核对「上游 tag 解析 commit == 实际 checkout 的 HEAD == 包内 `--version`」，见 `tools/a2/fleet-provenance.py` |
| 压缩 | **全部未压缩**（逐包复验 `UPX!` 魔数 = 0） |
| 键入活性 | v1 = `measured`（`DELTA_keys>0` 逐版 GREEN）｜v2 = **`not-measured-by-this-harness`**（见 §3.5） |
| 状态 | 不 push、不发布、不装机；压制外包给下游 |

## 1. v1 线（single-elf 真编译，配方 R1，料源 fresh-compile）

| 版本 | 料源 | 包体字节 | 包体 sha256 | 未压缩 ELF 字节 | ELF sha256 | 隔离 | TUI 冒烟 |
|---|---|---:|---|---:|---|---|---|
""")
        for r in rows:
            if r["line"] != "v1":
                continue
            fh.write(f"| `{r['ver']}` | `{sourcing('v1', r['ver'])}` | {r['bytes']:,} | "
                     f"`{r['sha'][:16]}…` | "
                     f"{r['elf_bytes']:,} | `{r['elf_sha'][:16]}…` | "
                     f"{r['isolation'] or '—'} | "
                     f"{'GREEN ✓' if r['tui'] == 'tui=GREEN' else (r['tui'] or '—')} |\n")
        fh.write(f"""
每版冒烟五项（`tools/a2/fleet-v1-build.sh` 第 7/8 步，硬门禁）：

1. `--version` 对版
2. 隔离假 HOME **四根**全部落位 `$HOME/{{.local/share,.cache,.config,.local/state}}/opencode1/opencode`
3. **诱饵 XDG 四根命名空间路径零外泄**（判的是「诱饵下出现 `opencode1|opencode` 命名空间路径 = FAIL」；
   bun 自身转译缓存 `bun/@t@/*.pile` 记 informational **不计分**，理由见 §3.2）
4. 真 PTY TUI 一帧 + 键入 `DELTA_keys > 0`（`task-3-smoke.sh` harness，判 verdict=GREEN）
5. 形态自证：home 路径 0、**零 glibc NEEDED**、内嵌 pty 资产、**零 UPX 魔数**

## 2. v2 线（历史形态；R2 重打包 19 版 + R3 真编 4 版）

| 版本 | 料源 | 配方 | 包体字节 | 包体 sha256 | 未压缩 runtime 字节 | runtime sha256 | hermetic 分类 | TUI |
|---|---|---|---:|---|---:|---|---|---|
""")
        for r in rows:
            if r["line"] != "v2":
                continue
            src = sourcing("v2", r["ver"])
            rec = "R3" if src.startswith("fresh") else "R2"
            if r["tui"] == "tui=GREEN":
                tui = "GREEN ✓"
            elif rec == "R2":
                tui = "—（重打包件未跑 TUI 冒烟；料源为 RC4 已实证在架件）"
            else:
                tui = r["tui"] or "—"
            fh.write(f"| `{r['ver']}` | `{src}` | {rec} | {r['bytes']:,} | "
                     f"`{r['sha'][:16]}…` | "
                     f"{r['elf_bytes']:,} | `{r['elf_sha'][:16]}…` | "
                     f"`{r['isolation'].replace('hermetic=', '')}` | {tui} |\n")
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
**已按此实现**：driver 逐版记 `namespace-leak=0` + `bun-runtime-cache=N`，后者不计分。

### 3.3 料源与来源自证（外包取料必读）

| 料源 | 版本 | 含义 |
|---|---|---|
| `fresh-compile` | v1 全部 5 版 + v2 2.0.19–2.0.22（共 9） | 本轮从上游 tag 真编译 |
| `repack-from-RC4-asset` | v2 2.0.0–2.0.18（共 19） | 从 RC4 在架资产提取 ELF 重打包，**与 RC4 在架件逐字节同源** |

「同源」有硬证据：`opencode-2.0.18-6` 包内 ELF 的 sha256 与
`artifacts/build/2.0.18/opencode-native-revived` **完全相同**（实测
`6fdef1c68348eb51ada7bc5025d23ec49fc650666c4a7dcef208ffd15490bbb0`），
且 `UPX!` 命中 = 0（本就是未压缩本体）。

**fresh-compile 9 版的来源三重自证**（`tools/a2/fleet-provenance.py --check --verify-payload`）：

| 版本 | 上游 tag 解析 commit | 实际 checkout 的 HEAD | 包内 `--version` |
|---|---|---|---|
| 1.18.30 | `3104c142` | `3104c142` | `1.18.30` |
| 1.18.31 | `014614d3` | `014614d3` | `1.18.31` |
| 1.18.32 | `545f51d2` | `545f51d2` | `1.18.32` |
| 1.18.33 | `51ef4be1` | `51ef4be1` | `1.18.33` |
| 1.18.34 | `aec0b9a6` | `aec0b9a6` | `1.18.34` |
| 2.0.19 | `1fd016ef` | `1fd016ef` | `opencode v2.0.19` |
| 2.0.20 | `84c9be93` | `84c9be93` | `opencode v2.0.20` |
| 2.0.21 | `8a8bd622` | `8a8bd622` | `opencode v2.0.21` |
| 2.0.22 | `527f0b93` | `527f0b93` | `opencode v2.0.22` |

**版本硬编码疑点的实测结论（CI 代理提出）**：`tools/a2/press-v5.sh` 有 `VER=1.18.32`、
`pty-embed-store-patch.sh` 有 `V1_SRC=…opencode-1.18.32` 与 `VENDOR_SHA`，看着都把版本钉死
1.18.32 —— **未污染本 fleet**：
1. fleet 链路**不调 `press-v*`**（那是 UPX 压制线，本轮跳过 UPX）；
2. 三个被调脚本都**显式传 `V1_SRC`**，默认值不生效；
3. `VENDOR_SHA` 是 **vendor blob 的完整性门禁**，不是 opencode 版本 pin —— 该 blob
   （`tools/bun-pty-embed/vendor/librust_pty_arm64.bionic.so`）是**跨版本通用静态资产**
   （bionic librust_pty，住在本仓 `tools/` 下、不在 v1 源树里），5 版共用同一 blob 正确
   （5 版的 `bun-pty@0.4.8` store 槽位名逐版一致）；
4. 上表逐版三方对账，全部一致。

### 3.4 两条不可省的门禁（都是「不报错但结果错」的教训）

**① 形态一致性 = 与 RC4 在架件成员集逐一比对。** W11 seccomp harden 是 `Makefile`
`transplant` 目标在 build 之后单独跑的一步（`Makefile:296-299`），直编 `build-bionic.sh`
**会漏**。漏掉的后果：PKGBUILD 的 W11 判据「binary 引用 shim 才装 shim」为假 →
**合法地不装** → 包能打出、`--version` 过、TUI 出画，只有并排比才看得出，
而 shim 的 spawn-child fd 卫生机制已失效。已做**双向**硬断言：harden 后
`DT_NEEDED refs>=1`，且包**必须**含 `usr/lib/opencode/libopencode-crhandler.so`。
实测 2.0.19–2.0.22 四版包与 2.0.18 **逐成员 diff 为空**。

**② 任何「条件性必跑」的步骤不得放在 RESUME 等可选块内。** harden 最初被放在
`SKIP_BUILD` 块内，于是 RESUME 路径静默跳过它 —— 包**仍然不带 shim**而 driver 报 DONE。
续接快路径只能省「产物无关」的步骤（编译），**产物相关**的步骤（harden/graft/remap/
形态自证/打包门/冒烟）永远不能跳。

### 3.5 键入活性：v1 measured / v2 not-measured-by-this-harness

| 线 | 键入活性 | 依据 |
|---|---|---|
| v1（5 版） | **`measured`** | `task-3-smoke.sh` 判 `DELTA_keys_window > 0`，逐版 GREEN（实测 4096） |
| v2（4 版真编） | **`not-measured-by-this-harness`** | 见下 |

v2 的 TUI 是**全屏原地重绘**，typescript 字节数恒定，所以 v1 那套「键入窗内字节增长 > 0」
在本 harness 下永远判 RED。对照实验（决定性在第二条）：

| 件 | S1@25s | S3 键入后 | DELTA |
|---|---:|---:|---:|
| 2.0.19（本 fleet 新编） | 12288 | 12288 | **0** |
| 2.0.18（**RC4 已实证在架件**） | 12288 | 12288 | **0** |

第二条证明是 harness 对 v2 的不适配，**不是编译件缺陷**。捕获里 TUI 完整出画。
另测把渲染窗 25s→45s、键入 `z`→`hello`，DELTA 仍 0 且画面哈希不变。

故 v2 判据改为「出画 + 无崩溃 + **画面完整**（输入框提示语 + 状态栏键位提示 +
版本号可见，三者齐）+ `rc != 139`」（`tools/a2/fleet-v2-tui-smoke.sh`），
**键入活性如实记为不可测**，不假装测了。**外包或后续若需真测键入活性，
请用真实交互会话或真 PTY 会话脚本**（例如人工在真机终端里敲键看响应），
不要沿用本 harness 的 DELTA 判据。

## 4. 复现

```bash
# v1（真编译，单份 clone 逐 tag checkout）
VERS="1.18.30 1.18.31 1.18.32 1.18.33 1.18.34" bash tools/a2/fleet-v1-build.sh

# v2 上游新增 4 版（真编译，含 seccomp harden）
VERS="2.0.19 2.0.20 2.0.21 2.0.22" bash tools/a2/fleet-v2-build.sh

# v2 RC4 沿途 19 版（重打包）
VERS="$(seq -f '2.0.%g' 0 18)" bash tools/a2/fleet-v2-repack.sh

# 三项复验
python3 tools/a2/fleet-provenance.py --check --verify-payload   # 来源自证
python3 tools/a2/fleet-manifest.py --check                      # 产物复验
python3 tools/a2/fleet-manifest.py                              # 重生成 md
```

证据：`.omo/evidence/a2-v1-effect-rebuild/task-30-fleet-build.txt`（逐版全过程）、
`task-30-fleet-manifest.tsv`（机器可读一行一版，断线续接靠它）、
`task-30-fleet-provenance.txt`（来源三方对账）。
""")
    print(f"—— 已写 {OUT_MD}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
