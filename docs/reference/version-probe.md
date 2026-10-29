# Version probe (device criteria)

`tools/probe-version.sh` answers one question per package: **does this build
actually work on that phone?** It replaces the ad-hoc ssh + tmux sessions that
used to live only in a conversation transcript.

## What it checks

| Signal | Meaning | Pass rule |
|---|---|---|
| `install` | `dpkg -i` accepted the package | `ok` |
| `version` | binary reports what we asked for | `opencode v<ver>` (v2) / `<ver>` (v1) |
| `serve` | `serve --port N` answers on `/` | `200` |
| `tui_bytes` | captured frame size in tmux (120x30) | `>= 800` |
| `echoed` | typed text came back on screen | `>= 1` |
| `alive15` | still running 15 s after the keystroke | `YES` |
| `crash` | `panic` / `SIGSEGV` / `SIGSYS` in the frame | `0` |
| `degrade` | legacy-kernel downgrade banner in the frame | `0` |

The 800-byte threshold is deliberate: the removed legacy-kernel fallback printed
a 307-byte "已降级 CLI" banner, while a real TUI frame is 1200–2400 B. A lower
threshold would let that fallback pass as a working TUI.

## Usage

```bash
# one version
tools/probe-version.sh --device u0_a115@192.168.2.128 --kind v2 --ver 2.0.32

# several, then leave the device on a known-good build
tools/probe-version.sh --device u0_a115@192.168.2.128 --kind v2 \
    --list 2.0.32,2.1.0,2.2.0 --restore 2.1.4 --json ~/tmp/probe.json

# v1 packages older than 1.19.4 still ship the shim to lib/opencode, which is
# v2's slot — they refuse to install while v2 is present
tools/probe-version.sh --device u0_a115@192.168.2.128 --kind v1 \
    --list 1.18.33,1.19.3 --drop-other
```

`--range 2.0.30..2.0.32` expands inside a single minor version only. Crossing a
minor is an error on purpose: upstream skips patches (2.0.32 → 2.1.0), so a
synthesised `2.1.-1` would be fabricated data.

Exit codes: `0` every probe passed · `1` any FAIL/MISSING · `2` usage or
transport error.

## Design notes

- The verdict rules live in `scripts/lib/probe-lib.sh` (pure string/arithmetic),
  so `tests/unit/probe-lib.bats` covers PASS plus all eight failure classes
  without a device.
- `tools/probe/device-probe.sh` is copied to the device once per run. It reverts
  everything it touches: deletes the deb, kills tmux, and kills the probe server
  by **exact PID**. Never use `pkill -f` with a path pattern there — it once
  matched its own command line and took sshd down with it.
- Probe one device at a time. A run installs packages, so a concurrent build or
  another probe on the same phone will fight over `/data` space and the runtime.
- The device needs `tmux` and `curl`; both are present in the Termux baseline.

## Measured baselines (oscar, kernel 3.18.140 / OC105, 2026-10-30)

| Range | Result |
|---|---|
| v2 `2.0.32`, `2.1.0`–`2.1.4` | PASS (frame 1319–1342 B, serve 200) |
| v2 `2.0.31` | FAIL — package predates the 0.5.17 tlsdesc renderer; a rebuild fixes it |
| v1 `1.18.33`, `1.18.34` | PASS (frame 1257–1280 B) |
| v1 `1.18.35`–`1.19.3` | FAIL — upstream effect crashes on 3.18; these are the beta.103 rebuild candidates |
| v1 `1.19.4` | PASS (our effect `4.0.0-beta.103` rebuild) |
