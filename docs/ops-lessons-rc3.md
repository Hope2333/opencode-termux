# RC3 发布实战经验（2026-09-28）

> 来源：rc3-release 计划全量执行 + 本机 v2.0.18 构建验证 + issues #16/#17/#23/#24/#25 巡检。
> 配套执行证据：`.omo/evidence/rc3-release/`（未入库）。

## 1. 双代清空重铸（clean-slate rebuild）流程

- 清空旧 release 资产是**单向门**：执行前把资产 `id + name` 清单落盘存证（`releases/<id>/assets?per_page=100`），执行时与架上实时对账，不符先覆写清单再删；逐 id DELETE（204=成功，404=跳过），单 id 失败重试 3 次。
- `--clobber` 上传（同名覆盖）只对 deb 生效——**pac 产物名带 pkgrel，改 PKGREL 就是改名**，旧 rel 文件不会自动下架。
- 上架后逐件对账用 **API 的 `digest` 字段**（`sha256:<hex>`）与本地 sha256 直接比对，无需下载抽样。
- 件数账：清空 N 件 → 新上 M 件 → 架上 = M + site-rebuild 自愈回传件（db/mirrorlist，自动出现，勿重复上传）。

## 2. PKGREL 透传矩阵（pkgrel 语义）

| 脚本 | PKGREL env | 状态 |
|------|-----------|------|
| `package_pacman_native.sh` | `PKGREL="${PKGREL:-1}"` → sed pkgrel | 原生支持 |
| `package_pacman_compressed.sh` | 同上（且恒 `.pkg.tar.gz`） | 原生支持 |
| `package_wrapper_v2.sh` | 曾硬编码 `pkgrel=1`（4 处：OUT_PAC/PKGBUILD/断言/mv） | 已修 `22bcb94` |
| deb 线 | 无 pkgrel 概念，Version 不变 = `--clobber` 覆盖 | N/A |

- 命令行 `PKGREL=3 make batch-v2 ...` 经环境变量自动传给全部子 make，无需逐级改 Makefile。
- **工具侧自适应**：`tools/fleet-push.py` 曾四处硬编码 `-1-`（`84086a9` 已改为 `-\d+-` 通配 + 同版本多 pkgrel 取最高，防旧 `-1` 残留 1.4.2 时代包被误分发）。

## 3. clean-version 自洁目标（afb31db）

- 四清：`$TMPDIR/v2src/opencode-<ver>` 解包树（tarball 点名保留）、`artifacts/staged` + `packing/{dpkg,dpkg-native,dpkg-compressed}/work` + `packing/pacman/{pkg,src}`、`artifacts/transplant/<ver>`、`artifacts/wrapper/<ver>`。
- 保留：`artifacts/build/<ver>`（bin+sha+json）、`packing` 交付包、`v2src/*.tgz`、`transplant/android-bun`、`wrapper/glibc-standalone`。
- bin 缺失守卫：`artifacts/build/<ver>` 存在但 bin 缺失 → 拒清退出（防误清后假成功）。
- `NOT_CLEAN=1` 全链退出（batch/batch-v2 循环尾、六 family 尾部、子 make 透传）；**`release-upload NATIVE=1` 必须带 `NOT_CLEAN=1`**，否则上传源 `artifacts/transplant/<ver>` 会被自洁吞掉。
- **Make 配方陷阱**：make 逐行配方 = 每行独立 shell，`exit 0` 拦不住后续行——守卫/执行/校验必须合并进单个 shell 调用（if/elif/else）。

## 4. 构建脚本漂移防线

- **OpenTUI chunk 文件名漂移**（#25，2.0.18/OpenTUI 0.5.12：`9gqvxy8c` → `8f4q4e2m`）：`apply-platform-patch.sh` 已改为按内容动态发现（`grep -RIl 'platform: process.platform'`，`ce1c2ca`）。上游 bun-compiled 产物文件名随时会漂，**禁硬编码生成文件名**。
- bun 底座 pin：`build-bionic.sh` 强制 bun@1.4.0（1.4.2 在 bionic SIGSEGV@0x40）；`resolve_bun_base()` 按 bind 目标优先排序缓存。

## 5. 网络/上传链路（fake-IP 环境）

- 透明代理白名单制：`api.github.com` 常通；`uploads.github.com` / `github.com` 可能被掐（症状：curl code=000 / TLS ClientHello 即 reset）。直连真 IP 也会被 SNI 无差别 reset，DoH 逃生门同样被掐 → 只能等代理放行，别盲试。
- fleet-push fetch 进度回归：`fetch.py` 的 `Content-Length` 可能被代理/分块剥掉 → 进度条恒 0%（下载本身正常）。已改为控制器传入期望 size 兜底（`f5102fb`），`pct` 封顶 100。
- 上传侧替代：curl `-K` 配置文件 + `--resolve` 真 IP；或直连代理放行后普通 curl（当前路径）。

## 6. ⚠️ OPEN：v2 native 包缺 seccomp shim（#17/#24 实证）

- 现象：kernel 4.19（Android 11）上 v2 native `opencode 2.0.12-3` SIGSYS（Bad system call, exit 159）；包内只有 `usr/bin/opencode`，无 shim。v1 `opencode1 1.18.32-3` 正常（`lib/opencode/libopencode-crhandler.so` 在包内）。
- 实证：`LD_PRELOAD=$PREFIX/lib/opencode/libopencode-crhandler.so opencode --version` → exit 0。
- 根因：`family-v2-native` 链路**不经过** `harden-native`（仅 family-v2-compressed 走 harden），且 `deb-native/pacman-native` 不 ship shim。
- **待办**：family-v2-native 接入 harden-native + deb/pacman-native 打包 ship shim（v1 布局 `lib/opencode/` + DT_RUNPATH），重建 v2 native 架上资产。修复前 workaround：`LD_PRELOAD=$PREFIX/lib/opencode/libopencode-crhandler.so opencode`。
- 待澄清：#17 报告 `pacman -U` 尝试写 `/usr`——本机 Termux pacman `pacman -U` 正常（2.0.18-1 实装验证），需对方提供 `pacman -v`（RootDir/DBPath）判断其 pacman 配置差异。

## 7. 社区运营模板

- Discussions 多语言五语（en/zh-Hans/zh-Hant/ja/es）公告与欢迎帖模板已落 31 仓（Announcements/General 板块）；新语言加一行即可。
- README 五语对标结构：`README{,.zh,.es,.zht,.ja}.md` 各 140 行逐章节对齐；横幅单源 `assets/discussions-banner.svg`（SMIL 动画，camo 下可动）。
- API 边界：Discussions 分类**创建/改名/描述/置顶**均无 API（UI-only）；发帖/改帖经 GraphQL `createDiscussion`/`updateDiscussion`。

---

## §8 RC4 追加（2026-09-29）

- **UPX-on-bionic 证伪**：stock UPX 压制手术过的 bun standalone bionic ELF（DT_NEEDED/RUNPATH 补丁 + .bun section）→ 同机未压制版正常、压制版 SIGSEGV@0x11。UPX aarch64 stub 按 glibc 惯例假设，不可靠；压制需求走 opencode-compressed-branch 外包路线。RC3/RC4 计划 Must-NOT-have「UPX 零触碰」再次验证正确。
- **嵌入资产污染检测法**：上游把平台二进制以 sha256 字符串形式嵌进编译产物——对产物 `strings | grep -c <hash>` 即可判定嵌入的是哪个变体（musl f9b069d3… / gnu 25e9273e…）。时序坑：修复合入前构建的包仍带旧资产，修复合入后必须全量重建或逐版断言。
- **源码获取双路**：codeload.github.com 间歇阻断（fake-IP 代理白名单外抖动），`git clone --depth 1 --branch vX` 直连 github.com 主机稳定；tarball 下载后必须 gzip -t 完整性校验（--max-time 截断会产出半截包，播种坏源坑后续构建）。
- **ENOSPC 纪律**：13 版批量构建前先 df 闸；v2src 源树/中间件（.pre-crhandler）用完即清；~/.bun/install/cache 单项可达 3.4G。

## §9 RC4 收口追加（2026-09-29）

- **本机 $PREFIX/glibc 消失事件**：wrapper 门空输出的真因是本机 vendored glibc 运行时缺失（连货架 2.0.12 wrapper 都报 `open ld.so failed`）。gpkg glibc 包 payload 路径自带 `data/data/com.termux/files/usr/glibc` 前缀，在 RootDir=/data/data/com.termux/files 下装入**双重嵌套路径**；用最小文件级符号链接桥接（343 个运行库文件、**排除 libc.so 文本 ld script**——目录级链接会把脚本暴露给 termux-exec preload，bash 启动即死 invalid ELF header）。教训：wrapper 门失败先测货架旧 wrapper 是否同样失败，区分「包坏了」vs「机器环境坏了」。
- **bin 守卫误伤 wrapper-only 流程**：`artifacts/build/<VER>` 存在但 revived bin 已被磁盘清理删除时，clean-version 守卫拒绝整个自洁。wrapper-only 批次用 `NOT_CLEAN=1` 绕过（该批次无需自洁）。
- **makepkg 并发互斥**：batch-v2 的 native 与 wrapper 批次共享 `packing/pacman/{src,pkg}`，禁止并行——必须串行排队。
- **并行发起竞态**：glibc 修复与依赖它的构建批次不能在同一消息里并行发起（修复落盘前批次已跑到门）。
- **RC4 终态**：96 计划件（v2 native 38 + v2 wrapper 38 + v1 20）+ site-rebuild 4；RC5=B1(native-gnu) 定版、RC6=B2(native-musl) 定版、compressed 独立 pkgrel、v2.0.12 实验车 UPX_OPTS=-4（RFC discussions/29）。

## §10 RC5 追加（2026-09-30）

- **PTY_VARIANT 开关**：build-bionic `PTY_VARIANT=musl|gnu`（默认 musl 行为不变），双模式 2.0.12 验收（musl=2/0 ↔ gnu=0/2）。RC5=B1 定版 38 件上架（Push260930，PKGREL=5）。
- **受控实验修正早前结论**：UPX -4 直压在 gnu/musl 双基底上**均 SIGSEGV**、未压制对照全活——「压制层杀 bun-standalone」与 PTY 变体无关，是通用问题。对照基线必须与实验件同测试床（RUNPATH $ORIGIN/../lib/opencode 相对解析，测试床缺伴生 lib 时连未压制对照都会假死）。
- **R-A 外包配方**：opencode-compressed-branch 实体未寻获（Hope2333 名下/本仓分支/本地目录均无），ELF-diff 反推（v1 57M packed 真身 vs 失败 rb1）待批。

## §11 RC5 撤销与发布门（2026-10-01）

- **用户令**：RC5 撤销；发布门升级为「**UPX 压制通过**」硬性要求——UPX 不过，不许发布。
- **机制定谳**（ra-mechanism.md，18min 子代理取证）：stock UPX 5.2.1 stub 把 282MB v2 镜像整体映射为 MAP_PRIVATE|MAP_FIXED|**ANONYMOUS**（仅代码段走 /memfd:upx 文件后备）；启动期 192MB `.bun`（$bunfs graph）在匿名映射中被丢成零页且无文件可回填 → bun 读零 → 空指针 SIGSEGV（`ldrb w0,[x26,x4]`，x26=0）。v1 的 180MB 镜像同区全程常驻（90672/90672 kB 字节一致）故存活。`upx -d` 往返 sha256 一致 = 压制无损，**死在映射形态**。
- **证伪记录**：EOF 自省（+4KB 垃圾照跑）、节头定位（清 e_shoff 照跑）均不成立；两代同为 Bun 1.4.0；`packing/dpkg-compressed` 的 1794B launcher 不做解压只设 env。
- **配方**：①v2 未压缩发布（RC4 口径=现状正确）；②省体积走 xz + launcher（解压到 $TMPDIR 后 exec 恢复文件后备映射）；③**UPX 对 v2 判死**。
- **v1 配法祛魅**：v1 压制 = 本仓 `make transplant-upx`（UPX_OPTS?=--best，Makefile:365），「外包 compressed-branch」为错误记忆——v1 成功仅因镜像形态耐匿名映射。
- **撤销执行**：Push260930 标 prerelease + make_latest=false（note 加双语 REVOKED banner）；RC4 回位 latest；site-rebuild dispatch 触发 db 回退再生；本机回装 2.0.18-4 musl（--version 通过，pty 嵌入=2）；wiki RC5 页双语标注；RFC #29 撤销公告。
- **教训**：UPX 对 bun-standalone 的兼容性是**映射形态问题而非压缩正确性问题**——`upx -t` 通过、`upx -d` 无损都挡不住运行时死；发布门若依赖压制件，必须以「真实运行冒烟」为准，不能只测压缩工具自身校验。

## §12 UPX 复活战役（rc56-upx-gate，2026-10-01）

- **补丁落地**：UPX 5.2.1 stub 非 PF_X 段从 mmap_privanon 改为每段独立 memfd 文件后备（`tools/upx-stub/v2-memfd-data.patch`，+31/-1）；数据段无 MFD_EXEC、offset=p_offset-frag 布局、RO 段重映 MAP_PRIVATE、W 段保 MAP_SHARED。
- **工具链**：PATH shim 换链（Makefile 零改动）——arm64-linux-gcc-4.9.2 系同名 shim → gobjcopy/gobjdump(binutils-2.47)+ld.bfd；clang IAS 拒绝 .S 重复标号需 -fno-integrated-as；仅 fold.h 需重出（entry 系保官方字节）。一键脚本 `tools/upx-stub/build-android.sh`。
- **实测裁决**：v2.0.12 gnu+musl 压制件（37.08/37.10%）本机四项与对照全一致；stock 阳性对照四项全 SIGSEGV（因果闭环）；oscar（3.18/3.6G RAM）6/6 冷启动零崩、dmesg 零命中、run 完整 LLM 往返。**门 1/门 2 双达标**（云发布仍冻结至 10-05）。
- **Makefile**：build-native-upx 引 `UPX_BIN`（默认 upx）+ `UPX_OPTS?=-4` 统一；family-v2-compressed 透传。
- **教训**：①测试床伴生 lib（RUNPATH $ORIGIN/../lib/opencode）缺失会让未压对照假死——基线必须与实验件同测试床；②GNU binutils 与 llvm-objdump 布局断言不兼容，stub 重建必须 GNU 系真身（本机 gobjcopy/gobjdump 包）；③TUI 在 adb pty harness 下压件与对照一致崩=测试床限制，一致性即可判过，真实验证依赖实机 GUI。
- 遗留：其它压缩等级/so 变体未逐一跑；RC5/RC6 再发布（新 tag）待 10-05 解冻后按双门契约执行。

## §13 TUI 根因定谳与门 2 修订（2026-10-01，oscar 实机）

- **双修正**：①「TUI adb-harness 一致崩=假象」作废——真终端/ssh+script 真 PTY 同签名崩（SIGSEGV@0x0 rc=139）；②「UPX-memfd 信令失效」存疑作废——F-comp 125s 超时是 glibc pty 族根因的次生表现（compressed 掩盖 dlopen 崩改走服务回退）。
- **根因**：「gnu/musl」双线只换 pty daemon（B2=静态 musl f9b069d3 已换对）；**librust_pty napi .so B1/B2 同件 glibc（libc.so.6）**→ v2 TUI 零 glibc 机全变体必死。组件级实锤：gnu daemon oscar exec "No such file or directory"、musl daemon 活；单换 daemon 无效。
- **UPX 补丁中性确认**：压/未压一致性门含 TUI 一致崩全过；B2-upx oscar 实测 version/run/serve 全过（37.19%）。
- **门 2 修订（用户裁决 A）**：非 TUI 功能双变体双机全过=判据主体；TUI 零 glibc 豁免。B 路线（musl librust_pty splice）划归 RC6/B2 任务。
- **方法论教训**：验收判据必须区分「环境可达面」——同一二进制在不同 glibc 可用性环境下功能面不同，组件级甄别（exec/dlopen 逐件验）比整机推断快且准；bun 对 pty 资产加载失败的错误路径未兜住（崩溃而非降级），上游可报。
