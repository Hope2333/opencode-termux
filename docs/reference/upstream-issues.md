# 上游 issue 与同步台账

> 状态：active ｜ 适用版本：全代（v1/v2）

**台账以 `gh issue list` 为准**；本表是历史结论与现行状态的汇总。现行主线是 native bionic（`build-bionic.sh` / `transplant.py`），`bun-termux-loader` 仅用于 wrapper 附录线——旧表里「用 loader 解决」的动作请按当前代际理解。

## 关键 issue 现状（上游）

| 仓库 | issue | 当前结论 | 本地动作（现行） |
|---|---|---|---|
| anomalyco/opencode | #12515 | Termux 安装可能缺平台包 | 不依赖 npm postinstall，走 staged/源码构建 |
| anomalyco/opencode | #11689 | 缺少 Android/Termux 原生支持 | 本仓自建 native bionic 线 |
| anomalyco/opencode | #10504 | 二进制兼容性问题 | native 线零 glibc；wrapper 线用 loader |
| oven-sh/bun | #26752 | `--compile` 对 `/proc/self/exe` 语义敏感 | native 线不再依赖该假设 |
| oven-sh/bun | #8685 | Bun on Termux 仍有兼容边界 | 保留回归测试与 pin |
| Hope2333/bun-termux-loader | - | userspace exec 方案 | wrapper 附录线依赖 |

## 已知技术限制

### opencode web 无内置 HTTPS

- `opencode web` 不支持 TLS/HTTPS；`Bun.serve()` 未暴露 cert/key。
- 方案：Caddy 反代（自动 Let's Encrypt）/ Cloudflare Tunnel（无需公网 IP）/ fork 源码。
- 现状：HTTP `0.0.0.0:4096` + `OPENCODE_SERVER_PASSWORD` Basic Auth。

详见 `reference/termux-services.md`。

### release 模式下冗余源码

- `runtime/opencode` 已内嵌全部源码，staged 的 `packages/` 目录为冗余（体积问题）。
- 待定：release 模式是否删除 `packages/`。

### UPX

见 `packaging/upx-notes.md`（结论已推翻，勿引用旧的「不可用」说法）。

## patch/workaround 管理

| workaround | 来源 | 适用版本 | 引入原因 |
|---|---|---|---|
| staged/源码构建替代 npm global | 本地 | 全代 | #12515 postinstall 失败 |
| bun-termux-loader 包装 | kaan-escober | wrapper 线 | glibc/bionic 兼容 |
| strip 优化 | 本地 | 全代 | 减小体积 |

评估原则：记录来源 URL、适用版本、引入原因；每次发版前评估可否移除；上游修复后清理。

## 退出条件（可删除本地 workaround）

1. 上游发布并验证 Android arm64 平台包可直接安装；
2. Bun 在 Termux 上不依赖当前方案即可稳定通过回归；
3. 本地回归矩阵（build/package/run）连续通过。

## 同步节奏

- 自动探测：`.github/workflows/probe-upstream.yml` 每日查 `/tags`（v2 线不发 Release）。
- 每次版本升级前执行一次全量复核（`scripts/ci/probe-latest-opencode.sh --check`）。

### 关键仓库

- https://github.com/anomalyco/opencode （镜像 sst/opencode；本仓构建取 sst 源）
- https://github.com/oven-sh/bun
- https://github.com/Hope2333/bun-termux-loader

## 2026-09-28 追加（RC3 实证）

| 仓库 | issue | 当前结论 | 本地动作 |
|---|---|---|---|
| Hope2333/opencode-termux | #25 | OpenTUI 0.5.12 chunk 文件名漂移破构建 | 已修：apply-platform-patch.sh 动态发现（ce1c2ca），已关闭 |
| Hope2333/opencode-termux | #23/#24/#17 | bun 1.4.2 SIGSEGV@0x40 / SIGSYS | RC3 全家族 bun 1.4.0 重建；v1 1.18.32-3 用户实证通过 |
| Hope2333/opencode-termux | #17/#24/#36/#37 | native 包缺 seccomp shim（**已修**） | 修复：family-v2-native/compressed 接 harden-native，打包 ship shim（`217f88d`/`080a6fd`）；Push261016 起全家族 hardened |

## 2026-09-29 追加（RC4 实测反馈）

| bug | 现象 | 根因 | 处置 |
|---|---|---|---|
| mirrorlist 校验和不匹配 | 全新下载仍 sha 不符 | Server 走 `releases/latest/download/`，latest 漂移期 db/pkg 来自不同轮 | **已修**：mirrorlist 先构建后 repo-add + pool 覆盖 + 自举 CDN 优先（消费仓 `41847c6`） |
| `.INSTALL` 钩子静默不跑 | post_install 报 `/usr/tmp/alpm_*/.INSTALL` 不存在 | termux-pacman 事务临时目录在 /usr/tmp（只读） | 关键逻辑迁 pacman hook；`.INSTALL` 降级 best-effort |

#17 实证：4.19 两轮干净安装零 SIGSYS ✓；#27 实证：Android 16 serve 正常 ✓。
