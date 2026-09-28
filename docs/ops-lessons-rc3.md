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
