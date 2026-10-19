# Upstream issue draft — opencode TUI startup SIGSEGV on old kernels (< 4.x), releases >= 1.18.35

> **Draft status**: prepared by the `opencode-termux` downstream packaging project from
> on-device measurements. **Not yet submitted upstream — submission is a separate decision
> (pending).** Every claim below is traceable to a cited test record (see Evidence index);
> anything without measurement support is explicitly marked "not yet measured".
> Internal code names are avoided: "device A" is the old-kernel test phone, "device B" the
> new-kernel control phone; "grafted build" refers to our byte-level renderer swap.

## Suggested title

```
opencode >= 1.18.35: TUI crashes with SIGSEGV at startup on kernels < 4.x
(tested aarch64 / kernel 3.18) — bisected to the embedded OpenTUI 0.5.10 -> 0.5.14+ bump
```

## Body

### Summary

On an aarch64 Android 9 device running kernel `3.18.140-mokee`, every opencode release from
**1.18.35 onward crashes with SIGSEGV (exit 139) within seconds of starting the interactive
TUI**, while 1.18.34 and older start and render normally. The same binaries run fine on a
kernel 6.6.118 device. Key properties of the bug:

- The fault is **specific to the TUI render path**: `--version`, `--help`, and CLI/`serve`
  mode are unaffected on the same device.
- The crash is **timing-sensitive**: attaching `strace` makes it disappear (Heisenbug), yet
  it reproduces 5/5 runs uninstrumented.
- It **correlates exactly with the embedded OpenTUI renderer library changing generation**
  (0.5.10 in 1.18.34 -> 0.5.14+ from 1.18.35 on). The embedded Bun runtime itself is healthy
  on this kernel (bare Bun smoke tests pass on the same device).

This affects real hardware: kernel 3.18 devices (the Android 9 era, still common on older
phones running custom ROMs) get a hard crash instead of a usable TUI from 1.18.35 onward.

### Environment

| | Device A — crashes | Device B — control |
|---|---|---|
| OS / libc | Android 9 (bionic) | Android 15 (bionic) |
| Arch | aarch64 | aarch64 |
| Kernel | `3.18.140-mokee` | `6.6.118-android15` |
| Runtime env | Termux | Termux |
| TUI result | SIGSEGV, rc=139, 5/5 | renders normally, rc=124 at the 10 s timeout, 5/5 |

Only kernels 3.18 and 6.6 were measured; the 4.x boundary is **not yet measured**.

### Reproduction

Requirements: aarch64, kernel < 4.x (tested `3.18.140-mokee`), opencode >= 1.18.35
(tested 1.19.3; the 1.18.35, 1.19.x and 2.0.x lines fail identically).

```sh
# Run under a real pty. With GNU timeout: rc=124 = process still alive at 10 s
# (healthy TUI); rc=139 = 128+11 = SIGSEGV.
script -qec "timeout 10 opencode" /dev/null
echo "exit=$?"        # 139 on the crashing device
```

Observed on device A: exit 139 during TUI startup (well inside the 10 s window), Bun panic
output on stderr ending with a `bun.report/...` link. Repeat 5x — single runs are not
conclusive for a timing-sensitive bug, but the uninstrumented crash rate is 5/5.

Control on device B (kernel 6.6.118): identical command and build exit 124 at the 10 s
timeout with a fully rendered TUI.

### Version matrix (measured; 5 consecutive pty runs per version on device A)

| opencode | embedded OpenTUI | Result | Evidence (file + data) |
|---|---|---|---|
| 1.18.32 | <= 0.5.10 (inferred from the 1.18.34 -> 1.18.35 jump; not individually measured) | **PASS** — rc=124 x5/5 | session record 2026-10-18: `1.18.32=5/5 rc124 PASS` [E1] |
| 1.18.34 | 0.5.10 (`libopentui.so`, 5,495,136 B, SONAME `libopentui.so`, NDK r29 / Android 24) | **PASS** — rc=124 x5/5 | task-1 record: `1.18.34=rc124 x5` [E2]; initial 3/3 in [E1] |
| 1.18.35 | 0.5.14+ (render-library generation jump at this release) | **FAIL** — rc=139 (SIGSEGV) x5/5 | session record: `1.18.35=5/5 rc139 FAIL` [E1]; ledger OSC-001 `first_bad=1.18.35` [E6] |
| 1.19.x (tested 1.19.3) | 0.5.14+ (bunfs slot 6,037,032 B) | **FAIL** — rc=139 x5/5 | task-1 record: `pure 1.19.3=rc139 x5` [E2]; `1.19.x=5/5 rc139` [E1] |
| 2.0.x (v2 generation) | not yet measured | **FAIL** — rc=139 x5/5 | session record: `v2.0.x=5/5 rc139 FAIL` [E1] (exact patch build not pinned — see pending) |

Bisection result: **first_bad = 1.18.35, last_good = 1.18.34** [E6]. Intermediate versions
(1.18.33, 1.19.0–1.19.2) were not individually run.

### Excluded causes

1. **JIT**: `BUN_JSC_useJIT=0` does not avoid the crash [E1].
2. **Packing / UPX compression**: the uncompressed native build and the UPX-compressed build
   crash identically — compression is not the differentiator [E1].
3. **Bun runtime base**: bare Bun smoke tests (console output, event loop, fetch, Worker)
   pass on the same device — the embedded runtime is healthy on this kernel [E1]. The crash
   record identifies the embedded runtime as Bun v1.4.0 [E4].
4. **Non-TUI code paths**: `--version` / `--help` are stable, and CLI/`serve` mode works on
   the old kernel (also demonstrated by a downstream CLI-fallback wrapper, 5/5 runs) [E1][E3]
   — the fault is in the TUI render path only.
5. **A deterministic missing-syscall failure as sole cause**: excluded — the crash is
   timing-sensitive (strace makes it disappear [E1]), which a hard ENOSYS-style failure would
   not be. Consequently no syscall-level trace was captured (see "Not yet measured").
6. Related prior investigation of a different Bun startup crash on the same kernel already
   ruled out `epoll_pwait2` / `pidfd_open` / `memfd_create` as TUI-blocking factors on
   3.18 [E7, criterion 4].

### Crash record format

Downstream launcher instrumentation writes a field record when the TUI process exits 139 and
stderr carries a `bun.report` / OpenTUI signature (noise control: any other exit produces no
record):

```
product: opencode1
timestamp: 2026-10-20T00:05:12Z
uname_r: 3.18.140-mokee
kernel_major: 3
runtime_version: 1.19.3
crash_rc: 139
--- stderr tail (last 50 lines) ---
<verbatim stderr: Bun v1.4.0 panic output ending with a bun.report/<id> link>
```

Sample record (fields verified on-device): `~/.local/share/opencode1/compat-crashes/20261020-000512-12477.log`
(26 lines) [E4].

Thread-level signature (session record [E1]): a render/event thread takes SIGSEGV
(`SEGV_MAPERR`, `si_addr=NULL`) after a futex wait; the main thread then terminates the
process (SI_TKILL), exit code 139.

Caveat when interpreting the report: Bun's crash handler reads a glibc-style `ucontext`
layout, so register/pc attribution inside `bun.report` is unreliable for bionic (Android)
processes — do not trust the JSC/JIT attribution without independent verification [E7].

### Bisect lead

The failure appears exactly when the embedded OpenTUI renderer library changes generation:

- 1.18.34: `libopentui.so`, 5,495,136 B — identified as OpenTUI 0.5.10 [E2]
- 1.18.35+: render-library slot jumps (1.19.3 slot: 6,037,032 B) — identified as
  OpenTUI 0.5.14+ [E2][E6]

Since 1.18.34 (0.5.10) passes and 1.18.35 (0.5.14+) fails on the same device with the same
Bun runtime generation, the **OpenTUI 0.5.10 -> 0.5.14+ bump is the prime suspect**. The
fault mode looks like a race in the render/event startup path that only settles on old
kernels; a review of the 0.5.10 -> 0.5.14+ diff for startup-path synchronization changes is
the suggested next step. This may need coordination with the OpenTUI repository.

### Minimal reproduction package

Generic (for maintainers with old-kernel hardware):

1. aarch64 Linux, kernel < 4.x (measured: 3.18 fails, 6.6 passes; the 4.x boundary is not yet
   measured).
2. opencode >= 1.18.35 (tested 1.19.3). Not yet re-verified against a pristine npm install —
   our runs use downstream Android builds compiled from upstream source at the 1.19.3 tag.
3. `script -qec "timeout 10 opencode" /dev/null` under a pty -> expect exit 139 plus a
   `bun.report` link on stderr.

Prebuilt, checksum-verifiable artifacts (paths relative to the downstream repository; built
from upstream source at the 1.19.3 tag):

| Artifact | Size (B) | sha256 | Behavior |
|---|---|---|---|
| `packing/dpkg-native/opencode1_1.19.3_aarch64.deb` | 40,260,580 | `e68b428dcb07420abc42187fb67ffc1c7839ba363b76e51dc06cb3adf2622711` | crashes (native, uncompressed) |
| `packing/dpkg-compressed/opencode1-compressed_1.19.3_aarch64.deb` | 59,597,024 | `a9b107e9a2ec2bab27f6ce3c293dadf2e879c1224fb34f2e00f94396bdb2f49e` | crashes (UPX-compressed) |
| `packing/compat/1.19.3/opencode1_1.19.3_aarch64.deb` | 40,181,592 | `91573249753c04f786b8ac6aaaac859d80c2ace366f773884914d08169bc1275` | works (downstream workaround; runtime sha256 `04dfae41a770eb733ebebf25affa1f70c3b4999508d54d3803f83a48e870f01a`, 181,326,096 B) |

(`opencode1` is the downstream package name for the 1.x generation so it can coexist with
the 2.x generation; the upstream binary name is `opencode`.)

### Downstream mitigation (context — not a proposed upstream fix)

We currently ship two narrow stopgaps for affected users; a proper upstream fix is preferred,
which is why this issue is filed:

- **CLI-fallback wrapper**: a launcher detects kernel < 4.x + runtime >= 1.18.35 and degrades
  the TUI-default scenario to headless `serve` (CLI stays fully usable), printing a bilingual
  (zh/en) notice; `--force-tui` overrides. Old-kernel device: 5/5 runs rc=124 with the
  service listening [E3].
- **Renderer graft**: swap the 1.18.34 OpenTUI 0.5.10 library (5,495,136 B) into the 1.19.3
  bunfs slot (6,037,032 B) via equal-length byte surgery with NUL padding. Old-kernel device:
  5/5 runs rc=124 with a fully rendered TUI (terminfo handshake, alternate screen, mouse
  tracking); new-kernel control device: 5/5 runs rc=124, zero regression [E2][E5]. The
  UPX-compressed variant of the grafted build is not shippable (empirically crashes; known
  UPX x graft incompatibility [E7, criterion 5]) — which is how narrow the workaround space
  is.

### Not yet measured (pending)

1. Kernel 4.x–6.x boundary: only 3.18.140 (fail) and 6.6.118 (pass) measured.
2. v2 exact patch build: the session record states "v2.0.x, 5/5 rc=139" but does not pin the
   patch build (2.0.31 was the current v2 build at session time); v2's embedded OpenTUI
   version/slot not measured.
3. Intermediate versions 1.18.33 and 1.19.0–1.19.2 not individually run.
4. Pristine npm / official-release binary reproduction not yet re-verified.
5. Root cause not pinned; no syscall-level trace captured (strace suppresses the crash).
6. Architectures other than aarch64 not tested.
7. The `bun.report` link IDs live in the full stderr tails of the crash records; they are not
   transcribed into this draft.

### Evidence index (downstream test records)

All paths are relative to the downstream repository (`opencode-termux`); records are available
on request.

- [E1] `.omo/drafts/oldkernel-compat.md` — session record 2026-10-18 (version matrix,
  exclusion list, thread-level crash signature, OpenTUI generation jump)
- [E2] `.omo/evidence/oldkernel-compat/task-1-hybrid-experiment.md` — 1.18.34 / 1.19.3 5-run
  results; donor and slot byte sizes; render proof
- [E3] `.omo/evidence/oldkernel-compat/task-4-launcher-degrade.md` — CLI-fallback wrapper 5/5
- [E4] `.omo/evidence/oldkernel-compat/task-5-crash-trap.md` — crash record fields and
  on-device sample log
- [E5] `.omo/evidence/oldkernel-compat/task-6-graft-product.md` — graft products; dual-device
  5/5; UPX variant not shipped
- [E6] `.omo/compat-ledger.jsonl` — OSC-001 (`first_bad=1.18.35`, `last_good=1.18.34`,
  `opentui_min=0.5.14`, verdict `graft-ok`)
- [E7] `docs/tui-reachability.md` — earlier same-kernel investigation (criterion 4: syscall
  exclusions; criterion 5: UPX x graft; bun.report attribution caveat)
