# opencode-termux 文档总索引（Canonical Index）

本目录是 Termux 打包 / 运行时工作流的**唯一真源**。2026-10-05 起 `docs/` 按**族树结构**
重组：按领域分入两位数字前缀的族目录，族内文件保留两位数字序号前缀（合起来即稳定公开路径）。

- **族目录** = 领域（`10-build/` = 构建与运行时）
- **文件序号** = 族内逻辑顺序（`10-build/14-transplant-pipeline.md` = 该族第 14 号）
- 原编号语义在族内保留（`11/12/13` 仍是 build 族的构建计划 / 二进制结构 / 运行时构建），
  便于历史追溯；完整「原名 → 新路径」对照见文末[迁移映射表](#迁移映射表原名--新路径)。

---

## 族树总览

| 族 | 领域 | 文件数 |
|---|---|---:|
| [`00-scope/`](00-scope/) | 目标、范围与环境基线 | 3 |
| [`10-build/`](10-build/) | 构建与运行时内部 | 7 |
| [`20-packaging/`](20-packaging/) | 打包、分发与服务 | 9 |
| [`30-testing/`](30-testing/) | 测试、验证与性能测量 | 5 |
| [`40-release/`](40-release/) | 发布与迁移运行手册 | 4 |
| [`50-automation/`](50-automation/) | CI 交接、Make 维护面、插件运维 | 7 |
| [`80-handover/`](80-handover/) | 交接快照（D1–D4 + 回忆包） | 5 |
| [`90-incidents/`](90-incidents/) | 事故与复盘 | 3 |
| [`99-reference/`](99-reference/) | 参考表、上游同步与研究 | 6 |
| [`cross-compile/`](cross-compile/) | 跨架构 / 交叉编译体系（独立工作流） | 6 |

---

## 推荐动线

### 新人阅读顺序（理解 → 能改包）

1. [`00-scope/01-scope-and-target.md`](00-scope/01-scope-and-target.md) — 项目目标与范围（**先看这份**）
2. [`00-scope/02-env-baseline-termux.md`](00-scope/02-env-baseline-termux.md) — Termux 环境硬约束（bionic、非标准 FHS、pacman）
3. [`00-scope/03-local-production.md`](00-scope/03-local-production.md) — 本地生产路径为权威（不走 GitHub Actions）
4. [`20-packaging/23-dual-track-install.md`](20-packaging/23-dual-track-install.md) — native 主线 vs wrapper 附录，选哪条线
5. [`10-build/14-transplant-pipeline.md`](10-build/14-transplant-pipeline.md) — native 线怎么构建（当前旗舰管线）
6. [`20-packaging/20-packaging-deb.md`](20-packaging/20-packaging-deb.md) + [`21-packaging-pacman.md`](20-packaging/21-packaging-pacman.md) — 两个渠道的打包形态
7. [`40-release/40-execution-checklist.md`](40-release/40-execution-checklist.md) — 安装/测试 runbook
8. [`30-testing/30-local-build-matrix.md`](30-testing/30-local-build-matrix.md) — 本地验证矩阵

### 发布者阅读顺序（ship 一版 → 上架 → 对账）

1. [`80-handover/80-release-runbook.md`](80-handover/80-release-runbook.md) — **D1 发布运行手册**（环境自检 → 构建 → hygiene → PKGREL → 上架 → 对账 → 双机）
2. [`80-handover/83-open-items.md`](80-handover/83-open-items.md) — 进行中与待决（发布前先看有没有未裁决项）
3. [`50-automation/50-make-maintainer.md`](50-automation/50-make-maintainer.md) — make 家族调度 / fleet push / cache 清理
4. [`20-packaging/22-termux-services-opencode-web.md`](20-packaging/22-termux-services-opencode-web.md) — `sv` 服务面（上架后验证）
5. [`90-incidents/91-ops-lessons-rc3.md`](90-incidents/91-ops-lessons-rc3.md) — RC3~5 实战经验（PKGREL 矩阵 / clean-version / chunk 漂移防线）
6. [`80-handover/82-community-state.md`](80-handover/82-community-state.md) — 社区与 issue 状态（发布后回帖）
7. [`40-release/42-upstream-notification-package-rename.md`](40-release/42-upstream-notification-package-rename.md) — 包名变更对外通告模板

---

## 分族清单

### `00-scope/` — 目标、范围与环境基线

| 文件 | 类型 | 一句话摘要 | 受众 |
|---|---|---|---|
| [`01-scope-and-target.md`](00-scope/01-scope-and-target.md) | scope | 项目范围与目标（bun + opencode 双包，可复现可验收） | 新人 |
| [`02-env-baseline-termux.md`](00-scope/02-env-baseline-termux.md) | env | Termux 环境基线：bionic、非标准 FHS、pacman 体系 | 新人 |
| [`03-local-production.md`](00-scope/03-local-production.md) | scope | 本地生产蓝图：为何禁用 GH Actions、canonical 输入/产物 | 维护者 |

### `10-build/` — 构建与运行时内部

| 文件 | 类型 | 一句话摘要 | 受众 |
|---|---|---|---|
| [`11-opencode-build-plan.md`](10-build/11-opencode-build-plan.md) | build | OpenCode 构建计划与运行时模式（staged 源码构建为首选路径） | 维护者 |
| [`12-bun-executable-structure.md`](10-build/12-bun-executable-structure.md) | runtime | `bun build --compile` 单文件产物结构与兼容性 | 维护者 |
| [`13-opencode-runtime-build.md`](10-build/13-opencode-runtime-build.md) | runtime | 官方 arm64 二进制 + bun-termux-loader 包装的运行时构建流程 | 维护者 |
| [`14-transplant-pipeline.md`](10-build/14-transplant-pipeline.md) | build | native 移植管线操作手册（extract→revive→verify，双格式复活手术 + TUI 注入） | 维护者 |
| [`15-native-line-evolution.md`](10-build/15-native-line-evolution.md) | reference | native 线演进史：ELF 拼接手术 → bionic 真编译 → 制度化 | 维护者 |
| [`16-tui-common-fix.md`](10-build/16-tui-common-fix.md) | incident | TUI `libopentui.so` 崩溃根因与公共层根治三提交链 | 维护者 |
| [`17-tui-reachability.md`](10-build/17-tui-reachability.md) | reference | TUI 可达性判定表（按 Android/bionic/内核组合查表 + 对位修补清单） | 维护者 |

### `20-packaging/` — 打包、分发与服务

| 文件 | 类型 | 一句话摘要 | 受众 |
|---|---|---|---|
| [`20-packaging-deb.md`](20-packaging/20-packaging-deb.md) | packaging | Debian 包布局、架构与依赖约束 | 维护者 |
| [`21-packaging-pacman.md`](20-packaging/21-packaging-pacman.md) | packaging | `pkg.tar.xz`（pacman）打包流程与 staged 布局约束 | 维护者 |
| [`22-termux-services-opencode-web.md`](20-packaging/22-termux-services-opencode-web.md) | packaging | `opencode web` 的 `sv` 常驻服务布局与生命周期 | 维护者 |
| [`23-dual-track-install.md`](20-packaging/23-dual-track-install.md) | packaging | `opencode` 双 provider 选择 + 包名时代分界（Push tag ↔ 家族） | 新人/发布者 |
| [`24-compressed-line-contract.md`](20-packaging/24-compressed-line-contract.md) | packaging | compressed 线契约：launcher-only（UPX memfd 下 `$ORIGIN` 失效）+ 陈旧 runtime 隔离 | 维护者 |
| [`25-plugin-packaging-design.md`](20-packaging/25-plugin-packaging-design.md) | packaging | 包管理器驱动的插件生命周期模型（apt + pacman） | 维护者 |
| [`26-system-skills-hook-architecture.md`](20-packaging/26-system-skills-hook-architecture.md) | packaging | 包模式 system skill + hook 框架（幂等、fail-soft、安全默认） | 维护者 |
| [`27-hook-design-proposal.md`](20-packaging/27-hook-design-proposal.md) | plan | 安装期 hook 的族归属与特征化提案（六族现状矩阵，未实现） | 维护者 |
| [`bundle-list.txt`](20-packaging/bundle-list.txt) | automation | 随包 documentation 清单（`scripts/build.sh` 读取，装入 `$PREFIX/share/opencode/docs`） | 维护者 |

### `30-testing/` — 测试、验证与性能测量

| 文件 | 类型 | 一句话摘要 | 受众 |
|---|---|---|---|
| [`30-local-build-matrix.md`](30-testing/30-local-build-matrix.md) | testing | 本地构建矩阵与环境采集（各组件构建策略与产物） | 新人/维护者 |
| [`31-glibc-min-deps-test-report.md`](30-testing/31-glibc-min-deps-test-report.md) | testing | glibc 依赖最小集实测报告（网络功能检查） | 维护者 |
| [`32-patch-coverage-audit.md`](30-testing/32-patch-coverage-audit.md) | testing | 八层补丁 × 13 版字节级产物审计（防「批量版没吃到」缺口） | 维护者 |
| [`33-performance-optimization.md`](30-testing/33-performance-optimization.md) | testing | 性能优化路线图（启动耗时 / TUI RSS / 零 glibc 目标与量化） | 维护者 |
| [`measurements/native-baseline-1.3.13.json`](30-testing/measurements/native-baseline-1.3.13.json) | testing | native 基线测量数据（C1 证伪记录，含 wrapper 对照） | 维护者 |

### `40-release/` — 发布与迁移运行手册

| 文件 | 类型 | 一句话摘要 | 受众 |
|---|---|---|---|
| [`40-execution-checklist.md`](40-release/40-execution-checklist.md) | release | 安装/测试执行清单（Phase A CI 交接 → Phase B 本地权威路径） | 新人/发布者 |
| [`41-migration-v1-to-v2.md`](40-release/41-migration-v1-to-v2.md) | release | v1 → v2 迁移指南（构建线 / 插件格式 / API / 配置 / 包名） | 发布者 |
| [`42-upstream-notification-package-rename.md`](40-release/42-upstream-notification-package-rename.md) | release | 包名变更对外通告（下游移植与 fork 适用） | 发布者 |
| [`43-termux-asset-release-flow.md`](40-release/43-termux-asset-release-flow.md) | release | Termux 仓库资产更新流程（多仓库获取 → 包装 → 打包 → 发布） | 发布者 |

> `43-termux-asset-release-flow.md` 是指向仓库外共享文档的**符号链接**（历史沿革，内容与
> `opencode-termux` 之外的姊妹仓库共用），移动时须保持链接本体，不得展开为普通文件。

### `50-automation/` — CI 交接、Make 维护面、插件运维

| 文件 | 类型 | 一句话摘要 | 受众 |
|---|---|---|---|
| [`50-make-maintainer.md`](50-automation/50-make-maintainer.md) | automation | make 维护面：家族数组调度、fleet push、cache 清理 | 维护者 |
| [`51-ci-prebuild-armv7.md`](50-automation/51-ci-prebuild-armv7.md) | automation | Phase A armv7 CI 预构建交接范围（attempt-based，非发布路径） | 维护者 |
| [`52-armv7-native-runner-setup.md`](50-automation/52-armv7-native-runner-setup.md) | automation | armv7 self-hosted runner 最小可用配置 | 维护者 |
| [`53-plugin-management.md`](50-automation/53-plugin-management.md) | automation | 插件安装 / 自更新 / 回滚（优先 `file://` 本地路径） | 维护者 |
| [`54-ci-fleet-switches.md`](50-automation/54-ci-fleet-switches.md) | automation | CI fleet 开关清单：位置、启用前置与风险（PREPARED 态登记，不含翻转） | 维护者 |
| [`55-fleet-decision-register.md`](50-automation/55-fleet-decision-register.md) | automation | 两套 D 编号对照 + CI D1–D6 决策寄存（待用户裁决） | 维护者 |
| [`quick-build.sh`](50-automation/quick-build.sh) | automation | 快速构建脚本（辅助脚本，非文档） | 维护者 |

### `80-handover/` — 交接快照（基线 2026-09-30）

| 文件 | 类型 | 一句话摘要 | 受众 |
|---|---|---|---|
| [`80-release-runbook.md`](80-handover/80-release-runbook.md) | release | D1 发布运行手册（全流程 9 节，最常用的发布文档） | 发布者 |
| [`81-machine-env.md`](80-handover/81-machine-env.md) | reference | D2 机器与环境手册（fake-IP 代理 / glibc 桥接 / 磁盘纪律 / 双机 RootDir） | 维护者 |
| [`82-community-state.md`](80-handover/82-community-state.md) | reference | D3 社区与 issue 状态（开放案 / 已闭案底 / 回帖模板与语言规则） | 发布者 |
| [`83-open-items.md`](80-handover/83-open-items.md) | plan | D4 进行中与待决清单（9 项，含阻塞点与下一步） | 维护者 |
| [`84-recall-pack.md`](80-handover/84-recall-pack.md) | plan | 回忆拼图包：唤醒 v1 压制亲历会话以解 UPX 复活方案 | 维护者 |

### `90-incidents/` — 事故与复盘

| 文件 | 类型 | 一句话摘要 | 受众 |
|---|---|---|---|
| [`90-2026-02-23-opencode-web-termux-so-avalanche.md`](90-incidents/90-2026-02-23-opencode-web-termux-so-avalanche.md) | incident | `opencode web` 下 `.*.so` 雪崩堆积（900+ 个 / 3.9GB）RCA | 维护者 |
| [`91-ops-lessons-rc3.md`](90-incidents/91-ops-lessons-rc3.md) | incident | RC3 发布实战经验（PKGREL 透传矩阵 / clean-version / chunk 漂移防线） | 发布者 |
| [`92-upx-v2-fix.md`](90-incidents/92-upx-v2-fix.md) | incident | v2 UPX 压制双 SIGSEGV：四假说 + 检验序列 + v1 成功线辨析 | 维护者 |

### `99-reference/` — 参考表、上游同步与研究

| 文件 | 类型 | 一句话摘要 | 受众 |
|---|---|---|---|
| [`99-open-issues-and-upstream-sync.md`](99-reference/99-open-issues-and-upstream-sync.md) | reference | bun/opencode/loader 上游 issue 跟踪与本地 workaround 漂移控制 | 维护者 |
| [`skills-index.md`](99-reference/skills-index.md) | reference | 精简索引：提示词里快速召回正确文档与已知修法 | 新人/维护者 |
| [`arch-reference-mapping.md`](99-reference/arch-reference-mapping.md) | reference | Arch 插件打包做法中可借鉴的部分与 Termux 适配差异 | 维护者 |
| [`comparison-runtime-lines.md`](99-reference/comparison-runtime-lines.md) | reference | 三条 Termux 运行时路线对比（native 复活 / guysoft / wrapper 主线） | 维护者 |
| [`native-android-research.md`](99-reference/native-android-research.md) | reference | Bun 原生 Android 二进制可行性研究（2026-05 结论，已被后续推翻） | 维护者 |
| [`octplugin-prebranch-research.md`](99-reference/octplugin-prebranch-research.md) | reference | OCTPlugin 拆独立开发线前的单文件研究基线 | 维护者 |

### `cross-compile/` — 跨架构 / 交叉编译体系

调研快照 2026-10-05。回答「本仓要扩到非 Android Linux / 其他架构，要动的是**打包**还是**工具链**？」
——结论是**打包活**：bun `--compile --target` 走 npm 预编译 baseline 下载，
aarch64 Android 本机零交叉工具链即产出 x86_64 glibc / musl / bionic 产物。
推荐路线 = **bun baseline 打包 + CI 原生 runner 验证**（风险低，不引入 Rust/Zig/容器/模拟器），
**首目标 `linux-x64` glibc**（1–2 天，且让自研 shim 层几乎全部退休）。
`linux-riscv64` 判定**不可行**（bun `Architecture` 枚举不含 riscv64，`raw_syscall6` 编译错误）。

本族由跨架构调研工作流独立维护，**不在本文档重组范围内**；此处仅作索引登记。
实测原始输出见 `.omo/evidence/a2-v1-effect-rebuild/task-31-crossarch.txt`（证据编号 E1–E5）。

| 文件 | 类型 | 一句话摘要 | 受众 |
|---|---|---|---|
| [`README.md`](cross-compile/README.md) | plan | 总览：成熟度矩阵摘要 + 三个实测坑 + 推荐方案（首目标 `linux-x64` glibc） | 决策者 |
| [`targets.md`](cross-compile/targets.md) | reference | 逐目标成熟度矩阵（7 个目标的工具链 / 评级 / 阻塞点 / 工作量） | 决策者 |
| [`toolchains.md`](cross-compile/toolchains.md) | reference | bun `--target` 语义、可用 target 清单、交叉编译配方与三个坑的规避 | 实现者 |
| [`shim-porting.md`](cross-compile/shim-porting.md) | reference | 自研 shim 层逐项跨构阻塞判定（结论：shim 存在理由是「Android 3.18 + bionic<11」，非 aarch64） | 实现者 |
| [`ci-and-emulation.md`](cross-compile/ci-and-emulation.md) | plan | Docker / qemu / binfmt / 自托管 runner 各方案边界与代价（本机做不了交叉+模拟闭环） | 实现者 |
| [`plan.md`](cross-compile/plan.md) | plan | 分阶段实施计划（A/B/C 三方案对比 + 阶段 / 前置 / 验收 / 回退） | 执行者 |

---

## 与 `.omo/` 的关系

- **`docs/`** = 版本化的**知识与契约**（设计、操作手册、事故复盘）。进 git，可被引用为
  「事实基线」，被 commit 历史追溯。
- **`.omo/evidence/`** = **执行证据区**（取证日志、pass/fail 记录、trace、账本）。
  多为 gitignored 的会话产物，**按约定本次重组不动它**。文档常以
  「详见 `.omo/evidence/<slug>/`」反向指向证据。
- 二者配合方式：文档给**结论与理由**，evidence 给**当次运行的原始记录**。
  文档里出现 `.omo/evidence/...` 路径属正常引用，不是死链——该目录不进版本库，
  本地存在即可核对。

---

## 分类与状态约定

- 本树内容反映**当前在维护的本地 Termux 打包工作流**。
- arm32 / armv7 可移植性工作默认 **deferred / non-mainline**，除非显式提升。
- CI armv7 内容一律视为 **handoff / prebuild 上下文**，不是最终运行发布证明。

## 护栏（已验证）

- **不要**用 musl 作为 Termux 运行时打包路径；**不要**用 proot 作为官方构建路径。
- 从上游官方 Linux arm64 二进制构建运行时，再包装适配 Android/Bionic。
- staging / 打包前用 `file` + `--version` 验证运行时。
- 从 staged/deb/pacman 产物**再次**验证版本（避免陈旧版本污染）。
- `statx` seccomp 崩溃：Android seccomp 屏蔽 `statx()` → SIGSYS → SIGSEGV。
  statx shim（`libstatx-shim.so`）在 staging 期编译并由 launcher 预加载；
  用 `OPENCODE_DISABLE_STATX_SHIM=1` 关闭。

## 已知坑

- 旧的生成目录 `artifacts/staged`、`packing/dpkg/work`、`packing/pacman/src` 可能残留陈旧运行时版本。
- Termux 下 `sv status opencode-web` 需用完整服务路径（`$PREFIX/var/service/opencode-web`）。
- `opencode web` 在 runit 下若启动崩溃会重启循环并堆积 `.*-0000*.so`（见 `90-incidents/`）。

## 仓库地图

- OpenCode Termux 仓（权威）：`~/develop/opencode-termux`
- 工作区根（多仓，非真源）：`~/develop`
- 运行时包装工具仓：`~/develop/bun-termux`（或旧 `~/bun-termux-loader`，发布前确认活跃工具链）
- 运行时配置 / 插件（用户态）：`~/.config/opencode/`

---

## 迁移映射表（原名 → 新路径）

2026-10-05 重组前 `docs/` 为扁平文件。下列对照供追溯旧引用与旧 commit：

| 原路径 | 新路径 |
|---|---|
| `00-scope-and-target.md` | [`00-scope/01-scope-and-target.md`](00-scope/01-scope-and-target.md) |
| `01-env-baseline-termux.md` | [`00-scope/02-env-baseline-termux.md`](00-scope/02-env-baseline-termux.md) |
| `local-production.md` | [`00-scope/03-local-production.md`](00-scope/03-local-production.md) |
| `11-opencode-build-plan.md` | [`10-build/11-opencode-build-plan.md`](10-build/11-opencode-build-plan.md) |
| `12-bun-executable-structure.md` | [`10-build/12-bun-executable-structure.md`](10-build/12-bun-executable-structure.md) |
| `13-opencode-runtime-build.md` | [`10-build/13-opencode-runtime-build.md`](10-build/13-opencode-runtime-build.md) |
| `transplant.md` | [`10-build/14-transplant-pipeline.md`](10-build/14-transplant-pipeline.md) |
| `native-line-evolution.md` | [`10-build/15-native-line-evolution.md`](10-build/15-native-line-evolution.md) |
| `tui-common-fix.md` | [`10-build/16-tui-common-fix.md`](10-build/16-tui-common-fix.md) |
| `tui-reachability.md` | [`10-build/17-tui-reachability.md`](10-build/17-tui-reachability.md) |
| `20-packaging-deb.md` | [`20-packaging/20-packaging-deb.md`](20-packaging/20-packaging-deb.md) |
| `21-packaging-pkg-tar-xz.md` | [`20-packaging/21-packaging-pacman.md`](20-packaging/21-packaging-pacman.md) |
| `22-termux-services-opencode-web.md` | [`20-packaging/22-termux-services-opencode-web.md`](20-packaging/22-termux-services-opencode-web.md) |
| `dual-track-install.md` | [`20-packaging/23-dual-track-install.md`](20-packaging/23-dual-track-install.md) |
| `compressed-line.md` | [`20-packaging/24-compressed-line-contract.md`](20-packaging/24-compressed-line-contract.md) |
| `plugin-packaging-design.md` | [`20-packaging/25-plugin-packaging-design.md`](20-packaging/25-plugin-packaging-design.md) |
| `system-skills-hook-architecture.md` | [`20-packaging/26-system-skills-hook-architecture.md`](20-packaging/26-system-skills-hook-architecture.md) |
| `hook-design-proposal.md` | [`20-packaging/27-hook-design-proposal.md`](20-packaging/27-hook-design-proposal.md) |
| `bundle-list.txt` | [`20-packaging/bundle-list.txt`](20-packaging/bundle-list.txt) |
| `30-ci-local-build-matrix.md` | [`30-testing/30-local-build-matrix.md`](30-testing/30-local-build-matrix.md) |
| `glibc-min-deps-test-report.md` | [`30-testing/31-glibc-min-deps-test-report.md`](30-testing/31-glibc-min-deps-test-report.md) |
| `patch-coverage-audit.md` | [`30-testing/32-patch-coverage-audit.md`](30-testing/32-patch-coverage-audit.md) |
| `performance-optimization.md` | [`30-testing/33-performance-optimization.md`](30-testing/33-performance-optimization.md) |
| `measurements/native-baseline-1.3.13.json` | [`30-testing/measurements/native-baseline-1.3.13.json`](30-testing/measurements/native-baseline-1.3.13.json) |
| `execution-checklist.md` | [`40-release/40-execution-checklist.md`](40-release/40-execution-checklist.md) |
| `migration-v1-to-v2.md` | [`40-release/41-migration-v1-to-v2.md`](40-release/41-migration-v1-to-v2.md) |
| `upstream-notification-package-rename.md` | [`40-release/42-upstream-notification-package-rename.md`](40-release/42-upstream-notification-package-rename.md) |
| `termux-asset-release-flow.md` | [`40-release/43-termux-asset-release-flow.md`](40-release/43-termux-asset-release-flow.md) |
| `make-maintainer.md` | [`50-automation/50-make-maintainer.md`](50-automation/50-make-maintainer.md) |
| `ci-prebuild-armv7.md` | [`50-automation/51-ci-prebuild-armv7.md`](50-automation/51-ci-prebuild-armv7.md) |
| `armv7-native-runner-setup.md` | [`50-automation/52-armv7-native-runner-setup.md`](50-automation/52-armv7-native-runner-setup.md) |
| `plugin-management.md` | [`50-automation/53-plugin-management.md`](50-automation/53-plugin-management.md) |
| `quick-build.sh` | [`50-automation/quick-build.sh`](50-automation/quick-build.sh) |
| `handover/release-runbook.md` | [`80-handover/80-release-runbook.md`](80-handover/80-release-runbook.md) |
| `handover/machine-env.md` | [`80-handover/81-machine-env.md`](80-handover/81-machine-env.md) |
| `handover/community-state.md` | [`80-handover/82-community-state.md`](80-handover/82-community-state.md) |
| `handover/open-items.md` | [`80-handover/83-open-items.md`](80-handover/83-open-items.md) |
| `handover/recall-pack.md` | [`80-handover/84-recall-pack.md`](80-handover/84-recall-pack.md) |
| `incidents/2026-02-23-opencode-web-termux-so-avalanche.md` | [`90-incidents/90-2026-02-23-opencode-web-termux-so-avalanche.md`](90-incidents/90-2026-02-23-opencode-web-termux-so-avalanche.md) |
| `ops-lessons-rc3.md` | [`90-incidents/91-ops-lessons-rc3.md`](90-incidents/91-ops-lessons-rc3.md) |
| `upx-v2-fix.md` | [`90-incidents/92-upx-v2-fix.md`](90-incidents/92-upx-v2-fix.md) |
| `99-open-issues-and-upstream-sync.md` | [`99-reference/99-open-issues-and-upstream-sync.md`](99-reference/99-open-issues-and-upstream-sync.md) |
| `skills-index.md` | [`99-reference/skills-index.md`](99-reference/skills-index.md) |
| `arch-reference-mapping.md` | [`99-reference/arch-reference-mapping.md`](99-reference/arch-reference-mapping.md) |
| `comparison-runtime-lines.md` | [`99-reference/comparison-runtime-lines.md`](99-reference/comparison-runtime-lines.md) |
| `native-android-research.md` | [`99-reference/native-android-research.md`](99-reference/native-android-research.md) |
| `OCTPLUGIN-PREBRANCH-RESEARCH.md` | [`99-reference/octplugin-prebranch-research.md`](99-reference/octplugin-prebranch-research.md) |

所有移动均用 `git mv`，`git log --follow <新路径>` 可追到原文件历史。
仓内引用（`AGENTS.md`、各语言 `README*`、`scripts/*`、`tools/*`、`.github/workflows/*`）
已同步更新为新路径。
