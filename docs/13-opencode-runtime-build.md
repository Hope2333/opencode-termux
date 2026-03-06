# 13 - OpenCode Runtime 构建流程

## 问题背景

### 初始问题

在Termux环境下运行 `bun build --compile` 时遇到权限错误：

```
error: Cannot read directory /data/: AccessDenied
error: Cannot read directory /data/data/: AccessDenied
```

### 根因分析

1. **Android权限限制**：bun在编译时扫描文件系统，从根目录开始遍历
2. **SELinux/AppArmor**：`/data/data/` 目录对应用进程不可读（除自己的数据目录外）
3. **grun环境**：通过glibc-runner运行时，`/proc/self/exe`指向`ld.so`而非bun本身

### strace追踪结果

```bash
openat(AT_FDCWD, /, O_RDONLY|O_CLOEXEC|O_DIRECTORY) = -1 EACCES (Permission denied)
openat(AT_FDCWD, /data/data/, O_RDONLY|O_CLOEXEC|O_DIRECTORY) = -1 EACCES (Permission denied)
```

---

## 解决方案

### 方案对比

| 方案 | 结果 | 原因 |
|------|------|------|
| grun直接运行 | ❌ AccessDenied | bun扫描/data目录被拒绝 |
| proot隔离环境 | ❌ 产物异常 | /proc/self/exe指向错误 |
| **下载官方预编译包** | ✅ 成功 | 绕过编译，直接使用成品 |

### 最终方案：使用官方预编译包

1. 从npm下载官方预编译的 `opencode-linux-arm64` 包（glibc版本）
2. 使用 `bun-termux-loader` 包装成Termux兼容版本
3. 生成的binary具有正确的属性

---

## 完整构建流程

### Step 1: 下载官方OpenCode二进制

```bash
# 创建工作目录
mkdir -p ~/work && cd ~/work

# 下载opencode-linux-arm64 (glibc版本)
npm pack opencode-linux-arm64@1.2.10

# 解压
tar -xzf opencode-linux-arm64-1.2.10.tgz

# 验证二进制属性
file package/bin/opencode
# 输出: ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), 
#       dynamically linked, interpreter /lib/ld-linux-aarch64.so.1, 
#       for GNU/Linux 3.7.0
```

### Step 2: 使用bun-termux-loader包装

```bash
# 进入bun-termux-loader目录
cd ~/bun-termux-loader

# 执行包装
python3 build.py ~/work/package/bin/opencode --wrapper ./wrapper

# 输出示例:
# [+] Processing: opencode -> opencode-termux
# [+] Found 3 native lib reference(s): libopentui-erby6bxg.so, ...
# [+] Success! Output size: 153.9 MB
# [+]   Embedded 3 native lib(s) + shim

# 验证产物
file ~/work/package/bin/opencode-termux
# 输出: ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV), 
#       dynamically linked, interpreter /system/bin/linker64, 
#       for Android 24, built by NDK r29
```

### Step 3: 测试运行

```bash
# 测试版本
~/work/package/bin/opencode-termux --version
# 输出: 1.2.10

# 测试帮助
~/work/package/bin/opencode-termux --help | head -20
```

### Step 4: 放入构建系统

```bash
# 创建runtime目录
mkdir -p ~/termux.opencode.all/artifacts/opencode/runtime

# 复制包装后的二进制
cp ~/work/package/bin/opencode-termux ~/termux.opencode.all/artifacts/opencode/runtime/opencode-termux

# 执行staged构建
cd ~/termux.opencode.all
bash scripts/build/build_opencode.sh

# 验证结果
file artifacts/opencode/staged/prefix/lib/opencode/runtime/opencode
# 输出: ... interpreter /system/bin/linker64, for Android 24, built by NDK r29

artifacts/opencode/staged/prefix/lib/opencode/runtime/opencode --version
# 输出: 1.2.10
```

### Step 5: 打包

```bash
# 打包DEB
cd ~/termux.opencode.all
bash scripts/package/package_deb.sh opencode

# 打包Pacman
bash scripts/package/package_pacman.sh opencode

# 查看产物
ls -lh artifacts/opencode/deb/
ls -lh artifacts/opencode/pacman/
```

---

## bun-termux-loader 原理

### 二进制结构

```
┌─────────────────────────────────────────────────────────────────┐
│                    opencode-termux 最终产物                      │
├─────────────────────────────────────────────────────────────────┤
│ Bionic Wrapper (userspace exec)                                 │
│   - 使用 mmap() 加载 glibc 的 ld-linux-aarch64.so.1             │
│   - 不调用 execve()，保持 /proc/self/exe 指向自身                │
│   - dlopen 拦截处理  调用                                  │
├─────────────────────────────────────────────────────────────────┤
│ BUNWRAP1                                                        │
│ ↑ loader 添加的元数据标记，用于提取嵌入的 Bun ELF                │
├─────────────────────────────────────────────────────────────────┤
│ ---- Bun! ----                                                  │
├─────────────────────────────────────────────────────────────────┤
│ 嵌入的 JS 源码 + Bun runtime + native libs                       │
└─────────────────────────────────────────────────────────────────┘
```

### 为什么需要userspace exec

| 问题 | 原因 | 解决 |
|------|------|------|
| `/proc/self/exe` 指向 `ld.so` | `execve()` 会更新 `/proc/self/exe` | userspace exec 不调用 `execve()` |
| Bun 找不到嵌入数据 | 标记定位错误 | 保持 `/proc/self/exe` 指向原二进制 |
| `` 不可用 | Termux 无此文件系统 | dlopen 拦截并重定向 |

---

## 关键文件路径

| 文件 | 路径 | 说明 |
|------|------|------|
| 官方二进制 | `~/work/package/bin/opencode` | npm下载的glibc版本 |
| 包装后二进制 | `~/work/package/bin/opencode-termux` | bun-termux-loader产物 |
| runtime输入 | `artifacts/opencode/runtime/opencode-termux` | 构建系统输入 |
| staged产物 | `artifacts/opencode/staged/prefix/lib/opencode/runtime/opencode` | 构建中间产物 |
| DEB包 | `artifacts/opencode/deb/opencode_*.deb` | 最终DEB包 |
| Pacman包 | `artifacts/opencode/pacman/opencode-*.pkg.tar.xz` | 最终Pacman包 |

---

## 验证命令清单

```bash
# 1. 检查二进制属性
file ~/work/package/bin/opencode-termux
# 期望: interpreter /system/bin/linker64, for Android 24, built by NDK r29

# 2. 检查版本
~/work/package/bin/opencode-termux --version
# 期望: 1.2.10

# 3. 检查Bun标记
tail -c 300 ~/work/package/bin/opencode-termux | xxd | grep 'Bun!'
# 期望: 看到 ---- Bun! ----

# 4. 检查BUNWRAP1标记
head -c 1000 ~/work/package/bin/opencode-termux | xxd | grep 'BUNWRAP1'
# 期望: 看到 BUNWRAP1

# 5. 检查提取的runtime大小
ls -lh $TMPDIR/bun-termux-cache/bun-*
# 期望: ~90-100MB (不是~240KB)
```

---

## 常见问题排查

### Q: 运行时提示 "loader cannot load itself"

**原因**：提取的Bun ELF不正确（可能是ld.so而非完整runtime）

**排查**：
```bash
ls -lh $TMPDIR/bun-termux-cache/bun-*
file $TMPDIR/bun-termux-cache/bun-*
```

如果文件只有~240KB，说明元数据解析错误，输入的二进制不是正确的`bun build --compile`产物。

### Q: 运行时崩溃 (Segmentation fault)

**原因**：可能是native lib嵌入问题或glibc兼容性问题

**排查**：
```bash
# 检查native libs是否正确嵌入
ls -lh $TMPDIR/bun-termux-cache/bunfs-libs/
```

### Q: 版本号显示为 0.0.0

**原因**：打包脚本未正确读取版本号

**修复**：检查 `scripts/package/package_deb.sh` 中的版本读取逻辑

---

## 相关文档

- [11-opencode-build-plan.md](./11-opencode-build-plan.md) - 构建计划
- [12-bun-executable-structure.md](./12-bun-executable-structure.md) - Bun二进制结构
- [99-open-issues-and-upstream-sync.md](./99-open-issues-and-upstream-sync.md) - 上游同步

## 参考

- [bun-termux-loader](https://github.com/kaan-escober/bun-termux-loader)
- [Bun Issue #26752](https://github.com/oven-sh/bun/issues/26752)
- [Bun Issue #8685](https://github.com/oven-sh/bun/issues/8685)

---

## 已知问题与解决方案

### 插件加载失败

#### 症状

```
error: Cannot find module '/data/data/com.termux/files/home/.cache/opencode/node_modules/oh-my-opencode' from '/$bunfs/root/src/index.js'
```

或

```
error: Cannot find module '/data/data/com.termux/files/home/.cache/opencode/node_modules/opencode-anthropic-auth' from '/$bunfs/root/src/index.js'
```

#### 原因

1. **用户插件**（如 `oh-my-opencode`）依赖原生模块（如 `@ast-grep/napi`）
2. 原生模块只有 glibc 版本（`linux-arm64-gnu`），没有 Bionic 版本
3. Termux 使用 Bionic，无法加载 glibc 原生模块

#### 解决方案

**方案1：移除用户插件**

编辑 `~/.config/opencode/opencode.json`，移除 `plugin` 字段中的 `oh-my-opencode`：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    // ... 保留其他配置
  }
  // 移除 "plugin": ["oh-my-opencode"]
}
```

**方案2：使用环境变量禁用默认插件**

```bash
OPENCODE_DISABLE_DEFAULT_PLUGINS=1 opencode web --port 7600 --hostname 127.0.0.1
```

> 注意：launcher 脚本已默认设置 `OPENCODE_DISABLE_DEFAULT_PLUGINS=1`

#### 插件兼容性矩阵

| 插件 | Termux 兼容 | 原因 |
|------|------------|------|
| `opencode-anthropic-auth` | ❌ | 安装依赖网络，Termux 可能失败 |
| `oh-my-opencode` | ❌ | 依赖 `@ast-grep/napi`（glibc only） |
| 纯 JS 插件 | ✅ | 无原生依赖 |

### getifaddrs 错误

#### 症状

```
A system error occurred: getifaddrs returned an error
```

#### 解决方案

使用 `127.0.0.1` 代替 `0.0.0.0`：

```bash
opencode web --port 7600 --hostname 127.0.0.1
```

#### 原因

Termux/Android 的网络接口枚举与标准 Linux 有差异，`getifaddrs()` 在某些情况下返回错误。

---

## 启动命令总结

### TUI 模式

```bash
opencode
```

### Web 模式

```bash
opencode web --port 7600 --hostname 127.0.0.1
```

### 环境变量

| 变量 | 默认值 | 作用 |
|------|--------|------|
| `OPENCODE_DISABLE_DEFAULT_PLUGINS` | 1 | 禁用内置插件安装 |
| `OPENCODE_SERVER_PASSWORD` | - | Web 服务器密码 |


---

## 插件系统使用指南

### local-plugins 方式（推荐用于 Termux）

OpenCode 支持通过 `file://` URL 加载本地插件，这完全绕过了 npm 下载：

```json
// ~/.config/opencode/opencode.json
{
  "plugin": [
"file:///data/data/com.termux/files/home/.config/opencode/local-plugins/oh-my-opencode/index.js"
  ]
}
```

**优点**：
- 不需要网络下载
- 不触发 BunProc.install()
- 预构建，立即可用

### local-plugin 目录结构

```
~/.config/opencode/local-plugins/
└── oh-my-opencode/
    └── package/
        ├── dist/
        │   └── index.js      # 插件入口
        └── package.json
```

### 更新 local-plugin

```bash
cd ~/.config/opencode/local-plugins/oh-my-opencode
git pull
bun run build
```

### npm 包方式（Termux 不可用）

```json
// ❌ 不要在 Termux 上使用这种方式
{
  "plugin": ["oh-my-opencode"]  // 会触发 BunProc.install()
}
```

**原因**：
- `BunProc.install()` 需要网络访问
- 安装原生模块（如 @ast-grep/napi）可能失败
- Termux 的网络权限限制

---

## 环境变量参考

| 变量 | 默认值 | 作用 |
|------|--------|------|
| `OPENCODE_DISABLE_DEFAULT_PLUGINS` | 1 | 禁用内置插件（不影响用户插件） |
| `OPENCODE_SERVER_PASSWORD` | - | Web 服务器密码 |
| `OPENCODE_CONFIG_CONTENT` | - | 内联配置内容 |



---

## 最终验证 (2026-02-23)

### 成功指标

```bash
# 检查agents数量
curl -s -u "opencode:test" http://127.0.0.1:7600/config | python3 -c "
import sys,json
d=json.load(sys.stdin)
print("Agents:", len(d.get("agent",{})))
print("MCPs:", list(d.get("mcp",{}).keys()))
print("Tools:", list(d.get("tools",{}).keys())[:10])
"

# 预期输出:
# Agents: 10+
# MCPs: ["websearch", "context7", "grep_app"]
# Tools: ["grep_app_*", "LspHover", "LspCodeActions", ...]
```

### 已验证工作

- [x] OpenCode v1.2.10 Termux runtime
- [x] OMO插件加载
- [x] Agents注册 (Sisyphus, Hephaestus, Prometheus等)
- [x] MCPs连接 (websearch, context7, grep_app)
- [x] Tools注册
- [x] Commands注册
