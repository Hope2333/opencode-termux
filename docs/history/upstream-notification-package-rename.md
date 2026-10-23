# Upstream Notification: Package Rename Transition

**Target:** XiaomiMiMo/MiMoCode (sister port) and any other downstream forks  
**Date:** 2026-09-03  
**Status:** Ready for distribution after Push 27/28 tag

## What Changed

The `opencode-termux` repository completed a package rename transition effective at Push 27/28:

| Old Name | New Name | Line | Command Entry |
|---|---|---|---|
| `opencode` (glibc wrapper) | `opencode-wrapper` | glibc wrapper (appendix) | `opencode` |
| — (new) | `opencode-wrapper-standalone` | glibc wrapper, frozen single version | `opencode-wrapper` |
| `opencode-native` | `opencode` | native bionic (mainline) | `opencode` |

**Key facts:**
- The native bionic line now inherits the plain `opencode` package name (stable mainline since 27/28).
- The glibc wrapper line was renamed `opencode-wrapper` (demoted to appendix maintenance).
- A new `opencode-wrapper-standalone` package provides a frozen rollback with independent prefix.
- `opencode` and `opencode-wrapper` are mutually exclusive (cannot coexist).
- `opencode-wrapper-standalone` coexists with `opencode` but conflicts with `opencode-wrapper`.

## Impact on Downstream

If your repository references package names from `opencode-termux`:

1. **Package name references**: Update any `opencode` (glibc) references to `opencode-wrapper`.
2. **Build scripts**: `scripts/package/package_deb.sh` and `scripts/package/package_pacman.sh` now produce `opencode-wrapper` packages.
3. **PKGBUILD**: `packing/pacman/PKGBUILD` pkgname is now `opencode-wrapper`.
4. **DEB control**: `packing/deb/DEBIAN/control` Package field is now `opencode-wrapper`.
5. **New files**: `PKGBUILD.standalone`, `package_deb_standalone.sh`, `package_pacman_standalone.sh` are new additions.

## What Does NOT Change

- The `opencode` binary name (command entry) remains `opencode` for native bionic.
- The `opencode-wrapper` binary name (command entry) remains `opencode` for glibc wrapper.
- The transplant pipeline (`tools/transplant/`) is unchanged.
- The staging/build infrastructure (`scripts/build.sh`, `scripts/common.sh`) is unchanged.

## Timeline

- Effective at Push 27/28 (package rebuild + tag).
- No breaking changes for users who only consume release artifacts — the `opencode` binary name is preserved.

## Action Required

- Review your packaging templates for any hardcoded `opencode` (glibc) package name references.
- If you maintain a fork, sync your packaging layer after Push 27/28.
- Contact: Hope2333 (幽零小喵) <u0catmiao@proton.me>
