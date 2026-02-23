# 99 - Open Issues and Upstream Sync

## 跟踪目标
持续同步 bun / opencode / loader 上游状态，控制本地 workaround 漂移。

---

## 关键 issue 现状（需持续复核）

| 仓库 | issue | 当前结论 | 本地动作 |
|------|-------|---------|---------|
| anomalyco/opencode | #12515 | Termux 安装可能缺 `opencode-android-arm64` | 不依赖 npm global postinstall，走 staged 构建 |
| anomalyco/opencode | #11689 | 缺少 Android/Termux 原生支持 | 使用 bun-termux-loader 包装 |
| anomalyco/opencode | #10504 | 二进制兼容性问题 | loader 解决 glibc/bionic 兼容 |
| oven-sh/bun | #26752 | `--compile` 对 `/proc/self/exe` 语义敏感 | loader 包装后强制 marker 检查 |
| oven-sh/bun | #8685 | Bun on Termux 仍有兼容边界 | 保留 glibc/loader 路径与回归测试 |
| kaan-escober/bun-termux-loader | - | userspace exec 解决方案 | 核心依赖，持续同步 |

---

## 已知技术限制

### UPX 不兼容 Bun 可执行文件

**问题**：
```bash
$ upx --best opencode-termux
error: no embedded Bun runtime (missing BUNWRAP1)
```

**原因**：
- Bun `--compile` 产物使用 `---- Bun! ----` 标记定位嵌入数据
- loader 包装后添加 `BUNWRAP1` 元数据标记
- UPX 压缩会破坏这些标记的位置和结构

**解决方案**：
| 方案 | 效果 | 推荐 |
|------|------|------|
| `strip` | 减少 10-30% | ✅ 构建时自动执行 |
| `zstd -19` 分发压缩 | 减少 60-70% | ✅ 仅用于打包分发 |
| UPX | 减少 50-70% | ❌ 不可用 |

详见：[12-bun-executable-structure.md](./12-bun-executable-structure.md)

---

### opencode web 无内置 HTTPS

**问题**：
- `opencode web` 不支持 TLS/HTTPS
- `Bun.serve()` 在 opencode 中未暴露 cert/key 选项

**解决方案**：

| 方案 | 优点 | 缺点 |
|------|------|------|
| Caddy 反向代理 | 自动 Let's Encrypt | 需要域名 |
| Cloudflare Tunnel | 无需公网 IP，自动 HTTPS | 依赖第三方 |
| 修改 opencode 源码 | 无外部依赖 | 需维护 fork |

**当前状态**：
- HTTP 监听 `0.0.0.0:4096` 已实现（局域网可访问）
- 可通过 `OPENCODE_SERVER_PASSWORD` 启用 Basic Auth

详见：[22-termux-services-opencode-web.md](./22-termux-services-opencode-web.md)

---

### release 模式下冗余源码

**问题**：
- `runtime/opencode` 已内嵌全部源码
- staged 的 `packages/opencode/` 目录（~几十 MB）为冗余

**待定**：
- [ ] 是否在 release 模式下删除 `packages/` 以减小体积

---

## patch/workaround 管理

| workaround | 来源 | 适用版本 | 引入原因 |
|-----------|------|---------|---------|
| staged 构建替代 npm global | 本地 | 所有 | #12515 postinstall 失败 |
| bun-termux-loader 包装 | kaan-escober | 所有 | glibc/bionic 兼容 |
| strip 优化 | 本地 | 所有 | 减小二进制体积 |

### 评估原则
- 记录来源 URL、适用版本、引入原因
- 每次发版前评估是否可移除
- 上游修复后及时清理本地 workaround

---

## 退出条件（可删除本地 workaround）

1. 上游发布并验证 Android arm64 平台包可直接安装
2. Bun 在 Termux 上不再依赖当前 loader 方案即可稳定通过回归
3. 本地回归矩阵（build/package/run）连续通过

---

## 同步节奏

- 每周检查一次关键 issue/pr
- 每次版本升级前执行一次全量复核

### 关键仓库

- https://github.com/anomalyco/opencode
- https://github.com/oven-sh/bun
- https://github.com/kaan-escober/bun-termux-loader
- https://github.com/thdxr/bun (patch 分支)
