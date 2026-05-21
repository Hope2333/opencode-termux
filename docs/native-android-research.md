# Native Android Bun Research

**Date:** 2026-05-15  
**Branch:** `native-android`  
**Status:** Research complete, feasibility confirmed with caveats

## Summary

Bun v1.3.14 (released 2026-05-13) adds **native Android builds** — Bionic-linked ARM64 binaries
that run directly on Android without glibc, wrappers, or shims. This doc evaluates the viability
of using this binary as the OpenCode runtime on Termux.

## Key Findings

### ✅ What Works

- **Android Bun binary runs on Termux natively**
  - ELF: `ARM aarch64, /system/bin/linker64, Android 28, NDK r27c`
  - `bun run <absolute-path>` works correctly
  - `bun --cwd <dir> -e 'code'` works correctly
  - Binary size: 86 MB (vs 144 MB glibc Bun)

- **JS payload extraction possible**
  - `opencode-linux-arm64` from npm has structure:
    ```
    [glibc Bun runtime 144 MB] [---- Bun! ---- marker] [JS bytecode 44 KB]
    ```
  - JS payload can be reliably extracted by scanning for marker

- **Runtime swap produces valid ELF**
  - Concatenating Android Bun + JS payload creates a valid Android PIE binary
  - No `SIGSYS` crash, no glibc dependency, no statx shim needed

### ❌ What Doesn't Work

- **`bun build --compile` on Android**
  - Fails with `Cannot read directory "/data/": AccessDenied`
  - Same Android permission issue that affects all filesystem-scanning operations
  - No workaround found (`--cwd` doesn't help)

- **Simple runtime swap doesn't produce working compiled app**
  - The resulting binary runs as `bun` interpreter, not as OpenCode
  - Shows `bun --version` (1.3.14) instead of `opencode --version` (1.15.0)
  - Shows `bun --help` instead of OpenCode help

- **Compiled-app entry code is NOT present in Android Bun binary**
  - The `bun` binary from GitHub release is the interpreter runtime only
  - Compiled-app entry code is added by `bun build --compile` on the build machine
  - This code does not exist in the distributed Android Bun binary

### Root Cause

`bun build --compile` does two things:
1. Appends JS bytecode + marker to a copy of the Bun runtime binary
2. **Modifies the ELF entry point** to a "compiled app mode" function that:
   - Reads `/proc/self/exe`
   - Scans for the `---- Bun! ----` marker
   - Loads and executes the embedded JS

The Android Bun binary has entry point `0x1f00200` (interpreter mode).
A compiled app has entry at the **start of the RX segment** (offset `0x0`).

Without this ELF entry point modification, the binary always acts as the Bun interpreter.

## Binary Structure Comparison

| Property | `bun-linux-aarch64` (glibc) | `bun-linux-aarch64-android` (bionic) |
|----------|---------------------------|-------------------------------------|
| ELF type | EXEC | DYN (PIE) |
| Interpreter | `/lib/ld-linux-aarch64.so.1` | `/system/bin/linker64` |
| Entry point | 0x2a7d200 (app mode) | 0x1f00200 (interpreter) |
| Segment base | 0x2a7d200 | 0x0 |
| Entry offset in segment | 0x0 (app mode) | 0x1f00200 (interpreter) |
| Size | 144 MB | 86 MB |
| `---- Bun! ----` marker | Yes (end of file) | Yes (embedded in code) |

## Evaluated Approaches

### Approach A: Runtime Swap in Wrapper (FAILED)
- Swap glibc Bun → Android Bun inside bun-termux-loader
- Wrapper extracts and `exec()`s the Android Bun
- **Problem**: Entry point is interpreter mode, not app mode
- **Verdict**: Not viable without entry point modification

### Approach B: ELF Entry Point Patch (FAILED)
- Find compiled-app entry function in Android Bun
- Modify ELF header to point to it
- **Problem**: The compiled-app entry code does NOT exist in the Android Bun binary
- Android Bun is built as a pure runtime, not as a `bun build --compile` output
- **Verdict**: Not viable without access to `bun build --compile`

### Approach C: Cross-Compile on Linux (VIABLE)
- Use GitHub Actions (Linux) to produce compiled binaries
- Download Android Bun as the build environment
- Run `bun build --compile OpenCodeSource` on Linux
- The output embeds the correct entry point
- Use bun-termux-loader wrapping for final Android binary (current flow)
- **Verdict**: Only viable path; implements existing flow + simpler artifact distribution

## Entry Point Analysis Details

```python
# Android Bun interpreter entry at 0x1f00200:
9f2403d5  # unknown instruction (interpreter-specific)
1d0080d2  # mov x29, #0
1e0080d2  # mov x30, #0
e0030091  # mov x0, sp

# Compiled-app entry (from opencode binary) at segment base:
1d0080d2  # mov x29, #0
1e0080d2  # mov x30, #0
e50300aa  # mov x5, x0   ← app-specific: preserves argc pointer
e10340f9  # ldr x1, [sp] ← app-specific: loads argc from stack
```

The distinguishing app-mode instructions `e50300aae10340f9` (`mov x5, x0; ldr x1, [sp]`)
were searched for in the Android Bun binary and **not found**, confirming the
compiled-app startup code is absent.

## Recommendation

1. **Short term**: Keep current bun-termux-loader wrapping approach
2. **Medium term**: Use GitHub Actions to automate the wrapping pipeline
   (Linux Bun can run `bun build --compile` without Android permission issues)
3. **Long term**: Watch for upstream OpenCode Android builds once Bun's
   Android target matures

The `native-android` branch can be used to track Android Bun version updates
and test new releases as they come.
