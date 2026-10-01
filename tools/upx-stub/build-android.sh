#!/bin/sh
# build-android.sh -- 在 Android aarch64 Termux 本机重建打了补丁的 UPX 5.2.1（stub + 本体）
#
# 输入: $1 = upx 源码树（默认 $TMPDIR/upx-src），要求 amd64-linux.elf-main2.c 已打 memfd 补丁
# 输出: <src>/build/upx  自编 upx 二进制
#
# 原理:
#   官方 stub 重建需要 x86 专用 gcc-4.9.2 + binutils-2.25 交叉链（src/stub/Makefile 引用
#   arm64-linux-gcc-4.9.2 / arm64-linux-ld-2.25 / arm64-linux-objcopy-2.25 / arm64-linux-objdump-2.25）。
#   本脚本不改 Makefile 一行，而是在 PATH 前置同名 shim:
#     gcc  -> clang --target=aarch64-linux-gnu -ffreestanding -fno-stack-protector
#             (.S 额外加 -fno-integrated-as: 官方 arm64-expand.S/lzma_d.S 尾部有同地址重复
#              标号 not_lzma，GNU as 容忍而 clang 集成汇编器拒绝；-E 后交 GNU as 语义等价)
#     ld   -> ld.bfd (Termux binutils 包自带，native aarch64，原生 elf64-littleaarch64)
#     objcopy/objdump -> gobjcopy/gobjdump (Termux 把 GNU 真身改名为 g 前缀，
#             裸名 objcopy/objdump 是 llvm 符号链接，llvm 版布局会挂 xstrip.py 断言)
#   生成规则零改动: 仍走官方 Makefile recipe（objcopy 清段 + gobjdump -htr -w 文本 +
#   xstrip/bin2h.py），仅编译器换代，保证 dump 文本与 UPX 运行时 ElfLinker 解析格式兼容。
#
# 只重建 arm64-linux.elf-fold.h: main2.c 补丁只进 fold stub（arm64-linux.elf-main2.c
# include amd64-linux.elf-main2.c）；entry/so_entry/shlib-init 不受补丁影响，保留官方 git 字节。
set -eu

SRC="${1:-$TMPDIR/upx-src}"
: "${TMPDIR:?TMPDIR must be set (Termux)}"
[ -f "$SRC/src/stub/src/amd64-linux.elf-main2.c" ] || { echo "ERR: $SRC 不是 upx 源码树" >&2; exit 1; }

for tool in cmake clang clang++ ld.bfd gobjcopy gobjdump python3; do
  command -v "$tool" >/dev/null || { echo "ERR: 缺少 $tool (pacman -S binutils cmake)" >&2; exit 1; }
done

# 1. vendor 子模块（cmake 顶层构建需要）
if [ ! -f "$SRC/vendor/ucl/CMakeLists.txt" ]; then
  git -C "$SRC" submodule update --init --depth 1
fi

# 2. shim 工具链
SHIMS="$TMPDIR/upx-shims"
mkdir -p "$SHIMS"
cat > "$SHIMS/arm64-linux-gcc-4.9.2" <<'EOF'
#!/bin/sh
has_S=0
for a in "$@"; do case "$a" in *.S) has_S=1 ;; esac; done
extra=""
[ $has_S = 1 ] && extra="-fno-integrated-as"
args=""
for a in "$@"; do
  case "$a" in
    -Werror) ;; # clang 警告集与 gcc-4.9.2 不同，仅去 -Werror，保留 -Wall -W 诊断
    *) args="$args $a" ;;
  esac
done
exec clang --target=aarch64-linux-gnu -ffreestanding -fno-stack-protector $extra $args
EOF
cat > "$SHIMS/arm64-linux-ld-2.25" <<'EOF'
#!/bin/sh
exec ld.bfd "$@"
EOF
cat > "$SHIMS/arm64-linux-objcopy-2.25" <<'EOF'
#!/bin/sh
exec gobjcopy "$@"
EOF
cat > "$SHIMS/arm64-linux-objdump-2.25" <<'EOF'
#!/bin/sh
exec gobjdump "$@"
EOF
chmod +x "$SHIMS"/arm64-linux-*

# 3. 重出补丁涉及的 stub 头（fold 依赖 main2.o）
mkdir -p "$SRC/src/stub/tmp"
( cd "$SRC/src/stub" && PATH="$SHIMS:$PATH" make arm64-linux.elf-fold.h )

# 4. 顶层构建（host = 本机 android aarch64）
BUILD_DIR="$SRC/build"
cmake -S "$SRC" -B "$BUILD_DIR" \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" -j8

echo
echo "OK: $BUILD_DIR/upx"
