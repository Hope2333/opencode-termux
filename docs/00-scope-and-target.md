# 00 - Scope and Target

## 目标
在 Android/Termux 环境下，构建并产出 **bun** 与 **opencode** 两套可复用构建流程，最终得到：

- `bun` 的 `deb` 包与 `pkg.tar.xz` 包
- `opencode` 的 `deb` 包与 `pkg.tar.xz` 包

并形成可追踪、可复现、可验收的文档与脚本集合。

---

## 文档索引

| 编号 | 文档 | 内容 |
|------|------|------|
| 00 | [Scope and Target](./00-scope-and-target.md) | 项目范围与目标（本文档） |
| 01 | [Environment Baseline](./01-env-baseline-termux.md) | Termux 环境基线 |
| 10 | [Bun Build Plan](./10-bun-build-plan.md) | Bun 构建计划与 loader 集成 |
| 11 | [OpenCode Build Plan](./11-opencode-build-plan.md) | OpenCode 构建计划与运行时模式 |
| 12 | [Bun Executable Structure](./12-bun-executable-structure.md) | Bun 可执行文件结构与兼容性 |
| 20 | [Packaging deb](./20-packaging-deb.md) | Debian 打包流程 |
| 21 | [Packaging pkg.tar.xz](./21-packaging-pkg-tar-xz.md) | Pacman 打包流程 |
| 22 | [Termux Services](./22-termux-services-opencode-web.md) | opencode-web sv 服务配置 |
| 30 | [CI Local Build Matrix](./30-ci-local-build-matrix.md) | 本地构建矩阵与验证 |
| 99 | [Open Issues](./99-open-issues-and-upstream-sync.md) | 开放问题与上游同步 |
| - | [howfixandroid.md](./howfixandroid.md) | 原始问题记录与上游 issue 摘要 |

---

## 当前已知前提

- 运行环境：Termux（Android arm64）
- 包管理层：已通过脚本转移到 `pacman`
- 兼容层：可使用 `grun` 运行 glibc 侧工具
- 关键问题域：Bun 在 Termux(Bionic) 与 glibc 运行时行为差异，尤其 `/proc/self/exe` 语义与 bundled 可执行行为

---

## 核心技术方案

### Bun on Termux

```
bun build --compile 产物
        │
        ▼
┌─────────────────────────────────────┐
│ ELF + 嵌入 JS + Bun Runtime         │
│ 标记: ---- Bun! ----                │
└─────────────────────────────────────┘
        │
        ▼ bun-termux-loader 包装
┌─────────────────────────────────────┐
│ Bionic Wrapper (userspace exec)     │
│ 标记: BUNWRAP1 + ---- Bun! ----     │
└─────────────────────────────────────┘
        │
        ▼
   可在 Termux 直接运行
```

### OpenCode 运行模式

| 模式 | 依赖外部 bun | 体积 |
|------|-------------|------|
| release-loader | ❌ | 小（单文件 runtime） |
| release-raw | ❌ | 小（单文件 runtime） |
| source-only | ✅ | 大（含完整源码目录） |

---

## 范围内（In Scope）

1. 明确 bun 与 opencode 的源码/发布物获取路径
2. 明确 bun-termux-loader 的接入方式（patch / wrapper / 混合）
3. 形成两种打包格式（deb 与 pkg.tar.xz）的统一产物布局
4. 提供最小可执行验收矩阵（安装、运行、版本检查、基本命令）
5. 形成上游问题与补丁同步策略
6. opencode-web 服务默认启用（sv 管理，监听 0.0.0.0:4096）
7. 打包 deb 时自动同步安装到本机

---

## 暂不承诺（Out of Scope, 第一阶段）

- 上游长期维护策略（如完整 CI 基础设施托管）
- 非 arm64 架构适配
- GUI 端集成（仅覆盖 CLI 能力）
- opencode-web 内置 HTTPS（可使用 Caddy/Cloudflare Tunnel）

---

## 已知技术限制

| 限制 | 原因 | 替代方案 |
|------|------|---------|
| UPX 不可用 | 破坏 Bun 嵌入标记 | 使用 strip + zstd 分发压缩 |
| opencode 无内置 HTTPS | Bun.serve 未暴露 TLS 选项 | 反向代理 / Tunnel |
| `/proc/self/exe` 语义 | Bionic vs glibc 差异 | userspace exec (loader) |

详见：[99-open-issues-and-upstream-sync.md](./99-open-issues-and-upstream-sync.md)

---

## 交付定义（Definition of Done）

- 文档齐备并可指导冷启动构建
- 两个项目均可得到 `deb` + `pkg.tar.xz` 产物
- 安装后关键命令可运行，且有结果记录
- 已记录已知问题、临时 workaround、上游链接

---

## 目录约定

```text
project/
├─ docs/                          # 文档
├─ scripts/
│  ├─ build/                      # 构建脚本
│  ├─ package/                    # 打包脚本
│  └─ common.sh                   # 公共函数
├─ packaging/
│  ├─ deb/                        # Debian 打包暂存
│  └─ pacman/                     # Pacman 打包暂存
├─ sources/
│  ├─ bun/repo                    # Bun 源码
│  └─ opencode/repo               # OpenCode 源码
└─ artifacts/
   ├─ bun/
   │  ├─ staged/                  # staged 产物
   │  ├─ deb/                     # deb 包
   │  └─ pacman/                  # pkg.tar.xz 包
   └─ opencode/
       ├─ staged/
       ├─ deb/
       └─ pacman/
```

---

## 相关资源

### 上游仓库
- https://github.com/oven-sh/bun
- https://github.com/anomalyco/opencode
- https://github.com/kaan-escober/bun-termux-loader
- https://github.com/thdxr/bun (patch 分支)

### 关键 Issue
- [opencode #12515](https://github.com/anomalyco/opencode/issues/12515) - Termux 安装失败
- [bun #26752](https://github.com/oven-sh/bun/issues/26752) - BUN_SELF_EXE 请求
- [bun #8685](https://github.com/oven-sh/bun/issues/8685) - Bun on Termux
