# OCT Plugin Split Pre-Branch Research (Single-File README)

> Purpose: preserve all key findings and constraints **before** plugin work is split out.
> Scope: this file is the canonical pre-split research snapshot for subsequent sessions.

---

## 1) Current Situation (Clear Status)

### 1.1 Repositories and role split

- `opencode-termux` (OCT): core runtime/package workflow (mainline)
- `oh-my-litecode` (OML): orchestration/command bridge
- `opencode-plugins-termux`: newly established external plugin builder route

### 1.2 What has already been proven

- Machine flow established and validated multiple times:
  - local host = edit/relay
  - machine1 = build
  - machine2 = install/test
- OCT package flow works on machine2 (`opencode --version`, `opencode web`)
- Hook/skill phase-2 framework exists in OCT (registry + compatibility/blocklist + fail-soft defaults)
- OML now has `oml opencode plugin-build ...` bridge to external plugin builder

### 1.3 Why plugin split is necessary

- Named-plugin auto install chain on Termux is high-risk due to:
  - network instability (`SSL EOF`, clone/pull failures)
  - npm/bun postinstall behavior drift
  - native/platform dependency mismatch
- Therefore, plugin packaging and plugin policy should evolve independently from OCT core packaging.

---

## 2) Hard Constraints / Working Rules

### 2.1 Environment priority

1. Termux first-class
2. GNU/Linux secondary
3. no additional OS scope unless explicitly requested

### 2.2 Operational chain (must keep)

- local edits/coordination
- machine1 build
- machine2 install/validation

### 2.3 Plugin safety defaults (Termux)

- Prefer `file://` plugin registration in `~/.config/opencode/opencode.json`
- Avoid bare named-plugin entries as default on Termux when dependencies are heavy/unpredictable

---

## 3) Key Technical Findings (Pre-Split)

### 3.1 Core/package findings

- Core dependency baseline for runtime path:
  - required: `glibc`, `openssl-glibc`
  - optional fallback: `glibc-runner`
- Matrix simulation (`upgrade/downgrade`) is available and useful for regression checks

### 3.2 Plugin/hook findings

- System-skill hook runner exists with safe defaults:
  - fail-soft behavior
  - optional network gate
  - registry/blocklist/idempotency support
- Plugin manager was hardened with:
  - git retry/backoff
  - rollback on failure
  - state metadata file
  - npm fallback path improvements

### 3.3 Recurring failure classes observed

1. network-level fetch failures (GitHub SSL EOF)
2. package manager dependency/platform constraints
3. malformed config JSON caused false negatives during runtime tests
4. transient artifact corruption in some relay/build attempts (must validate package integrity before install)

---

## 4) Plugin Candidate Notes (Preliminary)

> This section records what was observed before formal plugin-only sessions.

- `code-yeongyu/oh-my-opencode`:
  - very active
  - heavy harness; environment-sensitive behaviors possible
- Qwen OAuth direction references:
  - `gustavodiasdev/opencode-qwencode-auth`
  - `foxswat/opencode-qwen-auth`
  - alternative active auth-oriented candidate used in tests:
    - `andyvandaric/opencode-ag-auth`

No final long-term plugin ranking is declared in this file; plugin-only sessions should own that decision.

---

## 5) Decision: Plugin Development Ownership

### Effective decision

- OCTPlugin line is split out from OCT core mainline.
- Ongoing plugin development is delegated to **machine1 local Opencode + OMO workflow**.
- This session should focus on pre-split research context and non-plugin-core continuity.

---

## 6) What Future Sessions Should Do (After Split)

### Plugin branch sessions

- continue in `opencode-plugins-termux`
- iterate per-plugin subproject build/debug independently
- keep top-level Make as batch orchestrator
- validate on machine1->machine2 loop

### OCT core sessions

- focus on runtime/package stability and documentation quality
- avoid re-coupling plugin complexity into OCT core unless necessary

---

## 7) Practical Checklist Before Starting Plugin-Only Work

1. Confirm machine1 branch/repo baseline for plugin project
2. Confirm machine2 clean config JSON and plugin file-path mode for testing
3. Build artifact integrity check before install (`dpkg-deb -I` / extract check)
4. Execute web + selfcheck after install
5. Record result with explicit pass/fail and error class

---

## 8) Notes for Handoff Quality

- Keep this file updated only when pre-split assumptions change.
- Avoid scattering historical conclusions across many docs before plugin split stabilizes.
- Use this as the single context anchor for starting new sessions around "before plugin split" topics.
