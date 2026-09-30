# 发布运行手册（Release Runbook）

> **适用**：opencode-termux 滚动 Push tag 发布全流程（v1 `opencode1*` 1.18.x + v2 `opencode*` 2.0.x 双代）。
> **来源**：`docs/ops-lessons-rc3.md`（2026-09-28 起 RC3/RC4/RC5 实战）、`docs/native-line-evolution.md`（2026-09-28 RC4 收口期）、`docs/make-maintainer.md`、`.omo/plans/termux-asset-update.md`（v12.x changelog + TL;DR）、`Makefile` help 段。
> **事实基线**：RC5 = Push260930（2026-09-30，B1/native-gnu 定版，38 件，PKGREL=5）；RC4 = Push260928（2026-09-29，B2/native-musl 定版，96 资产存档）。
> **旁注**：实验机 10.254.129.10:8022 于 2026-09-30 快照离线，第 9 节双机验证待设备上线。

---

## 1. 环境自检

批量构建前必须先过三道闸：磁盘、工具链、gh 授权。ENOSPC 病历在案（2026-09-28：13 版批量构建前未 df 闸）。

```bash
# ① 磁盘闸（df 闸，v12.2 教义 2026-09-28：批量构建前先判，不足先扫后判）
df -k /data | tail -1 | awk '{print $4}'        # 剩余 KB；build-hygiene free_kb() 口径
source scripts/build-hygiene.sh && df_gate 3000000   # F1：先扫（中间件→bun cache→树）后判，不足返回 1

# ② 工具链版本
upx --version                                   # compressed 线（fleet UPX 资产）
clang --version                                 # harden-native：clang 编 libopencode-crhandler.so
bun --version                                   # 底座 pin bun@1.4.0（1.4.2 在 bionic SIGSEGV@0x40，见 §4）

# ③ gh 授权（全部 gh 命令统一带 GIT_SSL_NO_VERIFY=1 GH_INSECURE=1）
GIT_SSL_NO_VERIFY=1 GH_INSECURE=1 gh auth status

# ④ 间隔检查（v11.3 纪律，2026-09-14 起：无论是否新版本先做）
GIT_SSL_NO_VERIFY=1 GH_INSECURE=1 gh release list --repo Hope2333/opencode-termux --limit 1 --json publishedAt --jq '.[0].publishedAt'
```

- `df_gate FAIL` 即停：先 `tools/maintain.sh --clear`（默认只出统计，`LAYERS=<层> CONFIRM=1` 才删）。
- 单项缓存可观：`~/.bun/install/cache` 单项可达 3.4G（2026-09-29 实测）。

## 2. PTY_VARIANT 选择（musl 默认 vs gnu B1 continuation）

开关在 `scripts/build-bionic.sh`（commit 4952235，2026-09-30 落地），默认 `musl` 行为不变。env 变量随 make 逐级下发（与 `PKGREL` 同一传输机制，见 §6）。

| 变体 | 值 | 含义 | 何时用 |
|---|---|---|---|
| B2（native-musl，RC4 起） | `PTY_VARIANT=musl`（默认） | 换入上游官方 `@opencode-ai/pty-linux-arm64-musl` 全静态变体（无 INTERP/无 NEEDED） | 默认路线；RC4 = Push260928 定版（2026-09-29） |
| B1（native-gnu 延续） | `PTY_VARIANT=gnu` | GNU glibc 资产原样嵌入（B 线手术残留） | RC5 = Push260930 定版（2026-09-30，`PTY_VARIANT=gnu` 重建 19 版） |

```bash
# B1（gnu 延续，RC5 用）/ B2（musl 默认）双模式构建
PTY_VARIANT=gnu  PKGREL=5 make family-v2-native VER=2.0.18
PTY_VARIANT=musl PKGREL=5 make family-v2-native VER=2.0.18
```

- **构建后逐版嵌入哈希断言（防时序混入）**：`strings` 检索 musl / gnu 哈希计数（`f9b069d3…` / `25e9273e…`），期望 gnu 模式 = gnu≥1、musl=0；musl 模式 = musl≥1、gnu=0（RC5 实测口径 gnu≥1/musl=0）。RC4 首批 14 包即因合入前构建带旧资产而全量重建。
- 方案背景（#27，RFC discussions/29）：B1 构建/运行双稳（含零 glibc 环境、PTY/agent-pty 调试通过），仅脆弱环境暴露加载失败，patchelf 无法兜底（死于 `__libc_start_main` 入口 ABI）；B2 为 RC4 实证可跑的纯度正解。
- B1/B2 差异表补注：UPX 压制层与 PTY 变体无关——2026-09-30 受控实验坐实 gnu/musl 双基底直压均 SIGSEGV、未压制对照全活（详见 §4 v2 compressed 注意项）。

## 3. 源码获取双路（GitHub direct + npm tarball fallback）

2026-09-29 教训：codeload.github.com 在 fake-IP 代理白名单外间歇阻断，半截包会播种坏源坑后续构建。

```bash
# 主路：git clone 直连 github.com 主机（fake-IP 白名单内稳定）
git clone --depth 1 --branch v2.0.18 --single-branch -q https://github.com/anomalyco/opencode "$tree"

# 兜底路：tarball 下载后必须完整性校验（--max-time 截断会产出半截包）
gzip -t opencode-<ver>.tgz          # 不过校验 = 废弃重下，禁止入构建

# v1 glibc 附录线的上游版本核对（npm 口径；native 线独立跟踪）
npm view opencode-linux-arm64 version
```

- `npm pack` 在构建期抓包（download-chain 缓存 = `npm-cacache` 层，`make clear` 可清）。
- 依赖树：`bun install`（B 线流水第 ① 步，bun 底座 1.4.0）。

## 4. family 构建

**v1（1.18.x 兼容线）**——family 数组单命令派发（wrapper → native → compressed 顺序执行）：

```bash
make family=wrapper,native,compressed VER=1.18.x
# 等价逐家族：make family-wrapper VER=… / make family-native VER=… / make family-compressed VER=…
# v1 native 走 A 线：make transplant VER=<v> && make transplant-check   # goldens 回归（先 scripts/fetch-fixtures.sh）
# A 线顺序不可换：revive → swap_tui →（compressed）UPX 最后一步；packed 产物不可再 revive
```

**v2（2.0.x 主线）**——B 线 `scripts/build-bionic.sh`，单家族与批量：

```bash
make family-v2-native  VER=2.0.x     # → artifacts/build/<v>/opencode-native-revived；日志须 rc2b sweep OK
make family-v2-wrapper VER=2.0.x     # → packing/dpkg/opencode-wrapper_<v>_aarch64.deb + packing/pacman/opencode-wrapper-<v>-*
make batch-v2 VERS='2.0.[0-18]' PKG=native    # 区间展开批量（或 PKG=wrapper）
./artifacts/build/<v>/opencode-native-revived --version     # 期望 opencode v2.0.x
```

**v2 compressed**：见 `.omo/plans/v2-upx-revival.md`——UPX 三路线矩阵已裁决（2026-09-30）：R-B1(gnu)/R-B2(musl) 直压双 SIGSEGV、未压制对照全活；R-A 外包配方取证中（opencode-compressed-branch 实体未寻获）。

**硬约束**：

- `make batch` 600s 超时不可靠 → 逐版本 900s；`make clean` 会抹 PKGBUILD → clean 后 `git restore packing/`。
- **makepkg 并发互斥（2026-09-29）**：batch-v2 的 native 与 wrapper 批次共享 `packing/pacman/{src,pkg}`，必须串行排队，禁止并行。
- `family-glibc` 已不存在（2026-09-12 v9.0 更名链），引用旧名 = 构建即 FAIL。
- hook 注册表（`ff9bcd7`）：`stale-serve-kill` 默认仅 v2 `2.0.[0-3]` 发射，可用 `HOOKS_ENABLE` / `HOOKS_DISABLE` 覆盖（Makefile 顶部注册表）。

## 5. build-hygiene（clean-version 自洁 / df_gate / bun cache LRU）

函数库 `scripts/build-hygiene.sh`（commit `1a2c179` 函数库 + `0b3bfd3` LRU 修复，2026-09-29 落地）：

```bash
# 四清（commit afb31db）：v2src 解包树 / artifacts/staged + packing work + pacman {pkg,src}
#   / artifacts/transplant/<ver> / artifacts/wrapper/<ver>
# 保留：artifacts/build/<ver>（bin+sha+json）、packing 交付包、v2src/*.tgz、android-bun、glibc-standalone
make clean-version VER=2.0.18
NOT_CLEAN=1 make family-v2-native VER=2.0.18    # 退出自洁（bin 缺失守卫同路）

# 三函数入口
df_gate 3000000          # F1 磁盘闸（先扫后判）
bun_cache_gc             # F3 bun cache LRU：按顶层目录 mtime 最旧优先删，直到低于 BUN_CACHE_CAP_KB
sweep_intermediates      # 中间件（.pre-crhandler 等）清理
```

- **尾自洁纪律（2026-09-28 起）**：batch / batch-v2 / family 尾自动 `clean-version`（`NOT_CLEAN=1` 退出）。
- **⚠ `release-upload NATIVE=1` 必须带 `NOT_CLEAN=1`**——否则上传源 `artifacts/transplant/<ver>` 被自洁吞掉。
- **make 配方陷阱**：逐行配方 = 每行独立 shell，`exit 0` 拦不住后续行；守卫/执行/校验必须合并进单个 shell 调用。
- 缓存分层清理：`make clear`（统计）→ `make clear LAYERS=compressed-work,staged-trees CONFIRM=1`；上传后一键 `tools/maintain.sh --upload --tag <TAG> --family compressed --auto-clean`（前置 = 本次 run 有 upload，`--dry-run` 不执行）。

## 6. PKGREL 策略（native 顺延 5+ / compressed 独立序列）

| 线 | 机制 | 序列事实 |
|---|---|---|
| deb（全家族） | 无 pkgrel 概念，Version 不变 = `--clobber` 覆盖 | 同名覆盖，天然上架 |
| native pac | `PKGREL="${PKGREL:-1}"` → sed pkgrel（原生支持） | RC3=`-3`（2026-09-28）→ RC4=`-4`（2026-09-29，shim 修复 217f88d）→ RC5=`-5`（2026-09-30）→ **顺延 5+** |
| wrapper v2 pac | `22bcb94` 修硬编码后 env 化 | Push260928 上 `-3` |
| compressed pac | `package_pacman_compressed.sh` env 化，恒 `.pkg.tar.gz` | **独立序列先例，不外溢到 native** |

```bash
# env 传输：命令行 PKGREL 经环境变量自动传给全部子 make，无需逐级改 Makefile
PKGREL=6 make batch-v2 VERS='2.0.[0-18]' PKG=native
PKGREL=6 PTY_VARIANT=gnu make family-v2-native VER=2.0.18
```

- **`84086a9` PKGREL-adaptive discovery**：`tools/fleet-push.py` 四处硬编码 `-1-` 改为 `-\d+-` 通配 + 同版本多 pkgrel 取最高，防旧 `-1` 残留（1.4.2 时代包）被误分发。
- **改 PKGREL = 改 pac 产物名，旧 rel 不自动下架**——升级 rel 前先决定是否逐 id 删旧件（见 §7）。
- 三打包脚本（`package_pacman_native.sh` / `package_pacman_compressed.sh` / `package_wrapper_v2.sh`）均已 env 化，`PKGREL` 一路透传到底。

## 7. 上架（--clobber / --resolve 真 IP / digest 对账）

```bash
# 主路：make 维护入口（逐文件 gh release upload --clobber，缺 release 时新建 prerelease）
make maintain-upload TAG=Push260930
make maintain-upload TAG=Push260930 FAMILY=native
make maintain-upload TAG=Push260930 FAMILY=compressed DRY=1     # fleet 演练先 dry-run
tools/maintain.sh --upload --tag Push260930 --family compressed

# 逐件直传（TL;DR 口径）
gh release upload <TAG> packing/dpkg/<pkg>_<ver>_aarch64.deb            --repo Hope2333/opencode-termux --clobber
gh release upload <TAG> packing/pacman/<pkg>-<ver>-<rel>-aarch64.pkg.tar.xz --repo Hope2333/opencode-termux --clobber

# 回退（2026-09-24 v12.0）：gh 直传 fake-IP 断流（EOF）→ curl -K 配置文件 + --resolve 真 IP，逐资产 201
#   curl --resolve uploads.github.com:443:<DoH 真IP> …（样例：.omo/evidence/opencode-v2-port/rc2-rebuild/upload29-curl.sh）
#   直连真 IP 也会被 SNI 无差别 reset、DoH 逃生门同被掐 → 只能等代理放行

# 指纹链（v7.1）
sha256sum <assets...> > SHA256SUMS.txt
gh release upload <TAG> SHA256SUMS.txt --repo Hope2333/opencode-termux --clobber
# ELF 资产上传前 xz -9（教义）：xz -9 -T0 artifacts/transplant/<v>/opencode-native-revived-upx

# 新鲜度对账（发布门禁，RC1 12 stale 教训）：REST digest == 本地 sha256
bash .omo/evidence/opencode-v2-port/rc2-rebuild/upload29-verify.sh
```

- **digest 对账细则（2026-09-28）**：API `digest` 字段（`sha256:<hex>`）与本地 sha256 直接比；`--clobber` 只对 deb 生效；勿只看 upload exit 0（包体大小以本地 sha256 为准）。
- 清空重铸前先落盘 `releases/<id>/assets?per_page=100` 的 id+name 清单对账，逐 id DELETE（204=成功，404=跳过，失败重试 3 次）。
- 件数账：清空 N → 新上 M → 架上 = M + site-rebuild 自愈回传件（db/mirrorlist 自动出现，勿重复传）。
- fleet（compressed 多节点）：`tools/maintain.sh --nodes-init` 建 `artifacts/fleet-nodes.yaml`；续作 journal `artifacts/fleet-state.json`（跳过已完成 (node, version)、重试失败）；远端工作全部走节点 tmux。

## 8. note 模板（Push260906 式 BUILD LOG + 双代家族表）

双语教义定稿 2026-09-09，中文版正文 canonical（实例：io 仓 `wiki/opencode-termux/zh_CN/release/Push260906.md`）：

1. GitHub release note = 英文版，第 2 行 `[中文版](<io 中文页 URL>)`；io 站 = 中文版，顶部回链 GitHub Release。frontmatter 仅 `title` / `lang`。
2. **家族表按家族分行、只写包名/格式不写版本号**（v2 Native `opencode_*` / v2 Wrapper `opencode-wrapper_*` / v1 `opencode1*` + upx），版本区间只出现在 BUILD LOG。
3. **BUILD LOG = Push260803 事实风格**：日期行 = 资产 `created_at`(UTC) 逐日聚合，区间记法 `v<X.Y.{a-b}>`，不逐版本枚举、无包大小、无 sha 表格；末行 `最新版:` / `Latest:`。
4. 必带段落：互斥/共存声明（同代互斥、跨代 `opencode1*`×`opencode*` 可双装、v1 包 `<2.0.0` 界定）、Install（源配置一行 + 源装 + 手动装）、Verification（版本连续性 / SHA256SUMS / 双代矩阵 / 新鲜度）、Links。
5. 零 Contributors、零 `@user`；首传/补传 = first upload / backfill（勿沿用 "Lasted" 笔误）。

```text
## BUILD LOG
<YYYYMMDD>: v<X.Y.{a-b}> <涉及的家族/资产>
最新版: v<X.Y.Z>
```

- title 四段式（双代，v12.1 2026-09-28）：`<v2-lasted> <v1-lasted> <v2-库存区间> <v1-库存区间>`，段空塌缩删段。
- 发布 note：`GIT_SSL_NO_VERIFY=1 GH_INSECURE=1 gh release edit <TAG> --repo Hope2333/opencode-termux --notes-file <file>`（不要 `--title`；zsh 特殊字符 title 走 `gh api --input JSON`）。

## 9. 双机验证（本机 + 实验机）

```bash
# 本机
./artifacts/build/<v>/opencode-native-revived --version      # 或安装后 opencode --version
python3 .omo/evidence/opencode-v2-port/rc2-rebuild/matrix_v31.py   # 期望 MATRIX_ALL_GREEN（跨代零 BLOCKED + 同代互斥 + ELF 流 sha）

# 实验机（u0_a115@10.254.129.10 -p 8022，免密；2026-09-30 快照离线）
scp -P 8022 -q packing/pacman/opencode-<ver>-<rel>-aarch64.pkg.tar.xz u0_a115@10.254.129.10:/data/data/com.termux/files/usr/tmp/
ssh -p 8022 -o BatchMode=yes u0_a115@10.254.129.10 'pacman -U --noconfirm --overwrite "usr/*" /data/data/com.termux/files/usr/tmp/opencode-<ver>-<rel>-aarch64.pkg.tar.xz; pacman -Q opencode; timeout 30 opencode --version'

# 远程矩阵（Makefile help：机器层 lifecycle）
make matrix VERS='2.0.17 2.0.18' TARGET_HOST=10.254.129.10 TARGET_USER=u0_a115
```

- 门禁三件套（2026-09-24 起）：矩阵 `MATRIX_ALL_GREEN` + 新鲜度（REST digest==本地 sha）+ PTY 冒烟。
- wrapper 门失败先测货架旧 wrapper，区分「包坏了」vs「机器环境坏了」（2026-09-29 本机 `$PREFIX/glibc` 消失事件：343 个运行库文件文件级符号链接桥接、**排除 libc.so 文本 ld script**——目录级链接会让 termux-exec preload 启动即死 invalid ELF header）。
- compressed 验证一律走沙箱，不碰真实 `$PREFIX`：`pacman --root $TMPDIR/sb --noscriptlet --noconfirm -U <pkg>`。
- 双机 pacman RootDir 档案差异（Android 9 / Termux 0.117 双机）已入 `.omo/evidence/rc3-release/task-17-rootdir.md`（2026-09-29）。

## 10. Rolling / wiki 回写

```bash
# Push tag 规则（v8.2，2026-09-06 定）：当轮新建 Push<YYMMDD>，绝不追加既有 tag
TAG=Push$(date +%y%m%d)     # Makefile TAG ?= Push$(shell date +%y%m%d)

# 软件源联动（上传后必做——--clobber 不触发任何下游）
gh api -X POST repos/Hope2333/hope2333.github.io/dispatches -f event_type=site-rebuild
curl -s "https://github.com/Hope2333/opencode-termux/releases/latest/download/Packages.gz" | zcat | grep -E '^Package:|^Version:'

# wiki release 索引（v11.1 纪律，2026-09-12）：每新增 Push 页必须同步中英 index.md
#   wiki/opencode-termux/zh_CN/release/index.md
#   wiki/opencode-termux/release/index.md
#   新页：wiki/opencode-termux/zh_CN/release/Push<tag>.md → https://hope2333.github.io/wiki/opencode-termux/zh_CN/release/Push<tag>.html

# 推送路径：SSH 走 ssh.github.com:443（key ~/.ssh/id_ed25519_github）；workflow 文件改动必须 SSH（HTTPS 无 workflow scope 必败）
git push https://github.com/Hope2333/<repo>.git <branch>    # 普通 push 可走 HTTPS（先 gh auth setup-git）
```

- 正式发布后让位规则：新 Push 上架 → 旧 Push 降 prerelease 归档（Push260912→Push260922→Push260928 链），`releases/latest` 自动跟随最新正式件。
- 统一 db 保鲜：`make sync-db`（`DRY=1` 演练）兜底（site.yml HOPE_PAT 门控为双轨之一）。
- 收尾：`tools/maintain.sh --upload … --auto-clean` 或 `make clear`，并按 `.omo/plans/termux-asset-update.md` Wave 6 清理 + 重置计划状态。

---

## 附：B1/B2 双线速查

| 项 | B1（native-gnu） | B2（native-musl） |
|---|---|---|
| 开关 | `PTY_VARIANT=gnu` | `PTY_VARIANT=musl`（build-bionic 默认） |
| 定版 | RC5 = Push260930（2026-09-30），38 件，PKGREL=5 | RC4 = Push260928（2026-09-29），96 资产存档 |
| PTY 资产 | 上游 glibc 版原样嵌入（手术残留） | `pty-linux-arm64-musl` 全静态（7b271c7） |
| 风险 | 脆弱环境加载失败（#27），patchelf 不兜底 | 无（内核直接 exec），但需逐版哈希断言 |
| RFC | discussions/29 双语投票（👍① musl / 🎉② gnu / 🚀③ 双线 / 👀其他），2026-09-30 起收集 | 同左 |
