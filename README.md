[English](./README.md) | [简体中文](./README.zh.md)

# opencode-termux

OpenCode on Termux. **Mainline = native bionic direct-run line**: a single zero-glibc
Android ELF produced by the transplant revive pipeline, shipped as formal releases
under the plain `opencode` package name. The glibc wrapper line (inherited from the
former `pure-android` line) is kept as appendix maintenance. Current branch:
`native-android` (default mainline).

---

## Native line (mainline): zero-glibc single-ELF runtime

The official prebuilt Android Bun serves as the base. We graft opencode's module graph
into the same ELF, run the revive surgery, and produce a single Bionic executable that
can be execve'd directly. Zero glibc dependencies, requires Android API >= 28.

### Highlights

- ✅ **Zero glibc**: no glibc-repo / openssl-glibc needed. The earlier "zero glibc is
  impossible" conclusion was overturned by the revive surgery — the real cause was that
  assemble never patched `BUN_COMPILED.size` in the `.bun` section. See
  `docs/transplant.md` §0.1/§0.2.
- ✅ **Fully working TUI**: a self-built bionic `libopentui.so` (NDK) is swapped in at
  equal length via `tools/transplant/swap_tui.py`. W10a deep smoke passed 5/5 (real
  chat round trip / resize / clean exit / 5min soak with RSS actually dropping).
- ✅ **Native watcher**: `tools/watcher/` provides a standalone daemon module
  (`watcher.c`, NDK inotify recursive watching) plus a plugin-side shim (`shim.js`).
  Fixes the total lack of file watching caused by upstream `@parcel/watcher` failing to
  load on Termux. E2E all three event types <100ms, kill -9 self-heal ≤612ms.
- ✅ **bin-direct packaging**: `bin/opencode` inside the package is a real executable
  ELF, no bash launcher wrapper.
- ✅ **UPX compressed variant**: the same native ELF packed with UPX `--best`, shipped
  as the `opencode-compressed` package family — 71.14% smaller at a measured startup
  cost. See [Compressed variant](#compressed-variant-opencode-compressed-native--upx).

### How it works

```
official android bun ELF          opencode module graph
        │                                │
        └───────────────┬────────────────┘
                        ▼
     tools/transplant/transplant.py  (graft + patch)
                        ▼
        revive surgery  (BUN_COMPILED.size fix)
                        ▼
   swap_tui.py: bionic libopentui.so equal-length swap
                        ▼
      single execve-able opencode ELF (~180MB)
```

### Install (mainline package: `opencode`)

The native mainline has inherited the plain `opencode` package name (the glibc wrapper
line was renamed `opencode-glibc` — see the [coexistence matrix](#package-coexistence-matrix)):

```bash
# Download from https://github.com/Hope2333/opencode-termux/releases
# ELF asset names look like opencode-1.18.21-aarch64-android-native
dpkg -i opencode_<version>_aarch64.deb
# or
pacman -U opencode-<version>-1-aarch64.pkg.tar.xz
```

```bash
opencode --version   # -> 1.18.x
opencode run "hi"
opencode             # TUI
```

### Compressed variant: `opencode-compressed` (native + UPX)

The same revived native ELF, additionally packed with UPX `--best` and shipped as the
`opencode-compressed` package family (command entry is still `opencode`):

| Stage | Size | Note |
|---|---|---|
| Unpacked native ELF | 179,807,785 B | sha256 `02609002…` (native-beta-260826 build) |
| UPX `--best` | 51,891,796 B | **-71.14%**, sha256 `30c074ab…` |
| + `xz -9` upload layer | 50,362,704 B | sha256 `42a0ef39…`; xz gains only ~3% because UPX output is already high-entropy |

- **Startup tradeoff (measured)**: UPX decompression adds ~0.7–1.1s (1.9–2.3s total vs
  ~1.1s unpacked). Choose `opencode-compressed` for download size, plain `opencode`
  for startup latency.
- **Fingerprint chain**: unpacked `02609002…` → UPX `30c074ab…` → xz `42a0ef39…`
  (sha256 prefixes; full hashes in the release notes and `SHA256SUMS.txt`).
- **AV false-positive notice**: UPX-packed executables are a known antivirus
  false-positive trigger. Verify downloads against `SHA256SUMS.txt` before use.
- First shipped together in the **Push260828** release (four package families'
  first co-appearance): ELF assets `opencode-1.18.21-aarch64-android-native-tui-upx`
  (+ `.xz`), packages `opencode-compressed_1.18.21_aarch64.deb` /
  `opencode-compressed-1.18.21-1-aarch64.pkg.tar.xz`, plus `SHA256SUMS.txt`.

```bash
dpkg -i opencode-compressed_<version>_aarch64.deb
# or
pacman -U opencode-compressed-<version>-1-aarch64.pkg.tar.xz
```

### Package coexistence matrix

| Package | Line | Command entry | Coexistence |
|---|---|---|---|
| `opencode` | native bionic (mainline) | `opencode` | mutually exclusive with `opencode-glibc` and `opencode-compressed` |
| `opencode-compressed` | native bionic + UPX | `opencode` | mutually exclusive with `opencode` and `opencode-glibc` |
| `opencode-glibc` | glibc wrapper (appendix) | `opencode` | mutually exclusive with `opencode` and `opencode-compressed` |
| `opencode-glibc-standalone` | glibc wrapper, frozen single version | `opencode-glibc` | **coexists with `opencode`**; rollback only |

The three `opencode`-entry packages replace each other via the package manager's
conflict mechanism; the standalone package uses an independent lib path and a distinct
command name so it can sit alongside the native mainline as a frozen rollback.

### Build

One-shot pipeline:

```bash
make transplant VER=1.18.21
# extract -> detect -> convert -> patch -> assemble -> revive -> verify
# Produces a runnable opencode-native-revived directly
```

Key points:

- **All-version coverage**: 1.2.x through latest all work. Old trailer format and the
  new `.bun` section format (opencode >= 1.18, proven on 1.18.21) are auto-detected.
- **Auto revive size mode**: bases <= 1.3.x use reloc relocation writes, >= 1.4.x use
  plain-offset direct writes (auto-decided by base version since b09c28c); override
  explicitly with `--size-mode reloc|plain-offset`. Graphs in the new section format
  must use a >= 1.4 base (see `tools/transplant/config/bun-bind.json`, target=1.4.0).
- **TUI injection**: the pipeline includes a swap_tui step that swaps in the bionic
  libopentui.so at equal length.
- **Golden regression**: `make transplant-check` (golden-file regression; fixtures
  need `scripts/fetch-fixtures.sh` pre-downloaded first).

### Dependencies

| Tool | Required? | Purpose |
|---|---|---|
| python3 | ✅ | Pipeline itself, runs on stdlib alone |
| NDK | Only for self-built components | Building bionic libopentui.so / watcher.c |
| gh / npm / curl | ✅ | Fetching the Bun base, opencode packages and fixtures |

### CI and verification boundary

`.github/workflows/build-native-android.yml` (workflow_dispatch manual trigger):
runs the full revive flow and golden regression on an x86 runner; artifacts are
evidence-only (CI does not execute them). **CI green ≠ runnable**: final acceptance
requires on-device verification on a real machine. Also note: isolated-HOME testing
needs a warm cache mirror, otherwise the binary hangs at startup.

### Release policy (honest notes)

> The native line is the stable mainline release channel. Performance reality
> (measured, not marketing): startup ~1s magnitude (`--version` first try 1965ms =
> Phase B bootstrap ~220ms + Phase C JS evaluation ~820ms; the <300ms goal needs
> upstream Bun changes and is unreachable today), size ~180MB unpacked / ~50MB
> UPX-packed.

For the full surgery principles, config schema, failure playbooks and FAQ see
`docs/transplant.md`; for a comparison of the runtime lines see
`docs/comparison-runtime-lines.md`.

---

## Branch topology

| Branch | Role |
|---|---|
| `native-android` | **Default mainline** — native bionic line (this branch) |
| `glibc` | glibc wrapper line, appendix maintenance (renamed from `pure-android`) |
| `archive/glibc-classic` | legacy glibc line, archived |

---

## Appendix: glibc wrapper line (inherited from the pure-android line)

The bun-termux-loader wrapping approach: upstream `opencode-linux-arm64` is a
glibc-linked Bun single-file app (Bun runtime + JS compiled into one ELF). The loader
prepends a ~12KB Bionic wrapper ELF: it reads `/proc/self/exe` to locate BUNWRAP1
metadata, extracts the embedded opencode binary, then mmaps glibc's ld.so and jumps to
its entry (userland exec, no execve), keeping `/proc/self/exe` pointing at itself so
Bun's JS location stays intact.

### Dependencies

| Package | Required? | Why |
|---|---|---|
| `glibc` | ✅ Yes | OpenCode binary is glibc-linked; wrapper loads it via glibc's ld.so |
| `openssl-glibc` | ✅ Yes | HTTPS/TLS for API calls |
| `bash` | ✅ Yes | Launcher script |
| `ncurses` | ✅ Yes | TUI support |

### Install

```bash
# Path A: apt/pkg
apt install -y glibc-repo
apt update
apt install -y glibc openssl-glibc
dpkg -i opencode-glibc_<version>_aarch64.deb

# Path B: pacman
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U opencode-glibc-<version>-1-aarch64.pkg.tar.xz
```

Rollback package (coexists with the native `opencode`, command entry `opencode-glibc`,
single frozen version):

```bash
dpkg -i opencode-glibc-standalone_<version>_aarch64.deb
# or
pacman -U opencode-glibc-standalone-<version>-1-aarch64.pkg.tar.xz
```

### Build

```bash
# Single version
make all VER=1.17.3 PKG=both

# Batch build
make batch VERS='1.17.[0-3]' PKG=both ODIR=~/oct-out MIX=1

# Flow: clean -> runtime(produce-local.sh: npm download + loader wrap)
#      -> stage(scripts/build.sh) -> deb -> pacman
```

### CI

`.github/workflows/build-pure-android.yml`: workflow_dispatch manual trigger,
QEMU aarch64 binary handling, npm download of opencode-linux-arm64 wrapped with the
prebuilt wrapper+shim (`tools/prebuilt/`), artifact upload plus status JSON.

> amd64 (x64) + Android + Termux has almost no real users; this project ships no x64
> assets. armv7's 32-bit dependency chain is badly broken with prohibitive fix costs;
> that experiment is abandoned.

### Launcher safeguards

- TTY cleanup on exit (soft/hard depending on exit code)
- Stale lock cleanup (`*.lock` under `$XDG_STATE_HOME`)
- `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` by default

---

## Repository layout

```
.github/workflows/
  build-native-android.yml    Native line CI (evidence-only artifact)
  build-pure-android.yml      glibc line CI (aarch64)
tools/
  transplant/                 Native revive pipeline (transplant.py / revive_patch.py /
                              swap_tui.py / config/bun-bind.json)
  watcher/                    Native inotify watcher daemon + shim plugin bridge
  produce-local.sh            glibc line: npm download + loader wrap
  prebuilt/                   Prebuilt aarch64 wrapper+shim for glibc line CI
scripts/
  fetch-fixtures.sh           transplant-check golden fixtures pre-download
  build.sh                    Stage prefix (glibc line; STANDALONE=1 for rollback pkg)
  launcher.sh                 Runtime dispatcher (cleanup + exec)
  package/package_deb.sh      DEB builder (opencode-glibc)
  package/package_pacman.sh   Pacman builder (opencode-glibc)
  package/package_deb_native.sh        DEB builder (native opencode)
  package/package_pacman_native.sh     Pacman builder (native opencode)
  package/package_deb_compressed.sh    DEB builder (opencode-compressed)
  package/package_pacman_compressed.sh Pacman builder (opencode-compressed)
  package/package_deb_standalone.sh    DEB builder (opencode-glibc-standalone)
  package/package_pacman_standalone.sh Pacman builder (opencode-glibc-standalone)
  hooks/run-system-skills.sh  Post-install/upgrade hooks
patches/
  0001-android-support.patch  Upstream OpenCode Android patches (WIP)
docs/
  transplant.md               Authoritative native-line surgery doc
  comparison-runtime-lines.md Comparison of the runtime lines
  dual-track-install.md       Provider choice across the package families
  native-android-research.md  Zero-glibc research history
```

## Related

- OpenCode upstream: <https://github.com/anomalyco/opencode>
- bun-termux-loader: <https://github.com/Hope2333/bun-termux-loader>
- Android-native Bun: <https://github.com/Hope2333/bun-termux>
- Upstream Bun (Android builds): <https://github.com/oven-sh/bun>
- Releases: <https://github.com/Hope2333/opencode-termux/releases>

## Metadata

Maintainer: `Hope2333(幽零小喵) <u0catmiao@proton.me>`
