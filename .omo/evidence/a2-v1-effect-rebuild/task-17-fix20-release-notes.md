# fix20 发布文案草稿（两版，2026-10-04）

FIX_URL=https://github.com/Hope2333/opencode-termux/releases/download/EarlyEmergencyRelease0/init-pacmanV00fix20.sh

---

## 版本 A — GitHub Release note（opencode-termux / EarlyEmergencyRelease0）

```
【紧急修复】pacman 叠影事故（2026-10-04）

9 月下旬至 10 月初经旧版 init/install 脚本配置 hope2333 源的机器，pacman.conf 被写入
RootDir = /data/data/com.termux/files，绝对路径包被叠装入多余目录，程序装完即失效。我们为此致歉。

自检：存在 /data/data/com.termux/files/data/ 目录，或 pacman 所装程序无法运行。

一键修复：
  bash <(curl -sL https://github.com/Hope2333/opencode-termux/releases/download/EarlyEmergencyRelease0/init-pacmanV00fix20.sh)

脚本自动完成：注释 RootDir 回落默认 → 重装受影响包归位 → 校验落点 → 经确认后清理叠影目录。
已装 hope2333-mirrorlist 的机器：更新该包时会自动检测，检出问题即打印上述修复命令。
预防：包生成器已加绝对路径断言门（零相对 usr/ 成员方可出包），install.sh 的 RootDir 写入已纠正。
```

---

## 版本 B — 站点公告（hope2333.github.io 首页 / wiki 公告位）

```
关于近期 pacman 安装程序失效的说明与修复（10-04）

若您在 9/20–10/3 期间通过本站脚本安装过软件源，且 pacman 安装的程序无法启动——
这是我们的配置脚本写入了错误的 pacman RootDir，包文件被叠装入多余目录所致。向您致歉。

一键修复：
  bash <(curl -sL https://github.com/Hope2333/opencode-termux/releases/download/EarlyEmergencyRelease0/init-pacmanV00fix20.sh)

无需手动操作的部分：已装 hope2333-mirrorlist 的机器，更新该包时将自动检测，
并在发现问题时于安装输出中打印上述修复命令。
详见公告文件：https://hope2333.github.io/NOTICE.md
```
