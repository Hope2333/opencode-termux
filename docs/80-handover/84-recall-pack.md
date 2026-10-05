# 回忆拼图包 — 交接给 v1 压制亲历会话

> **收件人**: 更老的 Agent（v1 压制时期的亲历会话，掌握外包压制配方记忆）  
> **发件人**: 当前会话（2026-09-30），只掌握 ELF-diff 辅助证据线  
> **目的**: 唤醒记忆，集合散落拼图（v1 压制真身/失败件/实验矩阵/当时的命令与决策），与现在的 v2 对比，找到 UPX 复活方案  
> **用法**: 仅凭本包 + 自身记忆即可输出配方级答案，无需回读仓库

---

## 1. 现状快照：v2 已试什么

### 实验矩阵结果（2026-09-29/30）

| 基底 | 输入 | UPX 版本 | flags | 结果 | 崩溃签名 |
|------|------|----------|-------|------|----------|
| v2.0.12 **gnu** | B 线 `artifacts/build/2.0.12/opencode-native-revived` (282MB) | 5.2.1 | `-4` | **SIGSEGV** | `Segmentation fault at address 0x40` bun init |
| v2.0.12 **musl** | 同上（PTY_VARIANT=musl 编译） | 5.2.1 | `-4` | **SIGSEGV** | 同上 |
| **未压制对照** gnu | 同输入 | N/A | N/A | **PASS** | `--version` + PTY smoke 全过 |
| **未压制对照** musl | 同输入 | N/A | N/A | **PASS** | 同上 |

### 崩溃机制已定位的部分
- 崩溃点 = **UPX 解包完成后 bun runtime 初始化阶段**（不是 UPX stub 本身）
- 双基底（gnu/musl）同崩 = 不是 libc/loader 选择问题
- `0x40` = 空指针 + 结构体字段偏移（ptr=NULL, field_offset=0x40）
- 对照全活 = 输入 bin 本身无问题，**变量 = UPX 压制过程**

### 已排除的方向
- ❌ UPX 对 bionic 不可用（v1 时代 stock `--best` 成功 report 在案）
- ❌ musl/gnu 差异（双崩）
- ❌ `-4` 强度（更保守也崩，非强度问题）
- ⚠️ 版本回归未排除（v1 report=5.2.0，现=5.2.1）

### evidence 路径
- `.omo/evidence/opencode-compressed-upx-report.txt`（v1 成功 report）
- `.omo/evidence/rc3-release/ra-forensics.txt`（v1 packed vs rb1 对照 PH 表）
- `docs/90-incidents/92-upx-v2-fix.md`（四假说技术文档，检验序列已排好）
- `.omo/plans/v2-upx-revival.md`（三路线计划 R-A/R-B1/R-B2）

---

## 2. 拼图清单：在手实物

| 实物 | 路径 | 说明 |
|------|------|------|
| **v1 57M packed 真身** | `packing/dpkg-compressed/opencode1-compressed_1.18.32` | 外包结构（1794B launcher + 57MB packed runtime），**在架能跑** |
| **v1 1794B launcher** | 同上包内 `bin/opencode1` 层级 | 负责设环境 + exec runtime |
| **rb1 失败件** | `.omo/evidence/rc3-release/ra-forensics.txt` 第二段 | v2 gnu bin + upx -4，SIGSEGV |
| **v1 成功件（结构对照）** | 同上 txt 第一段 | v1 packed (WORKS)，phnum=64 UPX stub 态 |
| **双基底 bin** | `artifacts/build/2.0.12/opencode-native-revived` (gnu) / musl 变体（PTY_VARIANT 编译） | 当前输入 |
| **upx 5.2.1** | `/data/data/com.termux/files/usr/bin/upx` | 当前版本（v1 report 时代 5.2.0） |
| **v1 report（命令行原文）** | `.omo/evidence/opencode-compressed-upx-report.txt` | `upx --best -o <out> <in>`，109min，28.86% |
| **v1 1.18.21 目录** | `artifacts/transplant/1.18.21/`（若已 clean 则从 release 下载 `opencode-1.18.21-aarch64-android-native-tui`） | A 线 bin，179MB |

---

## 3. 精确提问（请逐条回答）

### 核心 5 问
1. **压制执行的机器与系统**？
   - Termux 本机？实验机（10.254.129.10）？还是其他？
   - Android 版本？kernel？

2. **完整命令行含全部 flags**？
   - 只有 `upx --best` 还是有其他参数？
   - 有没有 `--force` / `--no-color` / `--nrv` / 自定义 compression level？

3. **有无 ELF 预处理/后处理**？
   - 压制**前**是否做了段剥离（strip）/瘦身？
   - 有没有 `patchelf` 改 DT_NEEDED / DT_RPATH？
   - 有没有手动改 program headers（PH 表）？

4. **是否自编 UPX 或改 stub**？
   - stock 官方二进制？
   - 还是自己从源码编译的（有 patch）？
   - stub 是否改过（UPX 的解包 stub）？

5. **compressed-branch 的实际载体**？
   - shell 脚本？makefile 目标？
   - 还是只是记忆里的命令序列（没有固化成脚本）？

### 补充问（若有记忆）
6. 当时压制 1.18.21 与 1.18.32 的**流程完全一样**吗？
7. 外包结构的 launcher 是**编译的 C 二进制**还是 **bash 脚本**？
8. 压制过程中遇到过什么**坑**（失败重试、参数调整）？
9. 当时有没有对 A 线 bin 做**特别的手术**（比如先 `seccomp-harden` 再压）？

---

## 4. 取回路径：你自己的记忆检索法

### 记忆文件
```bash
# CodeBuddy 记忆（若用 CodeBuddy）
ls ~/.codebuddy/projects/<proj>/memory/ 2>/dev/null
grep -rli 'upx\|compress\|压制' ~/.codebuddy/ 2>/dev/null

# OpenCode 记忆
ls ~/.opencode/memory/  # governance-log.jsonl / skills/
grep -i 'upx\|compress' ~/.opencode/memory/governance-log.jsonl 2>/dev/null

# 仓内 notepad（v1 压制时代）
cat .omo/notepads/opencode-compressed-plan/learnings.md
```

### Session 检索
```bash
# cb-context-recall 技能（若装）
# 直接问：v1 压制配方/upx --best/1794B launcher

# acp_search（当前会话）
# query: "v1 upx compress 1794B launcher 57M"

# transcripts glob
find ~/.local/share/opencode/ -name '*.jsonl' -mtime -30 2>/dev/null | head -5
grep -l 'upx.*best\|1794\|57M.*packed' ~/.local/share/opencode/*.jsonl 2>/dev/null
```

### 会话日志
```bash
# 最近 30 天提到 upx 的会话
grep -rli 'upx --best\|opencode-native-revived-upx\|1794B' \
  ~/.local/share/opencode/log/ 2>/dev/null | head -10
```

---

## 5. 对比基准：v1 真身 vs rb1 结构对照

**全文已附**：`.omo/evidence/rc3-release/ra-forensics.txt`（152 行）

### 关键差异摘要

#### v1 packed (WORKS) - 第一段
```
size: 57373256 | ELF type: 3 | entry: 0x40 | phnum: 64
  PH type=1179403647 flags=0 off=0x10102 vaddr=0x100b70003 filesz=64 ...
  PH type=4194308 flags=25769803777 off=0x0 vaddr=0x0 filesz=0 memsz=4096 ...
  (后 60 条 PH 字段为 UPX 加密态特征 - type/flags/off 全是乱值)
```
**特征**：
- `phnum=64` = UPX stub 重建前的存根态（正常 ELF 只有 5-10 个 PH）
- PH 表字段**全是乱值** = UPX 加密后的 program headers，运行时由 stub 解密重建
- `entry: 0x40` = UPX stub 入口（非原始 bun 入口）

#### rb1 失败件 - 第二段
```
(需读 ra-forensics.txt 第二段对比)
```

**判读要点**：
- 对比两者的 **PT_LOAD 段数量与 flags**
- 找 UPX stub 的 `p_info` / `l_info` 标记段（v1 有、rb1 可能缺失）
- 看 `.bun` embed store 段在 UPX 后的 layout（v1 无 embed、v2 有大 embed）

**假设指向**（详见 `docs/90-incidents/92-upx-v2-fix.md`）：
- v1 A 线 bin = transplant 手术产物，PH 已被人改过
- v2 B 线 bin = bun compile 直出，未被 transplant 摸过
- 差异可能在 embed store 段的处理方式

---

## 附：R-A 主责 vs 旧代理辅助

| 角色 | 职责 | 产出 |
|------|------|------|
| **R-A（老代理）** | 主责 = 回忆拼图 | 本包 ③节 5 个精确提问的答案 → 配方级结论 |
| **旧代理（当前会话）** | ELF-diff 辅助证据线 | `ra-forensics.txt` + `docs/90-incidents/92-upx-v2-fix.md` 四假说 |

**汇合点**：R-A 的答案 + 四假说检验序列 → 收敛到 1-2 个可执行配方 → `v2-upx-revival` T2 实弹验证。

---

**预期产出时间**：R-A 收到本包后 **20-30 分钟** 出全包答案。
