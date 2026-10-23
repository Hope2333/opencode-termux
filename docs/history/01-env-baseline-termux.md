# 01 - Environment Baseline (Termux)

## 系统与目录
- OS: Android
- Shell: Termux
- 工作目录：`/data/data/com.termux/files/home/termux.opencode.all`

## 关键硬约束
1. Termux 非标准 FHS 根系统，前缀通常为：`/data/data/com.termux/files/usr`
2. 运行时是 Bionic，不等同 glibc
3. 共享存储可能 `noexec`，构建与运行产物应放在 app 私有可执行目录

## 包管理现状
- 当前环境已切到 `pacman` 体系（`$PREFIX/etc/pacman.conf`）
- `pkg/apt` 通过转译脚本映射到 `pacman`

## 风险说明
- 切换包管理器在 Termux 属于破坏性操作（可能替换 `usr/`）
- 混用外部 Debian/Ubuntu 仓库会导致不可预期冲突
- `grun` 能解决部分 glibc 运行问题，但对 Bun bundled executable 存在行为差异

## 构建前采集
```bash
uname -a
getprop ro.product.cpu.abi
echo "$PREFIX"
echo "$TMPDIR"
pacman -V
node -v
npm -v
python3 -V
clang -v
```

## 下一步
- 锁定 bun/opencode/loader 的 tag+commit
- 每次构建写入 source meta 与环境日志
