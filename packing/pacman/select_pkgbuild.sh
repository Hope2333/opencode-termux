#!/data/data/com.termux/files/usr/bin/bash
# Select appropriate PKGBUILD based on architecture

ARCH=$(uname -m)
case "$ARCH" in
    "aarch64"|"arm64")
        echo "Using aarch64 PKGBUILD"
        cp PKGBUILD.aarch64 PKGBUILD
        ;;
    "armv7l"|"arm")
        echo "Using armv7l PKGBUILD"
        cp PKGBUILD.armv7l PKGBUILD
        ;;
    *)
        echo "Unknown architecture: $ARCH"
        echo "Using default aarch64 PKGBUILD"
        cp PKGBUILD.aarch64 PKGBUILD
        ;;
esac
