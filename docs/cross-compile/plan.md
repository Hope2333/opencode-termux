# 分阶段实施计划：真要做多目标的话

> 前置阅读：[README](README.md)（矩阵与推荐）、[shim-porting.md](shim-porting.md)（哪些 shim 该退休）。
> 证据编号 E* → `.omo/evidence/a2-v1-effect-rebuild/task-31-crossarch.txt`。

## 方案对比（决策依据）

| | **A: bun baseline 打包 + CI 原生 runner** ★ | B: qemu-user + binfmt 全交叉 | C: 自托管 ARM runner 真机构建 |
|---|---|---|---|
| 形态 | 本机出产物，CI 原生 runner 验证 | x64 runner 上 binfmt 模拟目标架构执行一切 | 长期租 ARM 机器（或自购）当 runner |
| 前置条件 | ① `build.ts` target 参数化 ② 放宽 `A2_TARGET_FILTER` ③ CI 加 glibc job | ① 可写 `binfmt_misc`（**本机被沙箱封**）② `qemu-*-static` ③ target rootfs ④ docker daemon（**本机不可用**） | ① 一台 ARM64 机器或云 ARM runner ② 把它接进 CI ③ 维护镜像与工具链同步 |
| 风险 | **低**。不引入新依赖类别 | **中**。binfmt 全局注册影响宿主；模拟误差；TUI 时序可能失真 | **中**。机器/额度成本；镜像维护负担；供应链面变大 |
| 增量成本 | 首个 glibc 目标 **1–2 天**，此后每目标 **+0.5 天** | **3–5 天** | 首日 1–2 天接入，之后每次 CI 运行按云价目计费 |
| 何时失效 | 若 CI 额度耗尽或不能接受「本机无法自验」 | 若宿主无 binfmt 权限（本机就是这种） | 若不愿承担常驻机器成本 |

### 推荐：**方案 A**

理由（三条，按权重）：

1. **技术风险最低**。方案 A 用的全是已验证过的机制：bun 官方 baseline 下载
   （E1.2 四目标实测通过）+ GitHub 原生 runner（上游 opencode 正在用，E4.1）。
   不引入 qemu/binfmt/容器任一类别的新故障面。
2. **与上游一致，可直接抄**。上游 `build.ts` 的 target 枚举与 `Bun.build({compile:{target}})`
   调用（E4.2 `:83-144`/`:205-213`）就是我们需要的全部机制，差异只在
   「宿主是 android」这个我们独有的约束。
3. **方案 B/C 的额外成本换不来对应收益**。我们**本来就不需要**在本地跑多架构
   （产物验证 = `--version` + TUI smoke，都是一次性的），把这部分搬到 CI 原生 runner
   比维护模拟栈便宜得多。

**方案 C 的适用时机**：若 arm64 glibc 目标成为主线且 CI 额度成为瓶颈，再租 ARM runner。
**方案 B 的适用时机**：若需要在本地跑**测试套件**（而非一次性 smoke），
或 arm64 runner 额度买不到时的退路。

**明确不推荐**：`termux-build`（方向正交，见 [ci-and-emulation.md §2 方案 C](ci-and-emulation.md#方案-ctermux-官方-termux-build-流程)）。

## 阶段 1：`linux-x64` glibc（首个新增目标）

**为什么先做它**：成本最低（shim 层几乎全退休，1–2 天），
且它一次性把「target 参数化」这项基础设施建起来 —— 之后每个新目标只多一行配置。

### 1.1 前置（必须先做，否则后续返工）

| # | 事项 | 说明 |
|---|---|---|
| P1 | ~~验证 N2~~ ✅ **已结清** | 上游 `@opentui/core-linux-x64@0.4.5` 就是官方 glibc x64 预编译，**不需编译/移植 opentui**。机制细节见 [phase1-prereq.md](phase1-prereq.md)（P1–P7） |
| P2 | ~~确认 1.4.0 行为~~ ✅ **已结清** | 1.4.0 与 1.3.14 **同款坑，全部复现**，纠正配方照旧生效。仓内继续用 1.4.0 无需升降级（P8–P14） |
| P3 | 取 glibc baseline | `https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-1.4.0.tgz`，校验 sha256 / BuildID（1.3.14 的 `a9a0d18d…` 不能沿用，1.4.0 需重取） |
| **P4** | **install 门控（新增阻塞）** | 必须 `bun install --cpu=x64 --os=linux` **且在干净目录**。bionic 宿主上裸 install 会**静默跳过** x64 平台包（lockfile 有记录、exit 0、无 warning、`node_modules` 空）；只加 `--cpu=x64` 命中缓存也不重试（P15） |

### 1.2 实施

| # | 动作 | 文件 | 依据 |
|---|---|---|---|
| T1 | `A2_TARGET_FILTER` 参数化：从硬编码「linux+arm64+无abi+无avx2」改为按环境变量筛选 | `tools/a2/build-v1.sh:129` | E4.2 `:146-165` 上游同款 filter 逻辑 |
| T2 | 编译命令 = `--target=bun-linux-x64-musl` **＋** `--compile-executable-path=<glibc baseline>`（**两者必须同时给**） | 同上 | P13 组合 C；见下方配方纠错 |
| T3 | `process.platform` 烘焙断言：编译后 `strings` 查烘焙值，**不是** `"android"`，否则 fail | 同上（新增 gate） | P13 组合 D 是「readelf 全过但 platform 错」的静默坏件 |
| T3b | glibc 线**撤掉** `apply-platform-patch.sh` 的 `if (true)` 补丁 | `tools/a2/build-v1.sh:118-119` | P3：`if (true)` 是 bionic 线专用，会让 platform 分支判断失效 |
| T4 | glibc 目标**跳过** epoll-compat / sigsys_handler / TLSDESC 路径 | `scripts/opencode-launcher.sh`、`tools/a2/build-v1.sh` | E3.1/E3.3/E3.6：目标机内核 ≥5.10 + glibc 链接器，三者全不需要 |
| T5 | `crhandler_patch.py` 的 `LIBC_NAME` 参数化（`libc.so` ↔ `libc.so.6` ↔ `libc.musl-*.so.1`）+ 放宽「bionic aarch64 DYN」形状断言 | `tools/transplant/crhandler_patch.py:16-19,37-38` | E3.4（30–60 min） |
| T6 | 打包元数据：`package.json` 的 `os`/`cpu`（上游 `build.ts:249-250` 同样写法） | 打包脚本 | E4.2 |
| T7 | CI job：`linux-glibc-x64`，在原生 `ubuntu-2404` 上跑验收 | `.github/workflows/`（**由 res-cicd 代理负责，本目录只提需求**） | E4.1 上游同款 |

> ★ **配方纠错（重要）**：本计划初稿写的是「`--target=<glibc token>` +
> `--compile-executable-path=<glibc baseline>`」。P13 实测证明这在 bionic 宿主上
> **自相矛盾**：glibc token 单独用产出 bionic（E1.3 坑 1），配 glibc 路径又产出
> 「arch 对但 platform 烘成 android」的坏件（组合 D）。
> **唯一正解 = 组合 C**：`--target=bun-linux-x64-musl` **＋**
> `--compile-executable-path=<glibc baseline>`。两个旋钮各管一头：
> token 只管 JS 烘焙，路径只管 ELF。

**明确不做**：不移植 `epoll-compat.c`、不移植 `sigsys_handler.c`、不移植
`relax_tlsdesc.py`、不重编 bionic bun-pty、**不编译/移植 opentui**。
前四项是本阶段节省 3–5 天的关键（E3.8 排序）；opentui 是因为上游有官方 glibc 预编译包。

### 1.3 验收

在 CI 的原生 x64 runner 上执行（**不能在本机** —— E2.5 实测 qemu 无 sysroot）：

```bash
# 1. 架构与链接正确性
file out-linux-x64
#   期望: ELF 64-bit x86-64, interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux
readelf -d out-linux-x64 | grep NEEDED
#   期望: libc.so.6 / ld-linux-x86-64.so.2 / ... （绝不能出现 libc.so —— 那是 bionic）

# 2. 烘焙常量正确性（★ 这一查 readelf 查不出来，是组合 D 的唯一检出点）
strings -a out-linux-x64 | grep -oE 'PLATFORM=" \+ "[a-z]+'
#   期望: PLATFORM=" + "linux     若是 "android" 则 TUI 必起不来（opentui 落到 throw）

# 3. opentui 资产落地（P4 门控）
find node_modules -name libopentui.so       # 期望非空
readelf -d <该 .so> | grep NEEDED            # 期望 libc.so.6（= glibc 平台包）

# 4. 功能 smoke
./out-linux-x64 --version     # 期望含目标版本号

# 4. TUI smoke（对应 tools/transplant/tui_smoke.py，需 x64 侧依赖）
python3 tools/transplant/tui_smoke.py ./out-linux-x64 --timeout 30

# 5. 负向验收：错误配方必须 fail 而不是静默产出坏件
#   构造组合 D（--target=bun-linux-x64 + glibc executable-path）
#   → readelf 全绿但 strings 查烘焙值是 "android" → 应触发 T3 的 gate 报错
```

**验收标准**：1–4 全过，且第 5 项证明 gate 真的会拦（不是恰好没触发）。
⚠️ 第 5 项是**唯一能检出组合 D**的手段 —— 组合 D 的 ELF 完全合法，
`file`/`readelf` 全部通过，只有烘焙常量检查能发现。

### 1.4 回退

改动集中在 `tools/a2/build-v1.sh` 与 `tools/transplant/crhandler_patch.py`。
回退 = 恢复 `A2_TARGET_FILTER` 硬编码行 + 移除 T3 gate。
**建议用 feature flag**（如 `CROSS_TARGET=x64` 才走新路径），使 android-arm64 现有
产物构建路径**字节级不变** —— 这是本阶段的硬性要求：不许动现有基线。

⚠️ 撤 platform patch（T3b）**不能**放在 flag 同一条件下无脑执行：它是 bionic 线
专用补丁，只应在 glibc 目标路径上撤。bionic 回归验证见
[phase1-prereq.md §4 V5](phase1-prereq.md#4-下一验证动作)。

## 阶段 2：`linux-arm64` glibc

**前置**：阶段 1 全部验收通过（target 参数化已建好）。

- 改动量：**+0.5 天**。只换 target 参数（`--target=bun-linux-arm64-musl` + 对应
  arm64 glibc baseline 路径 —— 注意**同样要 musl token**，理由同组合 C）。
  shim 层的判定与 x64 **完全相同**（shim 是 aarch64 硬绑定，
  故 glibc arm64 与 glibc x64 的移植量一样 —— 都是「不移植」）。
- **额外注意**：`process.arch` 烘焙必须是 `arm64`（E1.6 坑 3：只给 executable-path
  不给 target 会烘焙成宿主 arch）。install 门控也要同步改
  `--cpu=arm64 --os=linux`（P15）。
- 验收：CI `ubuntu-2404-arm` 原生 runner（上游 E4.1 已在用这类 runner）。
- 回退：同阶段 1（flag 关掉）。

## 阶段 3：`linux-x64/arm64` musl

**前置**：阶段 2 完成。

- 改动量：**+0.5~1 天/目标**。target 串加 `musl` token 即自动修正 libc 与
  platform 烘焙（E1.6 方案 C —— **唯一不需要任何纠正手段的目标**）。
- **额外工作**：`libstdc++.so.6` + `libgcc_s.so.1` 运行时依赖（E1.3 实测 NEEDED）。
  需决策：(a) 文档标注依赖；(b) 目标机装包；(c) 静态链接（bun 上游未提供 musl 静态
  baseline → 需自编，超出本阶段范围）。
- **pty 需实测**：bun-pty 0.4.8 的 glibc 预编译在 musl 上 dlopen 是否成功
  （`libc.so.6` vs `libc.musl-*.so.1`）。若失败 → 需 musl 版 bun-pty，+1~2 天。
- 回退：flag。

## 阶段 4（可选）：`android-x64`

**为什么排最后 / 可能不做**：

| 阻塞 | 详情 | 成本 |
|---|---|---|
| **无验证载体** | 需要一台 x86_64 Android 设备（模拟器不算，`/system/bin/linker64` 那套 seccomp 行为差异大）。**采购/借用成本 > 技术成本** | 阻塞项 |
| TLSDESC x86_64 版 | `relax_tlsdesc.py` 属**重写**（x86_64 是 `GOTTPOFF`→`TPOFF32`，与 AArch64 的 0x407/0x406 完全不同） | 2–3 天 |
| bun-pty bionic x86_64 | 重编 rust-pty + 需一个 x86_64 的 android termios os 模块（现有 `termios-rs` 的 `src/os/android.rs` 是否 aarch64 假设**未取证 N1**） | 2–5 天 |
| epoll-compat x86_64 | 30–50 行（`REG_RAX`/`REG_RIP`，pc 步长 2） | 0.5 天 |
| **可能不需要** | x86_64 Android 设备（ChromeOS / x86 平板）的 bionic 通常 ≥11 → **TLSDESC 与 epoll-compat 都可能不需要** | 需先调研 |

**建议**：阶段 4 之前先做一次**纯调研**（不写代码）——查目标设备 bionic 版本，
再决定是否投入。若无设备需求，**永久搁置**。

## 阶段 5（不做）：`linux-riscv64`

bun `Architecture` 枚举只有 `X64 | Arm64 | Wasm`（E1.4 `env.rs:173-186`），
`raw_syscall6` 对非 x86_64/aarch64 是 `compile_error!`（E1.4 `linux.rs:72-76`）。
自编 bun 也需改两个 crate 的架构枚举 + 写 riscv64 syscall 内联汇编 + 一整套 libc。
**零收益，不做。**

## 关键风险登记

| 风险 | 影响 | 缓解 | 阶段 |
|---|---|---|---|
| ~~N2 未验证~~ | — | ✅ 已结清（[phase1-prereq.md](phase1-prereq.md)） | 1 |
| ~~N5 未验证~~ | — | ✅ 已结清，1.4.0 同坑、配方照旧 | 1 |
| **组合 D 静默坏件**：`--target=<glibc token>` + glibc 路径 → ELF 全绿但 platform 烘成 `android` → opentui `throw` → TUI 必崩 | 产物看似成功实则不可用 | T2 强制组合 C + T3 `strings` gate；验收第 5 项做负向验证 | 1 |
| **install 门控**（P15）：bionic 宿主裸 `bun install` 静默跳过 x64 平台包（exit 0、无 warning、`node_modules` 空） | opentui 缺失，TUI 起不来 | P4/T-row：强制 `--cpu=x64 --os=linux` + 干净目录；验收第 3 项断言落地 | 1 |
| **误信 compile 日志**：baseline 名会谎报（打印 android 实际是 glibc） | 验收误判 | 禁拿日志验收，只认 `readelf` + `strings` | 1 |
| **`if (true)` platform patch 残留** | glibc 目标 platform 分支判断失效 | T3b 撤掉 + V5 bionic 回归 | 1 |
| 现有 android-arm64 基线被破坏 | 影响当前主线（RC5/RC6 验收） | feature flag，字节级回归 | 1 |
| glibc x64 产物**未真机跑过**（N2-a：全部为静态取证，本机跑不了 x86-64） | 静态验收有盲区 | 阶段 1 必须在真 linux-x64 上跑 `--version` + TUI（[phase1-prereq §4 V4](phase1-prereq.md#4-下一验证动作)） | 1 |
| CI 额度耗尽 | 阶段 1–3 无法验收 | 退到方案 C（租 ARM runner） | 1+ |
| musl 的 `libstdc++.so.6` 依赖 | 目标机跑不起来 | 阶段 3 决策 | 3 |
| CI 额度耗尽 | 阶段 1–3 无法验收 | 退到方案 C（租 ARM runner） | 1+ |
| musl 的 `libstdc++.so.6` 依赖 | 目标机跑不起来 | 阶段 3 决策 | 3 |
