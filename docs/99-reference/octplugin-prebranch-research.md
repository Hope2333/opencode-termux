# OCTPlugin Pre-Branch Research README

> Session purpose: consolidate all findings before splitting `OCTPlugin` into an independent development line.

## 0) Important clarification

- This model cannot read clipboard/image input in this chat runtime.
- The error you pasted (`Cannot read "clipboard"`) is expected in current environment.
- Use plain text / pasted logs / file paths for analysis.

---

## 1) Current decision (confirmed)

1. `OCTPlugin` will be split out as a dedicated branch/line.
2. Plugin development execution will be owned by **machine1 local Opencode + OMO workflow**.
3. This session should focus on **pre-branch research and baseline documentation**, not long plugin feature coding.

---

## 2) What has been completed so far

### 2.1 Core OCT hardening (already landed)

- Termux package flow stabilized (deb + pacman).
- Machine1(build) -> relay -> machine2(test) flow repeatedly validated.
- System-skill hooks and safety gates implemented:
  - fail-soft hook default
  - compatibility gates (min/max/blocklist)
  - registry + selfcheck visibility

### 2.2 OML orchestration (already landed)

- `oml opencode ...` command group exists.
- `oml opencode plugin-build ...` bridge added to call external plugin builder project.

### 2.3 External plugin builder project initialized

- Repository: `opencode-plugins-termux`
- Initial structure created and pushed:
  - top-level batch Makefile
  - per-plugin workspaces (`plugins/<name>/...`)
  - dual package outputs (deb + pacman)
  - plugin definitions for:
    - `oh-my-opencode`
    - `opencode-qwencode-auth`
    - `opencode-qwen-auth`

---

## 3) Key technical findings (important)

### 3.1 Named plugin chain on Termux

Named plugin auto-install is **possible**, but higher-risk on Termux due to:

- network instability (git SSL EOF / transient clone failures)
- npm/bun postinstall drift
- native/OS package assumptions

### 3.2 Safer default mode on Termux

Prefer file plugin mode:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    "file:///absolute/path/to/plugin"
  ]
}
```

This is more deterministic and easier to rollback.

### 3.3 Package and test caveats observed

- Occasional archive corruption / quota-related build failures occurred during heavy local artifact churn.
- Temporary-directory pressure caused false negatives in plugin pack test runs.
- JSON quoting mistakes in remote inline commands caused invalid config writes during some tests.

Operational mitigation:

- keep build temp dirs explicit and clean
- prefer file-based config transfer for machine2 tests
- validate archive integrity (`dpkg-deb -I/-x`) before install tests

---

## 4) Candidate plugin route (oauth/qwen line)

Referenced candidates:

- `https://github.com/gustavodiasdev/opencode-qwencode-auth`
- `https://github.com/foxswat/opencode-qwen-auth`
- active alternative observed: `https://github.com/andyvandaric/opencode-ag-auth`

Current recommendation for Termux-first validation:

1. Build/install plugin package via `opencode-plugins-termux`.
2. Register as `file://` plugin path on machine2.
3. Verify with `opencode web` + `plugin-selfcheck`.

---

## 5) Pre-branch checklist (before creating OCTPlugin branch)

1. Freeze this document as baseline.
2. Confirm branch owner and machine1 execution policy.
3. Snapshot current repos and commit IDs (OCT / OML / plugins).
4. Define branch scope:
   - plugin packaging only
   - plugin runtime diagnostics
   - compatibility matrix and rollback behavior
5. Define acceptance criteria for branch mergeback.

---

## 6) Suggested branch scope for `OCTPlugin`

### In-scope

- per-plugin self-build Makefiles inside each plugin workspace
- top-level batch orchestration and bulk build/test
- plugin package metadata consistency (deb + pacman)
- machine1->machine2 plugin-only validation matrix

### Out-of-scope

- core opencode runtime packaging internals (remain in OCT mainline)
- unrelated CI armv7 tracks
- broad multi-OS support beyond current policy (Termux first, GNU/Linux second)

---

## 7) Suggested README container format (for future updates)

Use this single markdown as long-form container, with append-only sections:

- `## Date / Session`
- `### Goal`
- `### Changes`
- `### Validation`
- `### Risks`
- `### Next`

Include code/log snippets only when needed:

```bash
# command
... output ...
```

---

## 8) Immediate next action proposal

After your confirmation, create `OCTPlugin` branch and move plugin development cadence to machine1-local execution model, using this file as branch bootstrap context.
