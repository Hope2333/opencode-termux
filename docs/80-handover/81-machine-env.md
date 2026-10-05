# D2 — 机器与环境手册

> **快照基线**: 2026-09-30（交接快照日）；本文件落笔 2026-10-01。
> **范围**: 本机（Termux u0_a450）+ 实验机 10.254.129.10 + fake-IP 代理网络 + 磁盘纪律 + pacman RootDir 双机差异 + 外部仓库克隆/缓存约定。
> **证据约定**: 每条后括注在案来源（`file:line` / commit / evidence 路径）；**无在案证据的不写**——本手册不承载推断。

---

## 1. fake-IP 代理环境

本机走 fake-IP 透明代理（TUN 模式），DNS 回答假 IP，真连接由代理侧接管。这决定了所有 GitHub 相关操作的可用性分层。

### 1.1 白名单行为（`docs/90-incidents/91-ops-lessons-rc3.md:38-42`，2026-09-28 记录）

- **透明代理白名单制**：`api.github.com` 常通；`uploads.github.com` / `github.com` 可能被掐。
  - 被掐症状：`curl` 返回 `code=000`，或 TLS ClientHello 阶段即被 reset。
- **直连真 IP 也会被 SNI 无差别 reset，DoH 逃生门同样被掐** → 只能等代理放行，别盲试。
  - 注意这条是「真 IP + SNI 组合被掐」的记录；下面 §1.3 的 `--resolve` 法之所以能用，是因为它同时配合了上传专用形态与代理放行窗口，属**另一条实证路径**，两者不矛盾。
- 分层结论（实证）：`gh` 走 API（`api.github.com`）正常；资产**上传**（`uploads.github.com`）最脆；`git push` 见 §1.4。

### 1.2 codeload 抖动与 git clone 双路（`docs/90-incidents/91-ops-lessons-rc3.md:64`，2026-09-29；`docs/10-build/15-native-line-evolution.md:67`）

- **codeload.github.com 间歇阻断**（fake-IP 白名单外抖动）——tarball 拉取不可靠。
- **双路取源**：`git clone --depth 1 --branch vX` 直连 `github.com` 主机稳定（fake-IP 白名单内）。
- tarball 下载后**必须 `gzip -t` 完整性校验**：`--max-time` 截断会产出半截包，播种坏源坑后续构建。
- 现役代码：`scripts/build-bionic.sh:62` 的 `curl -fsSL https://codeload.github.com/anomalyco/opencode/tar.gz/v${VER}` 是兜底路之一。

### 1.3 gh 直传 EOF → curl --resolve 真 IP 法

- **病历**: fake-IP 下 `gh release upload` / curl 直传 `uploads.github.com` **断流 EOF**（RC2 资产批实证，2026-09-24 v12.0 changelog 回写）。
- **回退配方**:
  ```bash
  # 1) DoH 取真 IP（dns.google resolve）
  # 2) 逐资产上传，SNI/解析钉死真 IP
  curl --resolve "uploads.github.com:443:$ip" -K <netrc-or-config> --data-binary ... \
       https://uploads.github.com/repos/Hope2333/<repo>/releases/<id>/assets?name=<name>
  # 预期逐资产 201
  ```
- **分工**: 列表/删除走 `gh api`（`api主机通`），**只有上传**走 `curl --resolve`。
- **在案样例脚本**（可直接复用）:
  - `.omo/evidence/opencode-v2-port/rc2-rebuild/upload29-curl.sh`（29 资产批）
  - 同目录 `upload-26-curl.sh` / `upload6-curl.sh` / `upload-hook*.sh`（同模式）
  - 脚本头注释原文：`uploads.github.com 走 curl --resolve 真 IP（fake-IP 被掐绕行）；列表/删除走 gh api（api 主机通）`
- **出处**: `.omo/plans/termux-asset-update.md:40`（v12.0 changelog ⑤「上传回退=curl `--resolve` 真 IP（gh 直传 fake-IP EOF，upload29-curl.sh 样例）」）、`:495`、`:671`（trap 24）。
- （2026-09-30 快照）当前主路径：等代理放行后普通 curl / `gh release upload --clobber`（`Makefile:760`、`:779`，失败置 `upload_failed=1`）；`--resolve` 是断流时的兜底，不是默认。

### 1.4 ssh.github.com:443 绕行（`.omo/plans/termux-asset-update.md:642`、`:665`，trap 18，v7.3）

- **push 网络路径三分化**:
  | 路径 | 状态 |
  |---|---|
  | `github.com:22`（SSH 标准口） | 被代理拦截 |
  | `github.com:443` 直连 | 被墙 |
  | **`ssh.github.com:443`** | **可用**（key `~/.ssh/id_ed25519_github`） |
- **workflow 文件 push 必须走 SSH**（HTTPS push 不带 workflow 变更的能力受限于同一 trap）；`gh` API 走 HTTPS 不受影响。
- 普通 push 备选：`git push https://github.com/Hope2333/<repo>.git <branch>`（先 `gh auth setup-git`）。
- 实证引用：`opencode-compressed-plan.md:60` 记录 commit `05c4ee0` 经 `ssh.github.com:443` 路径 push。

### 1.5 同环境已知副作用

- `fetch.py` 的 `Content-Length` 可能被代理/分块剥掉 → fleet-push 进度条恒 0%（下载本身正常）。已修为控制器传入期望 size 兜底（`f5102fb`），`pct` 封顶 100（`docs/90-incidents/91-ops-lessons-rc3.md:41`）。

---

## 2. $PREFIX/glibc 双重路径 symlink 桥接

- **事件**: 2026-09-29 本机 `$PREFIX/glibc` 消失事件——wrapper 门空输出的真因是本机 vendored glibc 运行时缺失（连货架 2.0.12 wrapper 都报 `open ld.so failed`）。
- **根因**: gpkg glibc 包 payload 路径自带 `data/data/com.termux/files/usr/glibc` 前缀，在 `RootDir=/data/data/com.termux/files` 下装入**双重嵌套路径**（前缀被二次拼接）。
- **修复（已实施）**: 最小**文件级**符号链接桥接——343 个运行库文件逐个链接回预期位置。
- **诊断教训**: wrapper 门失败**先测货架旧 wrapper** 是否同样失败，区分「包坏了」vs「机器环境坏了」。
- 出处: `docs/90-incidents/91-ops-lessons-rc3.md:69`（§9，2026-09-29）。

## 3. termux-exec preload 与 glibc libc.so 脚本陷阱

- **陷阱本体**: 桥接 `$PREFIX/glibc` 时**绝不能用目录级链接**。
- **机制**: glibc 包里的 `libc.so` 是**文本 ld script**（linker script），不是 ELF；若整目录链到 `$PREFIX/lib`/`glibc/lib`，该脚本会被暴露给 **termux-exec preload**（exec 钩子按 ELF 解析一切被加载文件）。
- **后果**: `bash` 启动即死 `invalid ELF header`（连 shell 都起不来，机器不可用）。
- **铁律**: 只做文件级 symlink，**显式排除 `libc.so` 文本 ld script**（343 文件清单法，见 §2）。
- 出处: `docs/90-incidents/91-ops-lessons-rc3.md:69`（同段记录）。

---

## 4. 实验机 10.254.129.10:8022

| 项 | 值 | 来源 |
|---|---|---|
| 地址/端口 | `10.254.129.10:8022` | `docs/80-handover/83-open-items.md:28` |
| 登录 | `u0_a115` 免密（`ssh -p 8022 u0_a115@10.254.129.10`，BatchMode） | `./83-open-items.md:28`；`.omo/evidence/rc3-release/t5-dual-verify.sh:8-9` |
| 机型/系统 | oscar/OC105，Android 9，Termux **0.117.18** | `.omo/drafts/ISSUS@001-field-install-layout-anomaly.md:72` |
| kernel | **3.18.140**（MoKee） | `task-17-rootdir.md`（`--version` 实证行）；`.omo/plans/v2-upx-revival.md:54` |
| 对照本机 kernel | 6.6.118-4k | `.omo/plans/v2-upx-revival.md:54` |

**金丝雀用途**（旧内核/旧 Android 现场环境的第二验证台）:

1. **双机验证第二台**：RC5 = 本机 + 实验机（3.18.140）装 RC5 gnu 包 → `--version` + PTY smoke（`.omo/plans/rc5-b1-release.md:37`，QA：实验机 ssh 免密已配 `:39`）。
2. **v2.0.12 compressed 双机冒烟**（v2-upx-revival T5，同计划 `:54-56`）。
3. **pacman RootDir 现场诊断实证机**（2026-09-29，见 §6.1）。
4. **现场安装事故取样机**：2026-09-30 在其上实证「手工安装落点双层 bin」事故（`$PREFIX/bin/bin/opencode1`，A 类现场装错，归因见 ISSUS@001 draft）。

**当前状态（交接快照，2026-09-30）**:

- **离线**（2026-09-30 快照）——RC5 实验机验证条款挂起，阻塞点=设备离线（`docs/80-handover/83-open-items.md:26-31`）。
- 设备上线后要跑：v2.0.x compressed 双机安装冒烟（v2-upx-revival T5）。

**补充关联机**:

- `192.168.1.22:8022` = 干净 Termux apt 环境测试机（glibc 最小依赖测试 host，`docs/30-testing/31-glibc-min-deps-test-report.md:11`）——与本手册的 10.254.129.10 不是同一台。

---

## 5. 磁盘纪律

### 5.1 ENOSPC 病历

- **2026-09-29（RC4 期）**: 13 版批量构建场景下立「ENOSPC 纪律」（`docs/90-incidents/91-ops-lessons-rc3.md:65`）:
  1. 批量构建**前**先过 df 闸；
  2. `$TMPDIR/v2src` 源树 / 中间件（`*.pre-crhandler`）**用完即清**；
  3. `~/.bun/install/cache` 单项可达 **3.4G**——必须有上限 GC。
- 同源纪律回写：`.omo/plans/termux-asset-update.md:44`（v12.2 ⑦「批量构建前 df 闸 + 构建后 clean-version 自洁 + `.pre-crhandler` 中间件清理」）。

### 5.2 df 闸（`df_gate`，`scripts/build-hygiene.sh:51`）

- 阈值：`DF_MIN_KB` 默认 **3000000** KB（≈3.0 GB，`:9`）；取数 `free_kb()` = `df -k /data` 第 4 列。
- 行为：不足阈值则**先扫后判**，最多 4 轮，顺序固定:
  1. `sweep_intermediates` —— 删 `artifacts/build/**/*.pre-crhandler`（`KEEP_BINS=1` 时保留 `opencode-native-revived`）；
  2. `bun_cache_gc` —— bun cache 上限 `BUN_CACHE_CAP_KB=2097152`（2 GB），按 mtime 旧者先删（GNU `find -printf`；toybox `ls -t` 方向相反是已录坑）；
  3. `sweep_trees` —— `$TMPDIR/v2src/opencode-*` 源码树只留 `TREE_KEEP=2` 棵。
- 仍不足 → 返回 1（闸不放行），日志落 `HYG_LOG`（默认 `${TMPDIR}/build-hygiene.log`）。
- 计划状态: 函数库 `1a2c179` + LRU 修复 `0b3bfd3` 已落；build-hygiene 计划任务 2-6 未跑（`docs/80-handover/83-open-items.md:33-36`）。

### 5.3 清理清单

| 命令 | 作用 | 出处 |
|---|---|---|
| `make clean` | 删 `artifacts/staged`、`packing/dpkg/work`、`packing/pacman/{pkg,src}` | `Makefile:690` |
| `make clean-artifacts VER=<v>` | 只删 `artifacts/transplant/<VER>` | `Makefile:625` |
| `make clean-version VER=<v>` | **四清**（afb31db）：①`$TMPDIR/v2src/opencode-<ver>` 解包树 ②`artifacts/staged` + 三个 `packing/dpkg*/work` + `packing/pacman/{pkg,src}` ③`artifacts/transplant/<ver>` ④`artifacts/wrapper/<ver>` | `Makefile:634-686`、`docs/90-incidents/91-ops-lessons-rc3.md:26` |

- **保留项**（四清不碰）: `artifacts/build/<ver>`（bin+sha+json）、`packing` 交付包、`$TMPDIR/v2src/*.tgz`、`artifacts/transplant/android-bun`、`artifacts/wrapper/glibc-standalone`。
- **bin 守卫**: `artifacts/build/<ver>` 在但 `opencode-native-revived` 缺失 → 拒清退出（`Makefile:660`）。
- **`NOT_CLEAN=1` 全链退出**（batch/batch-v2 循环尾、六 family 尾、子 make 透传）——两条硬规则:
  1. **`release-upload NATIVE=1` 必须带 `NOT_CLEAN=1`**，否则上传源 `artifacts/transplant/<ver>` 会被自洁吞掉（`docs/90-incidents/91-ops-lessons-rc3.md:30`、`Makefile:709` 注释）；
  2. wrapper-only 批次在 bin 已被磁盘清理删掉时，用 `NOT_CLEAN=1` 绕过守卫误伤（`docs/90-incidents/91-ops-lessons-rc3.md:70`）。
- **Make 配方陷阱**: make 逐行配方 = 每行独立 shell，`exit 0` 拦不住后续行——守卫/执行/校验必须合并进单个 shell 调用（`docs/90-incidents/91-ops-lessons-rc3.md:32`）。

---

## 6. pacman RootDir 双机档案 + .INSTALL /usr/tmp 限制

### 6.1 双机 pacman.conf 档案（2026-09-29 诊断，`.omo/evidence/rc3-release/task-17-rootdir.md`）

症状：实验机 `pacman -U opencode-2.0.12-3...` → `Partition / is mounted read only` + `not enough free disk space`。

| 项 | 参照机（OK，本机形态） | 实验机（坏） |
|---|---|---|
| `RootDir` | `/data/data/com.termux/files` | `#RootDir = /`（被注释 → alpm 编译默认 `/`） |
| `DBPath/LogFile/CacheDir/HookDir/GPGDir` | 均在 | **全缺**（alpm 把编译默认 dbpath 拼到 RootDir → 双重路径） |
| `pacman.d/hooks`、`gnupg` 目录 | 有 | 无（补指令后 pacman-conf 解析报错） |

- **修复**（已实证）: 取消注释 `RootDir = /data/data/com.termux/files` + 补 DBPath 块 + mkdir 各目录 → `pacman -U OK`（需 `--overwrite 'usr/*'` 清掉 stale 无主 `opencode 1.17.9-1` 残留）→ `opencode --version` = v2.0.12，kernel 3.18.140（MoKee）。
- **self-heal**: `install.sh` self-heal v2 已随 wiki repo commit `49968d0` 出货。
- **未结**: issue #17 报「`pacman -U` 写 `/usr`」——本机（2.0.18-1）`pacman -U` 正常，需对方提供 `pacman -v`（RootDir/DBPath）判其配置差异（`docs/90-incidents/91-ops-lessons-rc3.md:50`）。

### 6.2 .INSTALL /usr/tmp alpm 限制（commit `89d8d4b`）

- **commit**: `89d8d4b`（2026-09-30 01:39:55 +0800）`docs: RC4 field feedback — mirrorlist non-atomic db/pkg pair bug + .INSTALL /usr/tmp alpm limitation (mozzaru 2/2 repro)`——改 `docs/99-reference/99-open-issues-and-upstream-sync.md` 一处 +9 行。
- **`.INSTALL` 钩子静默不跑（mozzaru 2/2 复现）**（`docs/99-reference/99-open-issues-and-upstream-sync.md:131`）:
  - 现象: `post_install`/`pre_remove` 报 `/usr/tmp/alpm_*/.INSTALL: No such file`；`pacman -R` 后残留 `$PREFIX/bin/opencode`。
  - 根因: termux-pacman libalpm **事务临时目录落在 `/usr/tmp`**（Android 上只读/不可用）。
  - 处置: **RC5 包装轮**——关键逻辑迁 **pacman hook 文件**（HookDir 是真实路径，§6.1 表中 HookDir 行）；`.INSTALL` 降级 best-effort 并文档化。
  - 现场同源观察: 实验机上 `.INSTALL` `post_upgrade` 同样失败，非致命（2.0.12 不在 stale-serve-kill 区间）（`task-17-rootdir.md` Note 行）。
- **同 commit 另一条**: mirrorlist db/pkg **非原子对**——Server 走 `releases/latest/download/`，latest 漂移（RC4 上线）期 db 与 pkg 来自不同轮 site-rebuild 自愈（`99-open-issues:130`）。处置: site-rebuild db+pkg 原子成对上传（用户侧自动化，待修）；货架已收敛（`7ec10039` 双向验证）。open item 见 `docs/80-handover/83-open-items.md:20-24`。

---

## 7. 外部仓库克隆与缓存约定（2026-10-05 用户确立）

**约定本体**：

1. 克隆/缓存外部仓库（如 bun-termux-loader）**只允许**放在：① 本仓（opencode-termux）内的临时 tmp 目录，或 ② env 显式指定的缓存目录。
2. opencode-termux 一律使用外部仓库的**最新**版本。上游仓库（如 btl）持续保持 GitHub 上的最新最佳状态，本地缓存**自动拉取并同步到最新**。
3. **禁止**在解析逻辑里做「优先选某个本地副本」——副本漂移的根就在这。

**Why（病历，约定存在的理由）**：2026-10-05 实测发现本仓 `Makefile:831`（`V2_LOADER_ROOT`）解析 bun-termux-loader 时优先选中旧本地副本 `~/bun-termux-loader`（停在 `15a4ced`，缺 readlink 截断修复），而活跃且已修复的副本在 `~/develop/bun-termux-loader`（`8da3340`）——结果是 wrapper-native 实际一直在用有缺陷的那个版本。用户裁决：**不改 Makefile 的解析顺序**（文档层解决，不动代码），而是确立本约定，让「本地只缓存最新 + 缓存放仓内 tmp」从根上消除副本漂移。

**配套事实（btl 侧，2026-10-05）**：

- btl 活跃副本 HEAD 曾带**未解决冲突标记**导致编译不过，已修复并 push。
- 另修 btl 缓存**仅按 size 校验**的缺陷——同尺寸的损坏缓存会被复用（红绿测试留证）。
- readlink 截断防护已随 `8da3340` 落地（旧副本 `15a4ced` 缺它）。

---

## 附：本手册的维护规则

1. 新增条目必须带**当日 evidence 或 commit 引用**（`handover-docs` 计划 D2 验收条款，`.omo/plans/handover-docs.md:35`）。
2. 事实快照类内容（机器在线状态、实验机 kernel）以 `docs/80-handover/83-open-items.md` 的快照日期为准；冲突时以新快照覆盖并在条目里写明日期。
3. 网络章节（§1）各路径的可用性会随代理策略漂移——每次断流事故后按 §1.1 三症状归类，再决定是否新增回退法。
