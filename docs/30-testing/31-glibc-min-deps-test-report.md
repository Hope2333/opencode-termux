# Glibc Dependency Reduction Test Report (Termux / OpenCode)

## Background

OpenCode currently runs on Termux through a glibc-based runtime path. Historically, installing `opencode` through local DEB packaging pulled in `glibc-runner`, which cascaded into many glibc-related packages.

This test aimed to identify the **minimum package set required for OpenCode networking** while keeping the current glibc runtime path (no musl/proot migration).

## Scope and Host

- Host: clean Termux apt environment (`192.168.1.22:8022`)
- Test package: `opencode_1.2.10_aarch64.deb`
- Primary functional check:
  - `opencode run "hi"` (user-provided target behavior)
- Supplementary checks used during staged verification:
  - `opencode --version`

> **Important scope note**: This report validates a networking-oriented execution path. It does **not** prove all OpenCode features (TUI/web/plugins/PTY/file-watchers) work with the same reduced dependency set.

## Original State

Installing `opencode` (with `glibc-runner` as hard dependency) in a clean Termux apt environment resulted in approximately **52 glibc-related packages** being installed.

## Method

Dependency subtraction was performed by forcibly removing packages step-by-step and re-running OpenCode checks:

- package removal tools used:
  - `dpkg -r --force-depends ...`
  - `dpkg -r --force-remove-essential --force-depends ...` (for essential-tagged glibc helper packages)
- functionality checks after each stage:
  - `opencode --version`
  - networking behavior target (`opencode run "hi"`) in the dedicated network-focused run

Warnings and package-manager consistency breakage were tolerated during the experiment. The focus was only on whether the OpenCode functionality under test still worked.

## Results Summary

| Stage | Approx. package count | Result |
|---|---:|---|
| Initial install (glibc-runner dependency path) | 52 | Pass |
| Remove recommended helpers | lower | Pass |
| Remove `glibc-runner` | lower | Pass |
| Remove helper glibc tools (`patchelf/binutils/strace`, etc.) | lower | Pass |
| Remove `bash-glibc` | lower | Pass |
| Remove `termux-exec-glibc` | lower | Pass |
| Remove `glibc` | N/A | **Fail** (`error: open ld.so failed`) |

## Final Confirmed Minimum (for tested networking path)

### Hard dependencies (validated)

- `glibc`
- `openssl-glibc`

These two packages were sufficient for the tested OpenCode networking path to continue working.

## Packages Confirmed Removable (for tested networking path)

The following were observed to be non-essential for the tested networking behavior and/or `opencode --version` path:

- `glibc-runner`
- `termux-exec-glibc`
- `bash-glibc`
- `patchelf-glibc`
- `binutils-glibc`
- `strace-glibc`
- `coreutils-glibc`
- `util-linux-glibc`
- `bash-completion-glibc`
- `libcurl-glibc`
- `ca-certificates-glibc`
- `libnghttp2-glibc`
- `libidn2-glibc`
- `zlib-glibc`
- `glibc-repo`

> This list means **"removable without breaking the tested path"**, not “safe to remove for every OpenCode feature or every glibc program”.

## Packaging Policy Decision (applied)

Based on the test result, package metadata policy was changed to:

- **Hard dependency**: `glibc`
- **Optional/recommended fallback**: `glibc-runner`

Additional note from test findings:

- `openssl-glibc` is required for the tested network path and should be treated as a hard dependency in package rules.

## Caveats and Risk Boundaries

The following still require dedicated validation under the reduced dependency set:

- `opencode web`
- TUI full interactive workflows
- plugin install/update/build workflows
- PTY-heavy behavior and file watcher paths
- edge-case environment handling under Termux shell integrations

## Practical Recommendation

For production packaging today:

1. Hard-depend on:
   - `glibc`
   - `openssl-glibc`
   - `bash`
   - `ncurses`
2. Keep `glibc-runner` as optional/recommended fallback tooling for troubleshooting and compatibility.
3. Maintain a follow-up smoke matrix for TUI/web/plugin paths before attempting further aggressive dependency reductions in package metadata.
