# v2 UPX 压制修复方案 — 四假说与检验序列

> **状态**: 2026-09-30 提出，待实验裁决  
> **背景**: v2 (2.0.x) B 线产物 stock UPX 压制双 SIGSEGV（gnu/musl 均崩），v1 (1.18.x) 时代 stock UPX 与外包两条线均成功  
> **关联**: `docs/handover/recall-pack.md`（老代理回忆包）· `.omo/plans/v2-upx-revival.md`（三路线计划）· `.omo/evidence/opencode-compressed-upx-report.txt`（v1 成功实证）

---

## 0. 证据基线

| 版本 | 产物来源 | stock UPX 结果 | 外包 launcher+runtime | UPX 版本 |
|------|----------|----------------|----------------------|----------|
| v1 1.18.21 | A 线 transplant | **成功** `--best` 179MB→51.9MB (28.86%, 109min) | **成功** 1794B launcher + 57MB packed runtime | 5.2.0 |
| v1 1.18.32 | A 线 transplant | N/A（未试） | **成功**（在架 `opencode1-compressed_1.18.32`） | 5.2.1 |
| v2 2.0.12 gnu | B 线 bun-compile | **失败** SIGSEGV 0x40 | 未试 | 5.2.1 |
| v2 2.0.12 musl | B 线 bun-compile | **失败** SIGSEGV 0x40 | 未试 | 5.2.1 |

**关键分界**：v1 = A 线（`transplant.py` 手术产物），v2 = B 线（`bun compile` 直出）——两者 ELF 结构根本不同。

**崩溃签名**（v2 双基底一致）：
```
panic: Segmentation fault at address 0x40
Bun v1.4.2/1.4.0 (744846f84) Android arm64
oh no: Bun has crashed. This indicates a bug in Bun, not your code.
```
- 崩溃点 = **UPX 解包完成后 bun runtime 初始化阶段**（不是 UPX stub 本身）
- `0x40` 偏移 = 典型的**空指针 + 结构体字段访问**（ptr=NULL, field_offset=0x40）
- 对照：未压制版 v2.0.12 gnu/musl 双双正常运行（`--version` + PTY smoke 全过）

---

## 1. 四假说与检验序列

### 假说 ①：bin 结构差异（最强候选）

**主张**：v1 A 线 transplant 产物的 PT_LOAD/embed 布局与 v2 B 线 `bun compile` 直出根本不同，UPX 对前者能正确处理、对后者踩空。

**证据面**：
- ra-forensics.txt 里 v1 packed 的 phnum=64（UPX stub 重建态）vs rb1 失败件的 program headers 对照
- A 线 transplant 手术 = 手工修 ELF（改段、换动态链接器、注入 seccomp shim）——UPX 之前已被人改过一次
- B 线 bun compile = 官方工具链直出，未被 transplant 摸过——但可能有 bun 自有的段布局特性（embedded store 段、self-check 段）

**检验命令**（同参双压对照，最强判据）：
```bash
# A 线 1.18.x bin（已知可压）
upx -4 -o /tmp/v1-test.upx artifacts/transplant/1.18.21/opencode-native-revived

# B 线 2.0.x bin（已知崩）
upx -4 -o /tmp/v2-test.upx artifacts/build/2.0.12/opencode-native-revived

# 结构对比
readelf -lW /tmp/v1-test.upx > /tmp/v1-ph.txt
readelf -lW /tmp/v2-test.upx > /tmp/v2-ph.txt
diff /tmp/v1-ph.txt /tmp/v2-ph.txt
```

**PASS/FAIL 判据**：
- A 活 B 死 → 坐实结构差异（下一步：读 diff 找可疑段）
- A 死 B 活 → 1.18.21 bin 已不可复现（版本漂移）→ 假说 ① 降级
- 双活 → 假说 ① 否定，转 ②③④
- 双死 → UPX 5.2.1 本身问题（5.2.0→5.2.1 回归），转 ④

---

### 假说 ②：内嵌 store 假说

**主张**：v2 bin 内嵌 bun module archive（~40MB+ 的 `.bun` store），UPX 解压后 mmap 该段时布局被改，bun init 读自己的 store 踩空。

**证据面**：
- v2 282MB 的主体就是 embed 的 module-graph + node_modules（rc2b normalize）
- 崩溃点 = bun init（正是读 store 的时机）
- `0x40` = store header 结构体字段（magic/version/offset 字段偏移）

**检验命令**：
```bash
# strace 定位死在哪段 mmap
strace -f -e trace=mmap,munmap,mprotect,read,openat \
  artifacts/build/2.0.12/opencode-native-revived --version 2>&1 | tail -50

# 或 ltrace（若可用）
ltrace -e mmap,munmap artifacts/build/2.0.12/opencode-native-revived --version 2>&1 | tail -30

# 对照：压一个无 embed 的最小 bin（bun compile 空项目）
echo 'console.log("hi")' > /tmp/empty.js
bun build --compile /tmp/empty.js --outfile /tmp/empty-bin
upx -4 /tmp/empty-bin && /tmp/empty-bin && echo "small-bin PASS"
```

**PASS/FAIL 判据**：
- strace 死在 `mmap(0x..., 0x..., PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, ...)` 或对 embed 段的 `mmap` → 坐实
- 小 bin（无 embed）压制后正常 → embed 是变量 → 假说 ② 成立
- 小 bin 也崩 → embed 不是变量 → 假说 ② 否定，转 ③

---

### 假说 ③：crhandler DT_NEEDED 假说

**主张**：v2 hardened bin 带 `DT_NEEDED libopencode-crhandler.so`（seccomp shim），UPX 解包后动态链接器重新解析 DT_NEEDED 时时机不对，shim 初始化早于 bun runtime 导致空指针。

**证据面**：
- `package_deb_native.sh` 明确注入 `DT_NEEDED libopencode-crhandler.so`（seccomp 硬化）
- v1 1.18.21 时代也有 seccomp（A 线 `seccomp-harden`），但 A 线的 linkmap 结构不同
- 崩溃 0x40 = shim handler 结构体字段（未初始化的 handler 函数表）

**检验命令**：
```bash
# unhardened 对照（无 crhandler）
cp artifacts/build/2.0.12/opencode-native-revived /tmp/v2-unhardened
# 移除 DT_NEEDED（若有 patchelf）
patchelf --remove-needed libopencode-crhandler.so /tmp/v2-unhardened
upx -4 /tmp/v2-unhardened && /tmp/v2-unhardened --version && echo "unhardened PASS"

# 或直接找 unhardened 中间产物（transplant 链路中 harden 之前的 bin）
find artifacts/transplant -name '*-native' -o -name '*-revived' | grep -v crh
```

**PASS/FAIL 判据**：
- unhardened 压制后正常 → crhandler 是变量 → 假说 ③ 成立
- unhardened 也崩 → crhandler 不是变量 → 假说 ③ 否定，转 ④

---

### 假说 ④：UPX 版本回归

**主张**：v1 report 时代用 upx 5.2.0 成功，本机现 5.2.1——5.2.0→5.2.1 引入回归导致 v2 处理失败。

**证据面**：
- `.omo/evidence/opencode-compressed-upx-report.txt` 记录 `upx 版本: upx 5.2.0`
- 本机 `/data/data/com.termux/files/usr/bin/upx --version` = 5.2.1
- 中间隔了 v1 1.18.32 外包压制（5.2.1 成功）——但那是不同的输入结构

**检验命令**：
```bash
# 获取 5.2.0（若本机有旧版本二进制）
find / -name 'upx-5.2.0*' -o -name 'upx-520*' 2>/dev/null | head -5
# 或从 GitHub release 下载
curl -sL https://github.com/upx/upx/releases/download/v5.2.0/upx-5.2.0-arm64-linux-android.tar.xz \
  | tar -xJ --strip-components=1 -C /tmp/upx520
/tmp/upx520/upx --version

# 同参压制对照
/tmp/upx520/upx -4 -o /tmp/v2-520.upx artifacts/build/2.0.12/opencode-native-revived
```

**PASS/FAIL 判据**：
- 5.2.0 压制 v2 成功 → 5.2.1 回归坐实（降级或等 5.2.2）
- 5.2.0 也崩 → 版本不是变量 → 假说 ④ 否定，回到 ①②③ 检验

---

## 2. 两条 v1 成功线的结构区别

### 线 A：stock UPX 整包直压（report 在案）

```
输入:  artifacts/transplant/1.18.21/opencode-native-w7c2-fixed  (179,807,785B)
输出:  artifacts/transplant/1.18.21/opencode-native-revived-upx (51,891,796B, 28.86%)
命令:  upx --best -o <output> <input>
耗时:  109 分钟 (2026-08-28 20:41 → 22:30)
UPX:   5.2.0
产物:  ELF 64-bit LSB pie executable, ARM aarch64, statically linked
```

**特征**：单一 ELF、无 launcher、`--best` 最高压缩、A 线 bin、bionic。

### 线 B：外包 launcher + runtime（57M 真身）

```
结构:  1794B launcher (shell/ELF wrapper) + 57MB packed runtime (UPX 压制)
在架:  packing/dpkg-compressed/opencode1-compressed_1.18.32
特征:  launcher 负责设置 LD_LIBRARY_PATH/环境后 exec runtime
UPX:   5.2.1 (推测，基于 packaging 时间线)
```

**关键问题**（recall-pack ③ 精确提问）：
- 外包线压制**前**是否有 ELF 预处理（段剥离/瘦身）？
- launcher 是编译的 C 还是 bash 脚本？
- runtime 是直接压整 bin 还是压了段？

**与 v2 的关联**：如果 v1 外包线压制前有预处理，v2 也得做同样预处理——这是可移植配方的核心。

---

## 3. 检验序列（推荐执行顺序）

| 序号 | 假说 | 耗时 | 判据 | 产出物 |
|------|------|------|------|--------|
| 1 | ④ 版本回归 | ~5min（若 5.2.0 在手） | 5.2.0 能压 v2？ | `t-upx520-test.txt` |
| 2 | ① 结构差异 | ~3min（双压+diff） | A 活 B 死？ | `t-structure-diff.txt` |
| 3 | ③ crhandler | ~2min（unhardened 压制） | unhardened 活？ | `t-unhardened-test.txt` |
| 4 | ② embed store | ~5min（strace+小 bin） | 小 bin 活？ | `t-embed-strace.txt` |

**并行性**：①③④ 可并行（不同输入），② 依赖 ① 结果（若 ① 坐实则 ② 无需做）。

**汇总路径**：`.omo/evidence/upx-v2-fix/t1-structure-diff.txt` 等，全部证据入 `docs/upx-v2-fix.md` 的「检验记录」章节。

---

## 4. 若全灭：备选方案

四假说全部否定后，非 UPX 路径：

1. **sfs (squashfs)**：`mksquashfs` + `squashfuse` 挂载——比 UPX 更通用，无 stub 执行
2. **自定义 UPX stub**：改 stub 适配 bun init（高风险，需 upx 源码级改动）
3. **rodata 分离**：把 embed store 拆成独立 `.so`/文件，只压 runtime 代码段
4. **接受不压缩**：v2 native 本就 282MB，v1 compressed 也只是 57MB——用空间换稳定性

---

## 5. 与 recall-pack 的接口

`docs/handover/recall-pack.md` ③节「精确提问」应回收以下问题（当前四假说的盲区）：

1. **压制执行的机器与系统**？（Termux 本机 or 实验机 or 其他）
2. **完整命令行含全部 flags**？（`--best` vs `-4` vs 自定义？）
3. **有无 ELF 预处理/后处理**？（段剥离？patchelf？手动改 PH？）
4. **是否自编 UPX 或改 stub**？（stock 二进制 or 自己编译的？）
5. **compressed-branch 的实际载体**？（shell 脚本？makefile 目标？还是记忆里的命令？）

老代理回答这 5 个问题后，四假说应能收敛到 1-2 个，然后直接出配方。

---

**验证命令**（F5 采纳标准）：
```bash
# 每假说至少一条可跑命令
upx -4 -o /tmp/t1.upx artifacts/transplant/1.18.21/opencode-native-revived  # ①
strace -e mmap artifacts/build/2.0.12/opencode-native-revived --version 2>&1 | tail  # ②
patchelf --remove-needed libopencode-crhandler.so /tmp/v2-unhardened  # ③
/tmp/upx520/upx --version  # ④
```

**实物路径实测存在**：
- `.omo/evidence/opencode-compressed-upx-report.txt` ✓
- `.omo/evidence/rc3-release/ra-forensics.txt` ✓
- `artifacts/build/2.0.12/opencode-native-revived` ✓
- `artifacts/transplant/1.18.21/` ✓（若已 clean 则从 release 下载）
- `/data/data/com.termux/files/usr/bin/upx` ✓ (5.2.1)
