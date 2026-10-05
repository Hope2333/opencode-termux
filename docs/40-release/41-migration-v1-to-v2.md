# v1 → v2 Migration Guide

> opencode 2.0.0 是全线替换版本（GA mainline）。v1.18.x 留档可降级。

## 版本对比

| | v1（1.18.31 封版） | v2（2.0.0 GA） |
|---|---|---|
| 上游 | opencode 1.18.x | opencode 2.0.x（Effect HttpApi 后端重写） |
| 构建线 | A 线（transplant 复活 glibc→bionic） | B 线（android bun 源码编译，零 glibc） |
| 插件 | V1 插件格式 | **V2 插件不兼容 V1**（需移植 entrypoints/hooks/tools/events） |
| 服务端 API | V1 | 重写（@opencode/client） |
| Config | V1 格式仍可读（内存翻译，不重写源文件） | autoshare→share policy |
| 包名 | `opencode`（native）/ `opencode-wrapper`（glibc） | `opencode`（native B 线）/ `opencode-wrapper`（glibc 包装） |
| TUI | ✅ 正常 | ✅ 正常（B 线构建） |
| serve | ✅ | ✅ |
| run | ✅ | ✅ |

## 升级路径（v1 → v2）

### 推荐方式（包管理器）

```bash
# Termux apt
pkg update && pkg upgrade opencode

# Termux pacman
pacman -Syu opencode
```

安装 v2 会自动替换 v1（同名包 `opencode`）。

### 手动升级

```bash
# 下载 v2 native 包
curl -LO https://github.com/Hope2333/opencode-termux/releases/download/Push260921/opencode_2.0.0_aarch64.deb

# 安装（会自动替换 v1）
dpkg -i opencode_2.0.0_aarch64.deb
```

### 回退到 v1

```bash
# 下载 v1 native 包
curl -LO https://github.com/Hope2333/opencode-termux/releases/download/Push260912/opencode_1.18.31_aarch64.deb

# 强制安装（覆盖 v2）
dpkg -i --force-all opencode_1.18.31_aarch64.deb
```

## 关键变化

### 插件不兼容

V2 插件与 V1 插件**不兼容**。如果你有自定义插件：

1. 插件入口点（entrypoints/hooks/tools/events）需移植到 V2 格式
2. 配置从 `opencode.json` 移到 `opencode.jsonc`
3. 使用 `opencode plugin add/list/check/update/remove` 管理插件

详见上游文档：https://opencode.ai/v2/docs/migrate-v1

### Config 翻译

V1 的 `opencode.json` 配置在 V2 中仍可读取，但会被内存翻译为 V2 格式。**不会修改源文件**。autoshare 功能已替换为 share policy。

### 包名不变

v2 继承 v1 的包名 `opencode`，无需改名。v1.18.31 是 v1 最终版（封版）。

## 构建线说明

### B 线（源码编译，v2 主线）

- 使用 `scripts/build-bionic.sh` 从 GitHub 源码编译
- 产物：零 glibc 的 bionic ELF（~180MB）
- 需要：android bun 1.4.2 + openat2 shim + opentui bionic .so

### A 线（transplant 复活，备用通道）

- 使用 `tools/transplant/transplant.py` 复活 glibc 二进制
- 产物：relocated bionic ELF（~210MB）
- 已知限制：TUI 不可用（bun 跨编译 bug，getaddrinfo SEGV）
- **用途**：备用通道，非特殊情况永不启用

### Wrapper 线（glibc 包装）

- 使用 bun-termux-loader 包装 glibc 版本
- 产物：~200MB，需要 glibc loader
- 用途：回退/兼容

## 互斥关系

```
opencode (v2 native B线) ←→ opencode-wrapper (glibc)
         ↕                        ↕
    不可并存                  不可并存
```

- `opencode` 与 `opencode-wrapper` 互斥（同名冲突）
- v1 封版后不再更新（v1.18.31 = 最终版）
- 如果后续 v1 需维护，包名改为 `opencode1*`

## 技术细节

详见：
- `../10-build/14-transplant-pipeline.md` — A 线移植管线
- `../20-packaging/23-dual-track-install.md` — 双轨安装说明
- `../10-build/13-opencode-runtime-build.md` — 运行时构建路径
- `../20-packaging/20-packaging-deb.md` / `../20-packaging/21-packaging-pacman.md` — 打包布局
