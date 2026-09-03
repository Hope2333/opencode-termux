# Upstream Notification: Package Rename Transition

**Target:** XiaomiMiMo/MiMoCode (sister port) and any other downstream forks  
**Date:** 2026-09-03  
**Status:** Ready for distribution after Push 27/28 tag

## What Changed

The `opencode-termux` repository completed a package rename transition effective at Push 27/28:

| Old Name | New Name | Line | Command Entry |
|---|---|---|---|
| `opencode` (glibc wrapper) | `opencode-glibc` | glibc wrapper (appendix) | `opencode` |
| — (new) | `opencode-glibc-standalone` | glibc wrapper, frozen single version | `opencode-glibc` |
| `opencode-native` | `opencode` | native bionic (mainline) | `opencode` |

**Key facts:**
- The native bionic line now inherits the plain `opencode` package name (stable mainline since 27/28).
- The glibc wrapper line was renamed `opencode-glibc` (demoted to appendix maintenance).
- A new `opencode-glibc-standalone` package provides a frozen rollback with independent prefix.
- `opencode` and `opencode-glibc` are mutually exclusive (cannot coexist).
- `opencode-glibc-standalone` coexists with `opencode` but conflicts with `opencode-glibc`.

## Impact on Downstream

If your repository references package names from `opencode-termux`:

1. **Package name references**: Update any `opencode` (glibc) references to `opencode-glibc`.
2. **Build scripts**: `scripts/package/package_deb.sh` and `scripts/package/package_pacman.sh` now produce `opencode-glibc` packages.
3. **PKGBUILD**: `packing/pacman/PKGBUILD` pkgname is now `opencode-glibc`.
4. **DEB control**: `packing/deb/DEBIAN/control` Package field is now `opencode-glibc`.
5. **New files**: `PKGBUILD.standalone`, `package_deb_standalone.sh`, `package_pacman_standalone.sh` are new additions.

## What Does NOT Change

- The `opencode` binary name (command entry) remains `opencode` for native bionic.
- The `opencode-glibc` binary name (command entry) remains `opencode` for glibc wrapper.
- The transplant pipeline (`tools/transplant/`) is unchanged.
- The staging/build infrastructure (`scripts/build.sh`, `scripts/common.sh`) is unchanged.

## Timeline

- Effective at Push 27/28 (package rebuild + tag).
- No breaking changes for users who only consume release artifacts — the `opencode` binary name is preserved.

## Action Required

- Review your packaging templates for any hardcoded `opencode` (glibc) package name references.
- If you maintain a fork, sync your packaging layer after Push 27/28.
- Contact: Hope2333 (幽零小喵) <u0catmiao@proton.me>
