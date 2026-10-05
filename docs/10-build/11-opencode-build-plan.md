# 11 - OpenCode Build Plan

## 目标
在 Termux/Android arm64 上可安装并运行 `opencode`，并产出：
- `deb`
- `pkg.tar.xz`

## 当前 blocker
- `npm i -g opencode-ai` 在 postinstall 阶段可能报错：
  - `Cannot find module 'opencode-android-arm64/package.json'`
- 因此不以“npm 全局安装直接成功”作为主路径。

## 执行优先级
1. **源码 staged 构建（首选）**
   - 拉源码
   - 复制到 staged 前缀
   - 自建启动脚本
2. **发布版重打包（备选）**
3. **patch postinstall（备选）**

## 与 Bun 关系
- `opencode` 构建与运行依赖 Bun 路径已先稳定。
- Bun 未通过门禁前，不进入 opencode 打包阶段。

---

## RUNTIME_MODE 与依赖关系

构建脚本 (`scripts/build/build_opencode.sh`) 根据输入文件自动选择模式：

| 模式 | 触发条件 | runtime 文件 | 是否依赖外部 bun |
|------|----------|-------------|-----------------|
| `release-loader` | 有 `opencode-termux` runtime | `runtime/opencode` | ❌ 不依赖 |
| `release-raw` | 有 `opencode` runtime | `runtime/opencode` | ❌ 不依赖 |
| `source-only` | 无 runtime 输入 | 无 | ✅ 依赖 |

### 运行逻辑

```bash
# launcher (bin/opencode) 执行流程：
if [[ -x "$OPENCODE_RUNTIME" ]]; then
  "$OPENCODE_RUNTIME" "$@"        # 使用 runtime（内嵌 Bun + 源码）
else
  "$OPENCODE_CLI" "$@"            # 使用 CLI（需要外部 bun）
fi
```

### staged 目录结构

```
prefix/
├── bin/opencode                    # launcher 脚本
├── lib/opencode/
│   ├── runtime/opencode            # 单文件可执行（release 模式）
│   └── packages/opencode/...       # TypeScript 源码（source-only 必需）
├── share/termux-services/opencode-web/run  # sv 服务
└── var/service/opencode-web       # 默认启用链接
```

### 体积优化

**release 模式下**，`runtime/opencode` 已内嵌全部源码，`packages/` 目录为冗余：

| 模式 | packages/ 目录 | 建议 |
|------|---------------|------|
| `release-*` | ~几十 MB（冗余） | 可删除以减小体积 |
| `source-only` | 必需 | 保留 |

---

## 二进制优化

### strip（推荐）

```bash
# 构建脚本已自动执行
strip "$PREFIX_DIR/lib/opencode/runtime/opencode"
```

效果：减少 10-30%，无运行时影响

### UPX（不可用）

```bash
$ upx --best runtime/opencode
error: no embedded Bun runtime (missing BUNWRAP1)
```

**原因**：Bun 可执行文件依赖嵌入标记 (`BUNWRAP1`, `---- Bun! ----`)，UPX 压缩会破坏结构。

详见：[12-bun-executable-structure.md](./12-bun-executable-structure.md)

---

## 验收
- `opencode --version` 或 `opencode --help` 至少一个成功
- 验证日志中不出现：
  - `Cannot find module 'opencode-android-arm64/package.json'`
- release 模式：`strings runtime/opencode | grep '---- Bun! ----'` 应有输出

## 待锁定
- [ ] opencode 版本/tag
- [ ] 与 Bun 的兼容矩阵
- [ ] 是否必须 patch postinstall
- [ ] release 模式下是否删除冗余 packages/ 目录
