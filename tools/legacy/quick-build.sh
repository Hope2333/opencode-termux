#!/bin/bash
# OpenCode Termux 快速构建脚本
# 用法: bash quick-build.sh <版本号>
# 示例: bash quick-build.sh 1.2.10

set -e

VERSION="${1:-1.2.10}"
WORK_DIR="\~/work-$VERSION"

echo "=== OpenCode Termux Build ==="
echo "Version: $VERSION"
echo "Work dir: $WORK_DIR"
echo ""

# Step 1: 准备工作目录
echo "[1/5] 准备工作目录..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Step 2: 下载官方二进制
echo "[2/5] 下载官方二进制..."
npm pack "opencode-linux-arm64@$VERSION"
tar -xzf "opencode-linux-arm64-$VERSION.tgz"
file package/bin/opencode

# Step 3: 使用bun-termux-loader包装
echo "[3/5] 使用bun-termux-loader包装..."
cd ~/bun-termux-loader
python3 build.py "$WORK_DIR/package/bin/opencode" --wrapper ./wrapper

# Step 4: 放入构建系统
echo "[4/5] 放入构建系统..."
mkdir -p ~/termux.opencode.all/artifacts/opencode/runtime
cp "$WORK_DIR/package/bin/opencode-termux" ~/termux.opencode.all/artifacts/opencode/runtime/opencode-termux

# Step 5: 构建和打包
echo "[5/5] 构建和打包..."
cd ~/termux.opencode.all
rm -rf artifacts/opencode/staged artifacts/opencode/build.meta
bash scripts/build/build_opencode.sh
bash scripts/package/package_deb.sh opencode
bash scripts/package/package_pacman.sh opencode

# 验证
echo ""
echo "=== 构建完成 ==="
echo ""
echo "验证结果:"
~/termux.opencode.all/artifacts/opencode/staged/prefix/lib/opencode/runtime/opencode --version
echo ""
echo "产物位置:"
ls -lh ~/termux.opencode.all/artifacts/opencode/deb/
ls -lh ~/termux.opencode.all/artifacts/opencode/pacman/
