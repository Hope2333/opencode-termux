# CI Runner Strategy — `.github/` build fleet

> **Status: PREPARED / not enabled.** The three workflows in this directory
> (`build-fleet.yml`, `nightly-fleet.yml`, `asset-push.yml`) exist only on branch
> `rc6-a2/docs-ci`. They are **not pushed**, and the cron trigger in
> `nightly-fleet.yml` is commented out. Nothing here changes CI behaviour today.
>
> Scope note: `.github/ACTIONS_DISABLED.md` still governs — GitHub Actions is not
> the final Termux release authority. These workflows are a *build-fleet
> candidate*, not a claim of release authority.

---

## 1. The question that decides everything: can the bionic/aarch64 triple be cross-compiled on an x86 runner?

Short answer: **no, not with the current scripts.** Three independent blockers,
each sufficient on its own.

| Component | Script | Why it can't run on GitHub-hosted x86 |
|---|---|---|
| bun baseline (aarch64-android) | `tools/transplant/config/bun-bind.json` pins the target; the binary is *downloaded* from `bun-linux-aarch64-android.zip` | The build scripts **exec** it (`$ANDROID_BUN --version`, then `bun script/build.ts`). An x86 host cannot exec an aarch64 ELF. This exact constraint is why `build-native-android.yml` passes `--no-execve` and calls itself "diagnostic/handoff". |
| bionic `libopentui.so` | `tools/transplant/build-libopentui.sh` | Depends on `BIONIC_SYSROOT=/data/data/com.termux/files/usr` and an `LD_PRELOAD` `w7b-shim.so` whose only job is to work around **Android SELinux's hardlink EPERM** in zig's cache. NDK has a bionic sysroot, but the w7b recipe's whole build layer (hdrfix dir, crt dir, `/system/lib64/libm.so`, the SELinux shim) is Termux-shaped, not NDK-shaped. Porting it is a project, not a config knob. |
| bionic `librust_pty` (bun-pty) | `tools/bun-pty-embed/build-embed.sh` | Plain `cargo build --release` — a **native** build against Termux bionic, no `--target` cross flag, plus a hand-patched `termios` crate with an `os/android.rs` module and a `[patch.crates-io]` re-versioning hack. NDK cargo targets exist but this crate pair has never been built that way; the android module is exactly the code path an NDK build would newly exercise. |

A fourth, softer blocker: the *press* and *package* stages are Termux-shaped too.
`tools/a2/press-v5.sh` needs Termux `upx` + `readelf` and gates on
`df -k /data/user/0` (an Android path). `scripts/package/package_pacman_native.sh`
needs `makepkg`, and `tools/pkg-abs-repack.sh` bakes the termux-pacman absolute
member convention `data/data/com.termux/files/usr/...` which is meaningless
outside that ecosystem.

### So: NDX/NDK cross is not the answer, a real ARM runner is

- **Termux-on-Android, aarch64** — the only environment where all of the above is
  already proven. This is what today's verified artifacts come from (Android 9 /
  kernel 3.18 on `oscar`, plus the local device).
- **A generic aarch64 Linux box (Debian arm64, SBC)** — would need the whole
  Termux toolchain re-rooted (`BIONIC_SYSROOT`, prefix layout, the SELinux shim
  becomes unnecessary but the hardlink problem may reappear differently, SELinux
  on Debian is not Android's). High risk, unproven.
- **x86 hosted runner with qemu-user** — aarch64 *user* emulation does not
  reproduce the bionic-vs-glibc distinction that this whole project exists to
  manage, and it isn't fast enough for a UPX `--best` pass. Not worth it.

**Conclusion: `build-*` jobs must run on a self-hosted ARM runner that is actually
a Termux device.** `plan` / `aggregate` / `summary` / the whole of
`asset-push.yml` are metadata-only and belong on GitHub-hosted x86.

---

## 2. Job-to-runner mapping

| Workflow | Job | Runner | Why |
|---|---|---|---|
| `build-fleet.yml` | `plan` | `ubuntu-latest` | Pure JSON matrix expansion + path existence checks. Nothing arch-specific. |
| `build-fleet.yml` | `build` | `[self-hosted, linux, ARM64, android, termux]` | Execs the aarch64-android bun; needs Termux upx/readelf/makepkg, the bionic sysroot, and the Android df gate. |
| `build-fleet.yml` | `aggregate` | `ubuntu-latest` | Reads status JSON, decides `ready_for_push`. |
| `nightly-fleet.yml` | `nightly`, `summary` | `ubuntu-latest` | Dispatch orchestration only; the real work is in `build-fleet.yml`. |
| `asset-push.yml` | `push` | `ubuntu-latest` | `gh release upload` is arch-agnostic; the upx slot stays on-device (see §6). |

---

## 3. Self-hosted Termux runner: what it takes

### 3.1 Labels

The `build` job requests `[self-hosted, linux, ARM64, android, termux]`. Register
the runner with exactly those labels; `ARM64` and `termux`/`android` are custom,
the other three come free with `--labels`.

### 3.2 Preconditions (the runner will fail without them)

| Requirement | Why | Check |
|---|---|---|
| Termux on aarch64 Android | whole toolchain assumption | `uname -m` → `aarch64`; `ls /data/data/com.termux/files/usr` |
| `gh` authenticated **or** relying on Actions' token | only needed for push-side, not build-side | `gh auth status` |
| `upx`, `readelf`, `python3`, `make`, `ar`, `pkg`, `tar`, `xz` | press + package stages | `command -v` sweep (the workflow's `Preflight` step does this and fails loudly) |
| bun baseline present at `artifacts/transplant/android-bun/bun-<ver>/bun` | the compile step | `tools/transplant/config/bun-bind.json` target |
| **Free disk** | build-v1 gates at 1200 MB, press-v5 at 800 MB, and a matrix entry writes a 180 MB-class ELF plus a UPX working copy | `df /data` — the preflight prints it; keep headroom for the whole matrix, not one entry |
| Constant power + thermal headroom | UPX `--best` on a phone is a sustained load | not checkable in software; this is the real constraint on a phone |

### 3.3 Operational warnings — read before enabling

1. **One executor.** A single device runs one job at a time. A 7-entry matrix is
   effectively serial. Wall-clock ≈ 7 × per-entry time.
2. **The runner shares the device with you.** It will eat the battery, fill
   `/data`, and can collide with your own Termux work (shared `$PREFIX`, shared
   `artifacts/`). `build-v1.sh` and `build-bionic.sh` both write
   `artifacts/build/<ver>/` and share the `libopentui` / `bun-pty` asset slots —
   two concurrent versions on one device can poison each other. The workflows set
   `max-parallel: 1` semantics via a single-device runner, but a *human* build
   running at the same time is not protected. Coordinate.
3. **The runner must not be the machine you dev on.** Untrusted-PR code plus your
   live `$PREFIX` is a bad combination. A dedicated device is strongly preferred.
4. **Workflows from a fork cannot run on self-hosted runners** (GitHub's own
   restriction) — good, but it means the fleet can only be driven from this repo.
5. **Registration is a trust decision.** A self-hosted runner executes whatever
   the workflow says, with the device's own permissions and network position.
   Keep the runner's GitHub token scope minimal; prefer a runner account whose
   only job is this.

---

## 4. Caching — what is worth caching, and what will bite you

`build-fleet.yml` caches three things. Each has a reason and a hazard.

| Cache | Path | Key | Why | Hazard |
|---|---|---|---|---|
| bun baseline | `$RUNNER_TEMP/fleet-cache/bun-<ver>.zip` | `bun-android-<ver>-<os>-<arch>` | ~100 MB download; the compile step is the expensive part, not the fetch | **Cache the tarball, not the extracted tree.** The extracted tree hits Android SELinux's hardlink EPERM in zig/bun caches (this is why `build-libopentui.sh` needs `w7b-shim.so` in the first place). Caching an extracted tree freezes a directory state that must be re-extracted anyway. |
| bun install store | `$RUNNER_TEMP/fleet-cache/bun-store` | `bun-store-<line>-<ver>-<os>-<arch>` | `bun install` on the opencode monorepo is slow and network-heavy | Per-line-per-version key, so it accumulates. Add eviction by hand (`--key` churn) — `actions/cache` is LRU with a 10 GB repo cap. |
| cargo registry + git deps | `~/.cargo/registry`, `~/.cargo/git` | `cargo-<os>-<arch>` | `bun-pty-embed` and the w7b zig tree pull crates/git deps | Shared across all entries and all lines (correct — the dep set is version-independent). |

`nightly-fleet.yml` deliberately passes `cache_bun_baseline=false`: nightly writes
to the same cache keys as manual runs, and a nightly that lands mid-manual-run can
poison a warm cache. Nightly keeps `cache_rust=true` (harmless, low churn) and
shortens artifact retention to 7 days.

**Cache poisoning is the general hazard here**: `actions/cache` has no integrity
guarantee beyond the key. A cache written by a bad run is restored by a good run.
If a build ever fails in a way that could leave a corrupt store, the recovery is
to bump the key suffix, not to debug the restore.

---

## 5. Artifact size and retention

Numbers, not adjectives:

- a single un-pressed v1 ELF is **~180 MB** (the `upx-report` in
  `Makefile`'s `transplant-upx` target and the fleet logs both show the
  `179807785 -> 51891796` shape: 28.86% after UPX).
- a `.pkg.tar.xz` pacman package wraps that, so tens of MiB after compression.
- a 7-entry matrix × 14-day retention is enough to approach GitHub's free
  **artifact storage** quota (0.5 GB/repo/month on the free tier; **cache** is
  10 GB/repo separately). Above quota, artifact upload *fails* — it does not
  silently degrade.

Settings chosen: `artifact_retention_days` default **14** for manual
`build-fleet` runs, **7** for nightly. That is a quota decision as much as a
hygiene one.

Logs: default 30 days for status/evidence artifacts, 90 for the push evidence
(`asset-push-evidence-<tag>`) because it is the audit trail for a release write.
Workflow run *logs* (the console output) are retained by GitHub per repo settings
and are not controlled from the workflow file.

**Retention of truth:** the authoritative record for acceptance lives in
`.omo/evidence/`, not in CI artifacts. CI artifacts are disposable transport.

---

## 6. Why `asset-push.yml` does not call `fleet-push.py`

`tools/fleet-push.py` (~900 lines) is a **three-node compression scheduler**. Its
flow per version: local → SSH push to node → node untars the ELF → `upx --best`
with live progress → `xz -9` → node uploads straight to `gh release` (auth already
recorded on the node). It assumes `~/opc-fleet` inbox/out layout, reachable SSH
nodes, and `gh` already authenticated on each node. A GitHub-hosted runner has
none of that; a phone has the SSH topology but not a stable Actions control loop.

Current split of responsibilities:

- **Uncompressed `.pkg.tar.xz` upload** → `asset-push.yml`. Pure `gh release
  upload`, no SSH, no device.
- **UPX slot** (`opencode-native-<ver>-upx.xz`) → `fleet-push.py`, still run by
  hand from the device or a node host.
- The pending "switch the asset template to uncompressed + reserve a press slot"
  refactor is a **separate task**; until it lands, this workflow does not touch
  the UPX asset name.

### Asset naming contract (single source of truth)

`tools/fleet-push.py::discover_release` recognises packages by:

```
^(?:opencode|opencode1)-([\d.]+)-(\d+)-aarch64\.pkg\.tar\.xz$
```

so: `opencode1` for v1 (1.x) packages, `opencode` for v2, a dot-separated
numeric version, a `pkgrel` number, `aarch64`, and the `.pkg.tar.xz` extension.
`scripts/package/package_pacman_native.sh` is where the `1.*` → `opencode1`
rename happens. `asset-push.yml` validates every name against **the same regex
verbatim** (transcribed to POSIX ERE as `[0-9.]+`) before uploading, and fails the
whole run on a single violation — a near-miss name is worse than no name, because
`discover_release` will silently ignore it and the fleet will look short.

The transcription is deliberately *not* tightened to a three-part version. The
real consumer accepts `1.18`; a stricter CI gate would reject packages the fleet
itself is willing to read, making CI a stricter gate than production for no
benefit. Any future change to `discover_release`'s regex must be mirrored in
**both** workflows (`build-fleet.yml`'s status step and `asset-push.yml`'s
normalize step) at the same time.

### Release tag strategy

| Tag | Purpose | In `discover_release`? |
|---|---|---|
| `fleet-<line>-<YYYYMMDD>` (rolling) | the release `discover_release` reads; the whole version universe must be visible in **one** release | **Yes — this is the input** |
| `opencode-<ver>` (immutable, optional) | human-facing snapshot anchor; default off | No |

Why rolling rather than per-version: `discover_release` builds the version table
by scanning **one tag's** asset list. Per-version tags would degrade the fleet
table to a single row per scan. Rolling tag + immutable per-version aliases gives
both machine and human addressing.

Why `require_fresh_tag: true` by default: reusing a tag means `--clobber` could
overwrite assets someone else published under it. Freshness is checked; overwriting
must be opted into explicitly.

---

## 7. Idempotency: how a half-product cannot reach a release

Six independent gates, any one of which stops a bad push:

1. `build`'s package artifact uploads under `if: success()`. A failed or
   interrupted build produces **no** package artifact — only a status artifact.
2. Every entry writes `status/<line>-<ver>.json` under `if: always()`, so the
   aggregate can distinguish "failed" from "never ran".
3. `aggregate` computes `ready_for_push` = *all entries present, none failed*.
   Partial success is `false` — a half-matrix is never treated as a whole fleet.
4. `asset-push.yml` refuses to start unless it can download that
   `fleet-aggregate-summary` artifact **and** read `ready_for_push=true` **and**
   the source run's conclusion is `success`. It does not trust the dispatch-time
   judgement; it re-reads the artifact.
5. Names are validated against the `discover_release` regex and sha256s are
   recomputed and cross-checked **against the authoritative manifests from the
   source run's status artifacts**. If no manifest is found the push is
   refused — it does not degrade to "no checksum available, proceed". A missing
   manifest and a passing check must never look the same.
6. Real push requires `confirm: true` **and** the `release` environment
   (protection rules configured repo-side). Uploads default to *no* `--clobber`,
   so a pre-existing asset of the same name is a hard failure rather than a
   silent overwrite.

Re-running is safe at every level: the matrix is idempotent per entry (build
scripts are documented as idempotent — `build-v1.sh` reuses a warm store,
`pty-embed-store-patch.sh` skips when the store already carries the bionic build,
`hermetic-home-patch.py` re-detects a clean intermediate), status files are
overwritten, and the push is gated on a fresh tag.

---

## 8. Supply-chain checks

Present:
- `SHA256SUMS.txt` per entry, recomputed in CI, merged (not overwritten) into the
  release — same intent as `fleet-push.py::update_checksums`.
- Optional SBOM (syft → SPDX JSON) via the `sbom` input. Default **off**: syft must
  be preinstalled on the runner, and the build fails loudly if it was requested
  but missing (a silently-skipped SBOM is worse than none — it leaves a false
  "SBOM enabled" impression on the release).

Not present, and how to add:
- **cosign keyless**: needs `permissions: id-token: write` and OIDC, which the
  self-hosted Termux runner must be able to obtain. Add to `asset-push.yml`'s
  permissions and a `cosign attest` step after upload.
- **SLSA provenance**: `actions/attest-build-provenance`; again needs `id-token:
  write` and a verification step in `fleet-push.py` on the consumer side.
- **upstream source pinning**: `bun-bind.json` pins the bun target; the opencode
  tarball is fetched by version tag from npm. A `--provenance`-checked npm fetch
  would close the loop.

---

## 9. Known blockers before any of this can run

These are **not** runner-configuration problems. They will fail regardless of
runner.

1. **`press-v5.sh` hardcodes `VER="1.18.32"`.** A matrix containing
   1.18.30/31/33/34 on the v1 line will build 1.18.32 every time.
   `tools/a2/pty-embed-store-patch.sh` has the same pin in its default `V1_SRC`
   *and* a pinned `VENDOR_SHA` for the bionic `librust_pty`. **Parameterize these
   three before running a multi-version v1 matrix.**
2. **`fleet-push.py`'s `ASSET_TMPL` is hardcoded to the `-upx.xz` name** while
   `discover_release` keys off uncompressed package names. The uncompressed-mode
   refactor is a separate, pending task.
3. **`build-fleet.yml` is not yet a `workflow_call` consumer.** `nightly-fleet.yml`
   currently dispatches it with `gh workflow run` and cannot capture the run id;
   adding a `workflow_call:` trigger to `build-fleet.yml` would let nightly
   `needs:` the aggregate result properly. Deferred.
4. **v2 source acquisition.** `scripts/build-bionic.sh` expects a v2 monorepo
   checkout (`V2_SRC`, defaulting under `$HOME/develop/opencode-src/`). The v2
   matrix entries assume such a tree exists on the runner; there is no automated
   fetch step for it.
5. **`docs/fleet-matrix.md` does not exist yet** (being written by another task).
   `build-fleet.yml` deliberately does **not** depend on it — version lists come
   from `workflow_dispatch` inputs with in-file defaults.
6. **Docs were reorganised** under `docs/<topic>/NN-<name>.md`. References in this
   file use the new locations: the transplant pipeline is
   `docs/10-build/14-transplant-pipeline.md`, and the existing self-hosted ARM
   runner precedent is `docs/50-automation/52-armv7-native-runner-setup.md`
   (read it first — it is the closest thing to a setup guide we have, and §3.2
   below is deliberately consistent with it).

---

## 10. Open decisions for the maintainer

1. **Self-hosted runner: dedicated device or the dev phone?** Recommendation:
   dedicated. See §3.3.
2. **Nightly cadence.** Draft uses `17 3 * * *` (UTC), ~11:17 in UTC+8. Daily
   builds a 7-entry matrix on a phone; is nightly actually useful, or would
   weekly + on-demand be enough? Consider also that GitHub **auto-disables**
   scheduled workflows after 60 days of no repository activity.
3. **Artifact retention.** 14 days manual / 7 nightly. If the free-tier artifact
   quota is a concern, drop manual to 7 and rely on `asset-push.yml` for
   durability.
4. **Who approves `environment: release`?** The workflow declares the environment
   but the required-reviewer list is repo-side config. Without reviewers,
   `confirm: true` alone is the only human gate.
5. **Cross-repo push token.** Current draft uses `secrets.GITHUB_TOKEN`
   (same-repo, `contents: write`). If assets must land in a *different* repo, a
   fine-grained `secrets.RELEASE_PUSH_TOKEN` scoped to that repo is required —
   do not use a PAT.
6. **Matrix granularity.** Draft splits by **line** (v1 / v2) with per-line build
   commands rather than a flat version list, because the two lines share no
   toolchain, no gates, and no timeouts. Confirm this is the intended cut.
7. **glibc line scope.** `glibc-cross.yml` is prepared for **x64 only** (phase 1
   of `docs/cross-compile/plan.md`). Phase 2 (`linux-arm64` glibc) is a one-line
   target change *once phase 1 lands*, but it needs `ubuntu-2404-arm` quota —
   which is exactly the scarce resource that pushed this project toward a
   self-hosted runner. Decide whether phase 2 is worth it before assuming it is
   cheap.

---

## 9b. The glibc line is a different runner class — `glibc-cross.yml`

`glibc-cross.yml` is deliberately **not** part of `build-fleet.yml`.

| | `build-fleet.yml` | `glibc-cross.yml` |
|---|---|---|
| Product | bionic / aarch64 Android | glibc / x86_64 Linux |
| Runner | self-hosted Termux phone (`ARM64,android,termux`) | GitHub-hosted `ubuntu-24.04` (native x64) |
| Why that runner | must **exec** the aarch64-android bun; NDK cross can't do the bionic triple (§1) | no simulation needed — the target *is* the hosted runner, so no qemu/binfmt (方案 A) |
| Packaging | termux-pacman absolute-path members | none yet — phase 1 is compile + accept only |
| Gates | `readelf`/df gate/TUI smoke on-device | the **3 checks** below |

Merging them would erase the "which jobs need the real phone" boundary, and the
two product lines have nothing semantically in common.

### The 3 checks (tightened from 2)

1. `readelf -l` → INTERP must be `/lib64/ld-linux-x86-64.so.2`
2. `strings` → baked `process.platform` must be `linux`
3. opentui platform package landed → `@opentui/core-linux-x64` blob embedded

**Check 2 is the only one that catches the "sneaky bad product"** (combo D:
`--target=bun-linux-x64` + glibc baseline path). I verified this empirically by
building ELF fixtures: the combo-D shape **passes check 1 completely** — legal
glibc INTERP, correct `libc.so.6` NEEDED — while baking `platform="android"`,
which sends opentui down its `throw` path and makes the TUI 100% dead. A
`readelf`-only gate reports that product as good.

The only correct recipe is **combo C**: `--target=<musl token>` **and**
`--compile-executable-path=<glibc baseline>`, both together. The token governs
JS baking; the path governs the ELF. They are independent knobs — supplying
either alone produces a broken product.

### Negative acceptance (item 5) is mandatory

`build-and-verify` proves the happy path. `negative-acceptance` builds the
combo-D counter-example and asserts check 2 **rejects** it. Without this, "the
gate passed" only means "the gate wasn't triggered" — which is not the same
thing as "the gate works".

The job ends with a guard that **fails it** if the counter-example was never
actually built. A green negative-acceptance job that silently skipped its own
assertion is the classic false-PASS, and it is worse than no negative test at
all.

### Two silent traps (documented inline in the workflow)

1. **`bun install` on a bionic host silently skips the x64 platform package** —
   lockfile records it, exit 0, **no warning**, `node_modules` empty. Requires
   `--cpu=x64 --os=linux` **and a clean directory**; adding only the flags hits a
   cache and does not re-extract. The job asserts the blob landed immediately
   after install, so this fails loudly instead of producing a dead product.
2. **`apply-platform-patch.sh` rewrites `if (process.platform === "linux")` to
   `if (true)`** — a **bionic-line-only** patch that must be reverted for glibc,
   and must **not** be put behind the same feature-flag condition as everything
   else (that would break the bionic mainline).

**The compile log's baseline name lies.** Both combo C and D print
`bun-linux-x64-android-v1.4.0` while the copied binary actually comes from
`--compile-executable-path`. It is archived as evidence and must **not** be used
to judge success. Only the 3 checks count.

### glibc-cross.yml is currently blocked, honestly

Its `preflight` job asserts the prerequisites exist and **fails by design**:

| Item | Status in `tools/a2/build-v1.sh` |
|---|---|
| T1 `A2_TARGET_FILTER` parameterisation | missing — line 129 hardcodes `item.arch === "arm64"` |
| T1b `--compile-executable-path` support | missing — no such argument anywhere |
| T3b glibc opt-out of the platform patch | missing — line 118 applies it unconditionally |
| T3 in-script `strings` gate | missing (the 3 checks in CI substitute for it) |
| P3 baseline sha256 | 1.3.14's `a9a0d18d…` cannot be reused; 1.4.0 must be fetched and recorded |

All of those live in `tools/a2/build-v1.sh`, outside this agent's write scope
(`.github/` only). The job names each missing item rather than pretending to
work. Fix them, then run `glibc-cross.yml` with `run_negative=true`.

---

## 11. Enabling, in order

1. Provision the self-hosted Termux runner with labels
   `self-hosted, linux, ARM64, android, termux`; verify the §3.2 preconditions.
2. Fix blocker #1 (`press-v5.sh` / `pty-embed-store-patch.sh` version pinning) if
   you want more than the single 1.18.32 v1 entry.
3. Push this branch. Run `build-fleet.yml` with `dry_run=true` first — it stops
   after `plan` and never enters the `build` job, so it validates the matrix
   expansion and the path-existence checks without touching a device.
4. Run with `dry_run=false, push_artifact=true` for one entry. Inspect the
   artifact and the status JSON.
5. Run `asset-push.yml` against that run with `confirm=false` and read the dry-run
   plan. Only then `confirm=true` with a fresh rolling tag.
6. Enable nightly last, and only if §10.2's answer is "yes, daily".
