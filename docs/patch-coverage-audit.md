# 补丁覆盖审计（八层 × 13 版）

> 日期：2026-09-04 ｜ HEAD：`4aa32af`（branch `native-android`）
> 范围：Push260903 本地重铸批 = native 1.18.15–1.18.27 全 13 版（deb + pacman 双渠道 26 包），
> 外加 glibc / standalone / compressed 三个家族的互斥矩阵核对。
> 方法：**字节级产物审计**（python3 ELF/机器码扫描 + ar/tar 成员枚举），不重跑构建。
> 前置：TUI-COMMON-FIX 已根治公共层不应用补丁 + 陈旧槽位产物问题（见
> `docs/tui-common-fix.md`，提交 `17b51a4` → `10afa28` → `faf1334`）。本文回答的是：
> **其余补丁层有没有同类"批量版没吃到"的缺口。**

## TL;DR

- 八层审计 **7 层全 PASS，1 层发现 1 处真缺口并已修复**（L5 的 G2，≤10 行小修）。
- 13 版 × 2 渠道全部吃到：JS 图补丁语义、ELF 复活手术、带守卫 TUI、seccomp 层。
- 热修遗留 `libopencode-crshim.so` 未混入任何新包；watcher 未入正式发布矩阵（判定非缺口）。
- ⚠️ 残余待办：GitHub release `Push260903` 上仍是降级旧批资产，需整批重传（见 §6）。

## 一、八层审计矩阵

下表"13 版"列指 1.18.15–1.18.27 逐版核对结果，"渠道"指 deb 与 pacman 双格式。

| # | 补丁层 | 证据来源 | 13 版结论 | 判定 |
|---|--------|----------|-----------|------|
| L1 | JS 图补丁（`tools/transplant/config/patches.json`） | `patches.json` + `report.json` | 全部 hit_count=0 且按设计 | PASS |
| L2 | ELF 复活（`revive_patch.py` size-mode） | `report.json`（1.18.21/27）+ 13 版产物结构 | plain-offset 贯穿 | PASS |
| L3 | TUI 守卫（canonical build + swap） | 内嵌 .so 字节比对 + 机器码扫描 | 26/26 一致且带守卫 | PASS |
| L4 | seccomp（`sigsys_handler.c` → DT_NEEDED[0]） | ELF 动态段解析 + .so sha | 26/26 全绿（含 1.18.15） | PASS |
| L5 | 打包互斥矩阵（control/PKGINFO） | 全家族 control/PKGINFO 枚举 | G2 缺口已修 | FIXED |
| L6 | compressed 覆盖面 | `packing/*compressed*` 枚举 | 仅 1.18.21 属单版本设计 | PASS |
| L7 | 热修残留（`libopencode-crshim.so`） | 26 包二进制字符串扫描 | 零残留 | PASS |
| L8 | watcher 资产 | 包成员清单 + release 资产清单 | 不入包属设计 | PASS |

### L1 — JS 图补丁

`patches.json` 中唯一补丁 Patch 1（`guysoft-1-undici-case`，等长
`__reExport(exports_Undici, undici)` → `__reExport(exports_Undici, Undici)`）
仅声明于 range `1.0.0..1.3.99`。1.4.0+ range 显式写 `patch_required=false`
（reason=`section era`，`patches=[]`）。13 版全部基于 android-bun 1.4.0 section 图，
因此 hit_count=0 是**按设计的零命中**（`report.json` 记
`outcome=intentional-no-op`），不存在"应中未中"。历史教训（1.3.13 区间外 0 hits
曾致排查混乱）已由显式 `patch_required` 字段固化。

### L2 — ELF 复活

`report.json`（1.18.21 / 1.18.27 两版留档）：`format=section`、
`section_offset=93585408`、`size_mode=plain-offset`、`reloc_count=null`。
13 版最终产物逐个验证：均为有效 ELF、bunfs 内资产定位成功
（`tui_asset_off` ≈ 1.649e8–1.659e8，随版本单调递增，同源管线特征）。
注意：`artifacts/transplant/1.18.25|26` 无 `report.json`（构建记录缺口，非运行时
缺口）——后续构建脚本建议为每版落 report，见 §7。

### L3 — TUI 守卫（本审计的核心层）

对 26 个包（13 deb + 13 pacman）逐个：

1. 用 `swap_tui.py::find_libopentui_asset` 定位内嵌 `/$bunfs/root/libopentui-*.so`；
2. 与 canonical `artifacts/transplant/opentui-bionic/libopentui.so`
   （sha16 `bfc631c84748c63c`，5878192 B）做字节比对；
3. 用 `has_ffi_guard` 扫 10 个守卫函数符号区间
   （bufferDrawChar / isPointInScissor / isRectInScissor / clipRectToScissor /
   setCellWithAlphaBlending / drawGrayscaleBuffer / drawTextBufferInternal /
   clipRectToHitScissor / addToHitGrid / pushScissorRect）的机器码模式
   （clamp=`movn wd,#0x8000,lsl#16` 派生模式 + csel 饱和写模式）。

结果：`tui_canonical=true` 且 `clamp=6 / csel_vs=12`（阈值 ≥1）× 26。
即 TUI-COMMON-FIX 的公共层产物**全部 13 版真实吃到了守卫**，无陈旧槽位残留。

### L4 — seccomp 层

26 包的 `bin/opencode` 动态段 `DT_NEEDED[0]` 全部为 `libopencode-crhandler.so`，
包内 `.so` sha16 全部为 `ebf59e44e737f2ed`（与 artifacts 侧一致）。
**特别核对 1.18.15**：PREBATCH 时代它依赖"手动 cp tui→revived"的 workaround
（`Makefile` 于 `9f1ebc3` 才修），重铸后与标准管线同源，L3/L4 双层证据说明它
真实吃到了 TUI + seccomp 两层，workaround 无残留。

### L5 — 打包互斥矩阵（发现缺口并修复）

教义（D1 裁决）：`opencode`(native) ↔ `opencode-glibc` 互斥；
↔ `opencode-glibc-standalone` 共存；glibc ↔ standalone 互斥；
`opencode-compressed` 与前三者互斥。

逐家族 control/PKGINFO 全枚举结果：

| 家族 | deb Conflicts | pacman conflicts | 备注 |
|------|---------------|------------------|------|
| opencode (native) | opencode-glibc, opencode-compressed | opencode-compressed | pacman 侧**故意**不声明 glibc 字面名，见下 |
| opencode-glibc | opencode (+ Replaces: opencode) | opencode (+ replaces) ×13 一致 | 反向闭环承担 native↔glibc 互斥 |
| opencode-glibc-standalone | opencode-glibc | opencode-glibc (+ provides=opencode-glibc) | 与 native 共存 ✓ |
| opencode-compressed | opencode, opencode-glibc | opencode, opencode-glibc | **deb 侧漏 standalone（G2）** |

- **G1（native pacman 缺 `opencode-glibc`）→ 无需修**：pacman 的 conflicts 会匹配
  Provides 虚拟名，若 native 显式声明 `opencode-glibc` 会误伤 standalone（其
  `provides=opencode-glibc`）。现设计由 glibc 侧 `conflicts=('opencode')` 反向闭环，
  实测 glibc 13 版 pacman 全数声明，互斥成立。`PKGBUILD.native` 注释已自证此意图。
- **G2（compressed deb 缺 `opencode-glibc-standalone`）→ 真缺口，已修**：
  standalone 的 **deb** 无任何 Provides（grep 证），dpkg 世界无虚拟名桥，
  compressed × standalone 可共存，违反教义。修复 =
  `scripts/package/package_deb_compressed.sh` heredoc（真源）+
  `packing/deb-compressed/DEBIAN/control`（参考副本）同步补名。
  pacman 侧经 `provides=opencode-glibc` + conflicts 双向检查已闭合，无需改。
- 观察项（不动）：glibc 家族保留 `Replaces: opencode`（附录过渡遗产，装 glibc 会
  静默顶掉 native；compressed 则明确 no-Replaces 设计，两者不对称）。属历史决策，
  建议附录收尾时单独裁决。

### L6 — compressed 覆盖面

`opencode-compressed` 仅 1.18.21 一版（`packing/dpkg-compressed/` +
`packing/pacman/opencode-compressed-1.18.21-1-*`）。这是**单版本 UPX 试点的
后传进行中状态**，不是 13 版批量的遗漏；其余 12 版无 compressed 属已知设计。
后续若扩展，请直接复用本审计的扫描器跑守卫/互斥矩阵。

### L7 — 热修残留

`libopencode-crshim.so`（LD_PRELOAD 变体，native-beta-260826 时代的临时方案）
在 26 个包二进制中 `crshim` / `libopencode-crshim.so` 字符串扫描均为零命中。
该热修资产只应存在于 native-beta-260826 release，不得混入新包 —— 达成。

### L8 — watcher 资产判定

包内不含 watcher 文件属**设计**（deb/pacman data 成员仅 `bin/opencode` +
`lib/opencode/libopencode-crhandler.so` 两个文件）。Push260903 release 资产亦无
`watcher.tar.gz`（Push260822 曾带过）。判定：**非缺口** —— watcher 栈
（`tools/watcher/`：`watcher.c` inotify 守护 + `shim.js` 插件侧）尚未纳入正式
发布矩阵，走仓库分发即可；若未来要分发，建议以独立 release 资产补挂，不阻塞
13 版批量。

## 二、缺口清单

| 编号 | 内容 | 状态 | 处置 |
|------|------|------|------|
| G2 | compressed deb Conflicts 漏 `opencode-glibc-standalone` | **已修**（本文档同批提交） | heredoc 真源 + 参考副本；**已构建的 compressed 包需重建后生效** |
| G1 | native pacman conflicts 缺 `opencode-glibc` 字面名 | 无需修 | 故意设计（provides 虚拟名保护），glibc 侧反向闭环实测成立 |
| R1 | release `Push260903` 资产为降级旧批 | 待办（超本任务权限） | 52 包 + SHA256SUMS 整批重传（本地重铸批已全绿） |
| R2 | `artifacts/transplant/1.18.25|26` 无 report.json | 待办（记录缺口） | 构建脚本为每版落 report（运行时无影响） |
| R3 | glibc 保留 `Replaces: opencode` | 观察 | 附录收尾时单独裁决是否移除 |

## 三、未来版本如何"自动吃到"（机制说明）

| 层 | 自动化机制 | 关键守门 |
|----|-----------|---------|
| L1 | `patches.json` 每 range 显式 `patch_required` + reason；hit_count=0 时按语义判 intentional-no-op / warning | dry-run 报告 per-version hit_count |
| L2 | `revive_patch.py` 按 Bun 版本自动选 size-mode（≤1.3.x reloc / ≥1.4.x plain-offset） | 每版落 `report.json`（R2 待补齐 25/26） |
| L3 | canonical build（单一真源 .so）+ swap 时 `has_ffi_guard` 机器码自检，无守卫 exit 5 拒收 | `make transplant` 管线内强制 |
| L4 | 打包脚本 `grep -aqF libopencode-crhandler.so` 二进制自检，引用而缺失即报错 | `PKGBUILD.native` package() + deb 脚本同款 |
| L5 | D1 教义矩阵 + 本审计扫描器可复跑（control/PKGINFO 全枚举比对） | compressed 冲突名单已闭合成完整矩阵 |
| L6 | compressed 单版本试点，扩展时复用 L3/L5 扫描器 | 无需逐版手工 |
| L7 | 新包二进制 `crshim` 字符串扫描（本审计扫描器内置） | 发布前跑一遍即可 |
| L8 | watcher 独立于包矩阵；若入发布矩阵则补 release 资产 + 本审计复跑 | 判定记录于证据日志 |

## 四、方法与证据

- 证据日志：`.omo/evidence/task-patch-coverage-audit.log`（逐层 PASS/FAIL 行，
  中断可续）。
- 扫描器：`$TMPDIR/opencode/audit_scanner.py`（临时件，逻辑要点已固化于本文 §一；
  ELF 动态段解析 + `swap_tui` 守卫复用 + tar 流内扫描，无盘上展开）。
- 关键指纹：canonical TUI `bfc631c84748c63c`（5878192 B）；crhandler
  `ebf59e44e737f2ed`（8104 B）；守卫实测 clamp=6 / csel_vs=12。
- 本地重铸批 deb 尺寸示例：1.18.15 = 40056252 B（远端旧批 40057724 B，不等）。

## 五、残余风险

1. **远端 release 仍是降级批（R1）**：远端资产时间戳 2026-09-04 01:56–02:28 UTC，
   早于本地重铸（18:51–19:37 本地时区），且 release 标题自注
   "[demoted: TUI patch insufficient]"。在重传完成前，**不要**引导用户从
   Push260903 直接下载。
2. 修复 G2 后已构建的 `opencode-compressed_1.18.21` deb 未重建，现存产物仍是
   旧冲突名单（属生成物，按仓库纪律不手改）。

## 六、交叉引用

- `docs/tui-common-fix.md` — TUI 公共层缺陷的根因、修复与三提交链。
- `docs/transplant.md` — 复活手术与 size-mode 机制。
- `docs/dual-track-install.md` — 安装矩阵与家族语义。
- `tools/transplant/swap_tui.py` — 守卫扫描/拒收实现。
- `scripts/package/package_deb_compressed.sh` — G2 修复真源。
