[English](./README.md) | [简体中文](./README.zh.md)

# opencode-termux

OpenCode on Termux with two runtime lines: **native bionic direct-run line (primary) + glibc wrapper line (stable appendix)**.
Current branch: `native-android`.

> **Upcoming package rename (transition notice):** The current glibc `opencode` package will be renamed to `opencode-glibc`. The native bionic line will inherit the plain `opencode` name and become the stable channel around Push 27/28 (dates approximate). During the transition both packages may be installed side-by-side. Watch the [releases page](https://github.com/Hope2333/opencode-termux/releases) for the switchover.

---

## Native line (primary): zero-glibc native Android runtime

The official prebuilt Android Bun serves as the base. We graft opencode's module graph into the same ELF,
run the revive surgery, and produce a single Bionic executable that can be execve'd directly.
Zero glibc dependencies, requires Android API >= 28.

### Highlights

- **Zero glibc**: no glibc-repo / openssl-glibc needed. The earlier "zero glibc is impossible" conclusion was overturned by the revive surgery. The real cause was that assemble never patched `BUN_COMPILED.size` in the `.bun` section (the standalone detection chain is fully present in android bun). See `docs/transplant.md` §0.1/§0.2.
- **Fully working TUI**: a self-built bionic `libopentui.so` (NDK) is swapped in at equal length via `tools/transplant/swap_tui.py`, giving complete TUI rendering. W10a deep smoke passed 5/5 (real chat round trip / resize / clean exit / 5min soak with RSS actually dropping).
- **Native watcher**: `tools/watcher/` provides a standalone daemon module (`watcher.c`, NDK inotify recursive watching) plus a plugin-side shim (`shim.js`) and `install.sh`. It fixes the total lack of file watching caused by upstream `@parcel/watcher` failing to load on Termux. E2E all three event types <100ms, kill -9 self-heal ≤612ms.
- **bin-direct packaging**: `bin/opencode` inside the package is a real executable ELF, no bash launcher wrapper.

### Quick start (beta pre-release)

Native assets ship on a long-term BETA pre-release channel (`native-beta-*` tags);
first beta tag: `native-beta-260826`, includes the crashfix (commit 342d68d):

```bash
# Download from https://github.com/Hope2333/opencode-termux/releases/tag/native-beta-260826
# (and later native-beta-* tags). Asset names look like opencode-1.18.21-aarch64-android-native-tui
dpkg -i opencode-native_<version>_aarch64.deb
# or
pacman -U opencode-native-<version>-1-aarch64.pkg.tar.xz
```

Installing `opencode-native` replaces the glibc line's `opencode` provider (and vice versa).
Provider selection details: `docs/dual-track-install.md`.

```bash
opencode --version   # -> 1.18.x
opencode run "hi"
opencode             # TUI
```

### Build

One-shot pipeline:

```bash
make transplant VER=1.18.21
# extract -> detect -> convert -> patch -> assemble -> revive -> verify
# Produces a runnable opencode-native-revived directly
```

Key points:

- **All-version coverage**: 1.2.x through latest all work. Old trailer format and the new `.bun` section format (opencode >= 1.18, proven on 1.18.21) are auto-detected.
- **Auto revive size mode**: bases <= 1.3.x use reloc relocation writes, >= 1.4.x use plain-offset direct writes (auto-decided by base version since b09c28c); override explicitly with `--size-mode reloc|plain-offset`. Graphs in the new section format must use a >= 1.4 base (see `tools/transplant/config/bun-bind.json`, target=1.4.0).
- **TUI injection**: the pipeline includes a swap_tui step that swaps in the bionic libopentui.so at equal length.
- **Golden regression**: `make transplant-check` (golden-file regression; fixtures need `scripts/fetch-fixtures.sh` pre-downloaded first).

### Dependencies

| Tool | Required? | Purpose |
|---|---|---|
| python3 | ✅ | Pipeline itself, runs on stdlib alone |
| NDK | Only for self-built components | Building bionic libopentui.so / watcher.c |
| gh / npm / curl | ✅ | Fetching the Bun base, opencode packages and fixtures |

### CI and verification boundary

`.github/workflows/build-native-android.yml` (workflow_dispatch manual trigger):
runs the full revive flow and golden regression on an x86 runner; artifacts are evidence-only (CI does not execute them). **CI green ≠ runnable**: final acceptance requires on-device verification on a real machine. Also note: isolated-HOME testing needs a warm cache mirror, otherwise the binary hangs at startup.

### Release policy (honest notes)

> **Native line assets stay on the long-term BETA pre-release channel** (`native-beta-*` tags);
> stable maintenance remains carried by the pure/glibc dual-track packages.
>
> Performance reality (measured, not marketing): startup ~1s magnitude (`--version` first try 1965ms =
> Phase B bootstrap ~220ms + Phase C JS evaluation ~820ms; the <300ms goal needs upstream Bun changes and is unreachable today), size ~180MB.

For the full surgery principles, config schema, failure playbooks and FAQ see `docs/transplant.md`;
for a comparison of the three runtime lines see `docs/comparison-runtime-lines.md`.

---

## Appendix: glibc/pure line (stable dual-track packages)

The bun-termux-loader wrapping approach: upstream `opencode-linux-arm64` is a glibc-linked
Bun single-file app (Bun runtime + JS compiled into one ELF). The loader prepends a
~12KB Bionic wrapper ELF: it reads `/proc/self/exe` to locate BUNWRAP1 metadata,
extracts the embedded opencode binary, then mmaps glibc's ld.so and jumps to its entry
(userland exec, no execve), keeping `/proc/self/exe` pointing at itself so Bun's JS
location stays intact. Legacy maintenance branch: `glibc`.

### Dependencies

| Package | Required? | Why |
|---------|-----------|-----|
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
dpkg -i /path/to/opencode_<version>_aarch64.deb

# Path B: pacman
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U /path/to/opencode-<version>-aarch64.pkg.tar.xz
```

### Build

```bash
# Single version
make all VER=1.17.3 PKG=both

# Batch build
make batch VERS='1.17.[0-3]' PKG=both ODIR=~/oct-out MIX=1

# Flow: clean -> runtime(produce-local.sh: npm download + loader wrap)
#      -> stage(scripts/build.sh) -> deb -> pacman

# Hidden target: release-upload (defaults TAG=Push<YYMMDD>, REPO=Hope2333/opencode-termux, PKG=both)
make release-upload TAG=Push260522 VERS='1.17.[0-3]'
```

### CI

`.github/workflows/build-pure-android.yml`: workflow_dispatch manual trigger,
QEMU aarch64 binary handling, npm download of opencode-linux-arm64 wrapped with the
prebuilt wrapper+shim (`tools/prebuilt/`), artifact upload plus status JSON.

> amd64 (x64) + Android + Termux has almost no real users; this project ships no x64 assets.
> armv7's 32-bit dependency chain is badly broken with prohibitive fix costs; that experiment is abandoned.

### Launcher safeguards

- TTY cleanup on exit (soft/hard depending on exit code)
- Stale lock cleanup (`*.lock` under `$XDG_STATE_HOME`)
- `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` by default

### Zero-glibc constraints history (historical record)

The early Constraints table concluding "zero glibc impossible" has been partially overturned
by the transplant revive surgery (the real cause behind "runtime swap / binary surgery infeasible"
was the missing `BUN_COMPILED.size` patch). Still-valid constraints: on Android,
`bun build --compile` is hard-blocked by Zig source code scanning `/data/` permissions;
upstream Bun still has no `--target=bun-linux-aarch64-android`.
Full falsification and overturn records: `docs/transplant.md` and `docs/native-android-research.md`.

---

## Repository layout

```
.github/workflows/
  build-native-android.yml    Native line CI (evidence-only artifact)
  build-pure-android.yml      glibc line CI (aarch64)
  prebuild-armv7.yml          armv7 prebuild handoff (shelved)
tools/
  transplant/                 Native revive pipeline (transplant.py / revive_patch.py /
                              swap_tui.py / config/bun-bind.json)
  watcher/                    Native inotify watcher daemon + shim plugin bridge
  produce-local.sh            glibc line: npm download + loader wrap
  prebuilt/                   Prebuilt aarch64 wrapper+shim for glibc line CI
scripts/
  fetch-fixtures.sh           transplant-check golden fixtures pre-download
  build.sh                    Stage prefix (glibc line)
  launcher.sh                 Runtime dispatcher (cleanup + exec)
  package/package_deb.sh      DEB builder
  package/package_pacman.sh   Pacman builder
  hooks/run-system-skills.sh  Post-install/upgrade hooks
patches/
  0001-android-support.patch  Upstream OpenCode Android patches (WIP)
docs/
  transplant.md               Authoritative native-line surgery doc
  comparison-runtime-lines.md Comparison of the three runtime lines
  dual-track-install.md       Provider choice (opencode vs opencode-native)
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
