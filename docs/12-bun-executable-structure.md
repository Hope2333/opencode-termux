# 12 - Bun Executable Structure & Compatibility

## Bun `--compile` 产物结构

`bun build --compile` 生成的单文件可执行格式：

```
┌─────────────────────────────────────────────────────────────────┐
│ ELF Header + Program Headers                                    │
├─────────────────────────────────────────────────────────────────┤
│ Machine Code (.text, .data, .rodata, etc.)                      │
├─────────────────────────────────────────────────────────────────┤
│ ---- Bun! ----                                                  │
│ ↑ 魔数标记（约 16 bytes），定位嵌入数据的起始位置                 │
├─────────────────────────────────────────────────────────────────┤
│ 嵌入的 JavaScript/TypeScript 源码                                │
│ （编译后的 bytecode 或源码文本）                                  │
├─────────────────────────────────────────────────────────────────┤
│ 嵌入的 Bun Runtime                                               │
│ （完整的 Bun 运行时，约 80-100MB）                                │
└─────────────────────────────────────────────────────────────────┘
```

### 关键标记

| 标记 | 位置 | 作用 |
|------|------|------|
| `---- Bun! ----` | 嵌入数据前 | Bun 运行时定位嵌入 JS 源码 |
| `BUNWRAP1` | loader 包装后 | bun-termux-loader 元数据标记 |

### 运行机制

1. 用户执行 `./my-app`
2. Bun runtime 通过 `/proc/self/exe` 读取自身
3. 扫描 `---- Bun! ----` 标记
4. 加载嵌入的 JS 源码并执行

---

## bun-termux-loader 包装结构

Termux/Bionic 环境下，需要通过 loader 包装实现 glibc 兼容：

```
┌─────────────────────────────────────────────────────────────────┐
│                    *-termux 最终产物                             │
├─────────────────────────────────────────────────────────────────┤
│ Bionic Wrapper (userspace exec)                                 │
│   - 使用 mmap() 加载 glibc 的 ld-linux-aarch64.so.1             │
│   - 不调用 execve()，保持 /proc/self/exe 指向自身                │
│   - dlopen 拦截处理 $bunfs 调用                                  │
├─────────────────────────────────────────────────────────────────┤
│ BUNWRAP1                                                        │
│ ↑ loader 添加的元数据标记，用于提取嵌入的 Bun ELF                │
├─────────────────────────────────────────────────────────────────┤
│ ---- Bun! ----                                                  │
├─────────────────────────────────────────────────────────────────┤
│ 嵌入的 JS 源码 + Bun runtime                                     │
└─────────────────────────────────────────────────────────────────┘
```

### 为什么需要 userspace exec

| 问题 | 原因 | 解决 |
|------|------|------|
| `/proc/self/exe` 指向 `ld.so` | `execve()` 会更新 `/proc/self/exe` | userspace exec 不调用 `execve()` |
| Bun 找不到嵌入数据 | 标记定位错误 | 保持 `/proc/self/exe` 指向原二进制 |
| `$bunfs` 不可用 | Termux 无此文件系统 | dlopen 拦截并重定向 |

---

## UPX 兼容性分析

### 为什么 UPX 会失败

```
$ upx --best opencode-termux
...
error: no embedded Bun runtime (missing BUNWRAP1)
```

**原因：**

1. UPX 压缩 ELF 的 code/data 段
2. 压缩后，`BUNWRAP1` 和 `---- Bun! ----` 标记的**位置和格式改变**
3. loader/Bun 无法定位嵌入数据 → 启动失败

### 兼容性矩阵

| 工具 | Bun 原始产物 | loader 包装后 | 原因 |
|------|-------------|--------------|------|
| `upx` | ❌ | ❌ | 破坏嵌入标记结构 |
| `strip` | ✅ | ✅ | 仅删除符号表，不影响嵌入数据 |
| `gzip/zstd/xz` | ✅（外部压缩） | ✅（外部压缩） | 不修改 ELF 结构，仅用于分发 |

### 推荐优化方式

| 方式 | 效果 | 运行时影响 | 适用场景 |
|------|------|-----------|---------|
| `strip` | 减少 10-30% | ✅ 无影响 | 构建时自动执行 |
| `zstd -19` | 减少 60-70% | ✅ 无影响 | 分发打包 |
| `xz -9e` | 减少 65-75% | ✅ 无影响 | 分发打包（更慢但更小） |
| UPX | 减少 50-70% | ❌ 破坏结构 | **不可用** |

---

## 构建验证命令

```bash
# 检查输入二进制（bun build --compile 产物）
file ./my-app
strings -n 8 ./my-app | grep '---- Bun! ----'

# 检查 loader 包装后产物
file ./my-app-termux
strings -n 8 ./my-app-termux | grep -E 'BUNWRAP1|---- Bun! ----'

# 检查提取的 Bun ELF 大小（应 ~90MB，而非 ~240KB）
ls -lh "$TMPDIR/bun-termux-cache/"
```

---

## 相关链接

- [bun-termux-loader](https://github.com/kaan-escober/bun-termux-loader)
- [Bun Issue #26752](https://github.com/oven-sh/bun/issues/26752) - Request for BUN_SELF_EXE env var
- [Bun Issue #8685](https://github.com/oven-sh/bun/issues/8685) - Bun on Termux documentation
