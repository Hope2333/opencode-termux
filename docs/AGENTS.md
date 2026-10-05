# DOCS KNOWLEDGE BASE

## OVERVIEW
`docs/` is the operational runbook corpus: build path, packaging policy, CI handoff,
plugin/system-skill architecture, incidents. Since 2026-10-05 it is organised as a
**family tree** (numbered directories by domain); `README.md` is the canonical index.

## STRUCTURE
```text
docs/
├── README.md          # canonical index: family tree + per-file entries + old→new map
├── AGENTS.md          # this file (docs-corpus conventions)
├── 00-scope/          # goals, scope, env baseline, production policy
├── 10-build/          # build & runtime internals (bun/opencode/native/TUI)
├── 20-packaging/      # deb/pacman/service/plugin packaging + docs bundle list
├── 30-testing/        # matrices, audits, test reports, perf, measurements
├── 40-release/        # release & migration runbooks, upstream notifications
├── 50-automation/     # CI handoff, make maintainer surface, plugin ops
├── 80-handover/       # dated handover snapshots (D1–D4 + recall pack)
├── 90-incidents/      # incident RCA, release lessons, UPX postmortem
├── 99-reference/      # upstream issue sync, comparisons, research, lookups
└── cross-compile/     # cross-compilation line (separate workstream)
```

## NAVIGATION ANCHORS
- Start at `README.md` — canonical index with per-file type/audience and the
  **old path → new path** mapping table for pre-2026-10-05 links.
- Lifecycle flow across families: `00-scope` → `10-build` → `20-packaging` →
  `30-testing` → `40-release`. Failures live in `90-incidents`.

## WHERE TO LOOK
| Question | Document | Notes |
|---|---|---|
| Mainline release path? | `40-release/40-execution-checklist.md`, `00-scope/03-local-production.md` | local Termux path is authoritative |
| Runtime build details? | `10-build/11-opencode-build-plan.md`, `10-build/13-opencode-runtime-build.md` | source/wrapper/staging flow |
| Native/transplant pipeline? | `10-build/14-transplant-pipeline.md` | revive surgery, dual format, TUI swap |
| DEB vs pacman packaging? | `20-packaging/20-packaging-deb.md`, `20-packaging/21-packaging-pacman.md` | package layout and verification |
| Which provider to install? | `20-packaging/23-dual-track-install.md` | native mainline vs wrapper appendix |
| Compressed/UPX line rules? | `20-packaging/24-compressed-line-contract.md`, `90-incidents/92-upx-v2-fix.md` | launcher-only contract + postmortem |
| Hook/system-skill model? | `20-packaging/26-system-skills-hook-architecture.md` | policy defaults, lifecycle, registry/blocklist |
| Plugin operations? | `50-automation/53-plugin-management.md`, `20-packaging/25-plugin-packaging-design.md` | file-plugin mode + rollback model |
| CI armv7 handoff intent? | `50-automation/51-ci-prebuild-armv7.md` | attempt-based diagnostic workflow |
| Maintainer make targets? | `50-automation/50-make-maintainer.md` | family dispatch, fleet push, cache cleanup |
| Release execution? | `80-handover/80-release-runbook.md` | D1 runbook, snapshot 2026-09-30 |
| Incident context? | `90-incidents/*` | RCA + follow-up actions |
| Upstream issue status? | `99-reference/99-open-issues-and-upstream-sync.md` | bun/opencode/loader tracking |

## CONVENTIONS
- Directory = two-digit family prefix + lowercase name; files inside keep a
  two-digit sequence prefix. Both together form the stable public path.
- Keep docs aligned with current command surfaces (`Makefile`, `scripts/*`, `tools/*`).
- Adding a workflow-critical document means updating `docs/README.md` (index) and
  the family entry — not just dropping a file in.
- Keep "mainline vs deferred" status explicit (especially armv7 CI/handoff topics).

## ANTI-PATTERNS (DOCS)
- Do not describe CI armv7 handoff as final release path.
- Do not duplicate long command sequences across many files; link to canonical runbook sections.
- Do not leave numbering/index references stale after moving or adding docs.
- Do not reintroduce flat files at `docs/` root — everything belongs to a family.

## QUICK CHECK
```bash
# every docs/ path referenced anywhere in the repo must exist
grep -rIho --exclude-dir=.git -E 'docs/[A-Za-z0-9_./-]+\.(md|txt|json|sh)' . | sort -u \
  | while read -r p; do [ -e "$p" ] || echo "DEAD: $p"; done
```
