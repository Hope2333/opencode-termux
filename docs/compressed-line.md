# Compressed 线契约（opencode1-compressed / UPX-packed）

> 适用：`opencode1-compressed` deb（`scripts/package/package_deb_compressed.sh`）
> 与 pacman 包（`scripts/package/package_pacman_compressed.sh` + `packing/pacman/PKGBUILD.compressed`）。

## Launcher-only 契约

compressed 包内的压制 runtime（`$PREFIX/lib/opencode1/runtime/opencode`）
**只允许经 `opencode1` launcher 调用**，不允许直跑 runtime。

- launcher（`scripts/opencode1-launcher.sh`）在 exec 前设置
  `LD_LIBRARY_PATH`，覆盖 runtime 的 `DT_RUNPATH $ORIGIN/../lib/opencode`
  解析（crhandler shim 等）。
- 两个打包器都有构建期 guard：payload 必含 launcher（`bin/opencode1`）
  与 crhandler shim，缺一即 FATAL。

## 机制一句话

UPX stub 把 ELF 段解压映射到匿名 `/memfd:upx`，磁盘上的
`$ORIGIN`（= `lib/opencode1/runtime/`）不再对应任何可解析路径，
`DT_RUNPATH $ORIGIN/../lib/opencode` 随之失效 —— 所以必须有 launcher
显式喂 `LD_LIBRARY_PATH`。

## 直跑报错样例

```text
$ $PREFIX/lib/opencode1/runtime/opencode --version
CANNOT LINK: library "libopencode-crhandler.so" not found
```

这不是包损坏：请改用 `opencode1 --version`。

## 陈旧 runtime 隔离（native 包安装钩子）

历史 v1 包（pre-v12.1）把 runtime 放在 `$PREFIX/lib/opencode/runtime/`；
现行包已迁到 `lib/opencode1/runtime/`，旧路径可能残留无主文件（实测
o s c a r 机上有 6 月期 1.17.9，159M）。native deb/pacman 安装钩子含
保守隔离规则，满足以下**全部**条件才动它：

1. `$PREFIX/lib/opencode/runtime/opencode` 存在；
2. `dpkg -S` / `pacman -Qo` 判定无包拥有；
3. `file` 头与本包 runtime 同架构（aarch64 ELF）。

动作 = 改名备份 `opencode.stale-<日期>`（**绝不 rm**，删除由用户手动）。
若不满足条件则原样保留，仅在同名备份已存在等边缘情况下跳过。
