# opencode-termux — pure-android branch

**This is the current mainline branch.** It produces OpenCode packages using
bun-termux-loader to wrap the upstream `opencode-linux-arm64` binary for
Android/Bionic. glibc is required at runtime (the wrapper loads it via
userland exec).

**Looking for the legacy branch?** See the `glibc-legacy` branch (same approach,
older version).

---

## Dependencies

| Package | Required? | Why |
|---------|-----------|-----|
| `glibc` | ✅ Yes | OpenCode binary is glibc-linked; wrapper loads it via glibc's ld.so |
| `openssl-glibc` | ✅ Yes | HTTPS/TLS for API calls |
| `bash` | ✅ Yes | Launcher script |
| `ncurses` | ✅ Yes | TUI support |

```bash
# Install dependencies
apt install -y glibc-repo
apt update
apt install -y glibc openssl-glibc

# Then install opencode
apt install -y /path/to/opencode_<version>_aarch64.deb
```

### Path B: pacman (secondary)

```bash
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U /path/to/opencode-<version>-aarch64.pkg.tar.xz
```

### Optional: Android-native Bun

```bash
# From the bun-termux repo (pure-android branch)
# Provides: bun -- JavaScript runtime, 0 glibc
# Repo: https://github.com/Hope2333/bun-termux
```

---

## What this branch provides

- ✅ **Real OpenCode AI** (`opencode --version` → `1.15.x`)
- ✅ deb + pacman package output
- ✅ Plugin lifecycle system (install/update/rollback)
- ✅ TTY/signal cleanup launcher
- ✅ System-skill hooks (post-install/upgrade/remove)
- ✅ CI workflow for automated builds
- ✅ Batch build (`make batch VERS='1.15.[1-7]'`)
- ✅ Release upload automation (`make release-upload`)

---

## How it works

The upstream OpenCode binary (`opencode-linux-arm64` from npm) is a
**glibc-linked Bun-compiled application**. It contains the Bun runtime +
OpenCode JS code compiled into a single ELF executable.

To make it run on Android/Bionic, **bun-termux-loader** prepends a thin
Bionic wrapper:

```
┌──────────────────────────────────────────────┐
│ Bionic wrapper ELF (~12KB)                   │
│   - Reads /proc/self/exe                     │
│   - Finds BUNWRAP1 metadata                  │
│   - Extracts embedded OpenCode binary        │
│   - Userland exec via glibc's ld.so          │
├──────────────────────────────────────────────┤
│ BUNWRAP1 metadata                            │
├──────────────────────────────────────────────┤
│ Original opencode binary (glibc Bun + JS)    │
│   - Interpreter: /lib/ld-linux-aarch64.so.1  │
│   - Entry: compiled-app mode (RX seg base)   │
│   - ---- Bun! ---- marker + JS bytecode      │
└──────────────────────────────────────────────┘
```

**Userland exec**: Instead of `execve()` (which would update `/proc/self/exe`
and break Bun's JS location), the wrapper mmap()s glibc's `ld.so` and jumps
to its entry point, keeping `/proc/self/exe` pointing to itself.

---

## Constraints (zero-glibc attempts)

We invested significant research into removing the glibc dependency.
Here's what we tried and why it didn't work:

| Approach | Result | Root Cause |
|----------|--------|------------|
| **Android Bun as runtime** (v1.3.14 Bionic binary) | ❌ | `bun build --compile` fails on Termux (`/data/` permission) |
| **JS bundle from source** (`bun build --target=bun`) | ❌ | Native modules (`@opentui/solid`) require `--compile` |
| **Runtime swap** (replace glibc Bun with Android Bun) | ❌ | Android Bun lacks compiled-app entry point code (ELF entry at 0x1f00200, not segment base) |
| **Binary surgery** (patch ELF entry + swap) | ❌ | Missing Zig/C++ level "load embedded JS" code in Android Bun |
| **Fork Bun + add android target** | ⏳ | Requires modifying Bun's Zig/C++ build system + WebKit |

**Current path**: bun-termux-loader wrapping. Production-stable, works today.
The glibc dependency is standard on Termux (`apt install glibc`).

**Future**: When upstream Bun supports `--target=bun-linux-aarch64-android`,
we can switch to native Android Bun as the runtime and eliminate glibc.

See `docs/native-android-research.md` for full research details.

---

## Install

```bash
# Path A: apt/pkg (recommended)
apt install -y glibc-repo
apt update
apt install -y glibc openssl-glibc
apt install -y /path/to/opencode_<version>_aarch64.deb

# Path B: pacman
pacman -Syu
pacman -S glibc openssl-glibc
pacman -U /path/to/opencode-<version>-aarch64.pkg.tar.xz
```

Releases: https://github.com/Hope2333/opencode-termux/releases

---

## Usage

```bash
opencode --version          # → 1.15.7
opencode run "hi"           # OpenCode AI chat
opencode run --mode=dev .   # development mode
opencode serve              # API server mode
opencode web                # web interface
```

---

## Build

### Local build (Termux)

```bash
# Single version
make all VER=1.15.7 PKG=both

# Batch build (1.15.1 through 1.15.7)
make batch VERS='1.15.[1-7]' PKG=both ODIR=~/oct-out MIX=1
```

### Build + release upload

```bash
# Hidden target (not in help):
make release-upload TAG=Push260522 VERS='1.15.[1-7]'
# Defaults: TAG=Push<YYMMDD>, REPO=Hope2333/opencode-termux, PKG=both
```

### Build flow

```
make all VER=1.15.7 PKG=both
  → clean (rm -rf artifacts/staged, packaging work dirs)
  → runtime (tools/produce-local.sh: npm download + bun-termux-loader wrap)
  → stage (scripts/build.sh: copy to prefix tree)
  → deb (scripts/package/package_deb.sh)
  → pacman (scripts/package/package_pacman.sh)
```

---

## CI Pipeline

Workflow: `.github/workflows/build-pure-android.yml`

```
workflow_dispatch (manual, with version input)
  ↓ Install Bun (Linux) for optional bundle build
  ↓ Clone upstream source + apply patches (WIP)
  ↓ QEMU aarch64 emulation for binary handling
  ↓ Download opencode-linux-arm64 from npm
  ↓ Wrap with bun-termux-loader (pre-built aarch64 wrapper+shim)
  ↓ Create bundle + upload artifact + write status JSON
```

Matrix builds for: `aarch64`, `x64`

---

## Repository layout

```
.github/workflows/
  build-pure-android.yml      CI automated build pipeline
tools/
  produce-local.sh            Download from npm + wrap
  prebuilt/                   Pre-built aarch64 wrapper+shim for CI
scripts/
  build.sh                    Stage prefix
  launcher.sh                 Runtime dispatcher (cleanup + exec)
  package/package_deb.sh      DEB builder
  package/package_pacman.sh   Pacman builder
  hooks/run-system-skills.sh  Post-install/upgrade hooks
patches/
  0001-android-support.patch   Upstream OpenCode Android patches (WIP)
docs/
  native-android-research.md  Research: zero-glibc approaches
```

## Launcher safeguards

- TTY cleanup on exit (soft/hard depending on exit code)
- Stale lock cleanup (`*.lock` in `$XDG_STATE_HOME`)
- `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` (default)

## Metadata

Maintainer: `Hope2333(幽零小喵) <u0catmiao@proton.me>`

## Related

- OpenCode upstream: <https://github.com/anomalyco/opencode>
- bun-termux-loader: <https://github.com/Hope2333/bun-termux-loader>
- Android-native Bun: <https://github.com/Hope2333/bun-termux> (pure-android branch)
- Upstream Bun (Android builds): <https://github.com/oven-sh/bun>
- Research doc: `docs/native-android-research.md`

---

## Why pure-Bionic OpenCode is not yet possible

This branch's name (`pure-android`) reflects its **goal**, not its current
state. The obstacles preventing a truly glibc-free OpenCode are:

### 1. Compilation: `bun build --compile` is blocked on Android

Bun's `--compile` flag scans the filesystem from `/` to resolve imports and
native modules. On Android, `/data/` is permission-restricted (`AccessDenied`),
causing all `bun build` operations (with or without `--compile`) to fail.
There is no known workaround — it's hardcoded in Bun's Zig source.

```bash
bun build ./src/index.ts            # ❌ Cannot read directory "/data/": AccessDenied
bun build --compile ./src/index.ts  # ❌ same
```

### 2. Android Bun has no "compiled app" entry point

The Android Bun binary (v1.3.14) is a **pure interpreter** — it starts as
`bun`, not as a Bun-compiled application. The ELF entry point is at offset
`0x1f00200` (interpreter mode) instead of the RX segment base (compiled-app
mode). The compiled-app startup code (`mov x5, x0; ldr x1, [sp]` pattern)
does **not exist** in the binary. Simply concatenating Android Bun + JS
payload produces a binary that runs as `bun --help`, not as OpenCode.

### 3. JS bytecode is not portable

The JS extracted from the upstream binary is **compiled bytecode**, not
TypeScript source. It cannot be run with `bun run` — it requires the
`bun build --compile` loading path, which only exists in binaries produced
by that process.

### 4. Native modules lack Bionic builds

OpenCode depends on `@opentui/solid` (TUI framework) and `@parcel/watcher`
(file watcher). These ship with glibc `.so` files. Bionic-compiled versions
do not exist publicly.

### 5. Upstream Bun has no Android compile target

```bash
bun build --compile --target=bun-linux-arm64           # ✅ works (produces glibc binary)
bun build --compile --target=bun-linux-aarch64-android # ❌ does not exist
```

There is no `--target` for Android in Bun's build system. Adding it requires
changes to Bun's Zig/C++ source code and WebKit/JavaScriptCore integration.

---

## This branch's commitment

This branch exists specifically to **track and resolve** these obstacles.
The path forward:

| Timeline | Milestone |
|----------|-----------|
| **Now** | bun-termux-loader wrapping (works, needs glibc) |
| **Short-term** | Fork Bun, patch `/data/` scan, add Android compile target |
| **Medium-term** | Build Android-native OpenCode on CI with forked Bun |
| **Goal** | `opencode` → runs on Termux, **zero glibc**, single Bionic binary |

Every constraint documented here has a corresponding issue or experiment in
the repo. When upstream Bun or OpenCode removes any of these blockers, this
branch will switch immediately.

**This is not a dead end. It's a work in progress.**

