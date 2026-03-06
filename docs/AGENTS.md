# DOCS KNOWLEDGE BASE

## OVERVIEW
`docs/` is the operational runbook corpus: build path, packaging policy, CI handoff, plugin/system-skill architecture, and incidents.

## NAVIGATION ANCHORS
- Start at `README.md` (canonical "Start here" + classification map).
- Use numbered flow for lifecycle context: `00`/`01` (scope+env) → `11`/`12`/`13` (build internals) → `20`/`21`/`22` (packaging/service) → `30` (verification matrix) → `99`/`incidents` (failures).

## WHERE TO LOOK
| Question | Document | Notes |
|---|---|---|
| Mainline release path? | `execution-checklist.md`, `local-production.md` | confirms local Termux path is authoritative |
| Runtime build details? | `11-opencode-build-plan.md`, `13-opencode-runtime-build.md` | source/wrapper/staging flow |
| DEB vs pacman packaging? | `20-packaging-deb.md`, `21-packaging-pkg-tar-xz.md` | package layout and verification |
| Hook/system-skill model? | `system-skills-hook-architecture.md` | policy defaults, lifecycle, registry/blocklist |
| Plugin operations? | `plugin-management.md`, `plugin-packaging-design.md` | file-plugin mode + rollback model |
| CI armv7 handoff intent? | `ci-prebuild-armv7.md` | attempt-based diagnostic workflow |
| Incident context? | `incidents/*` | RCA + follow-up actions |

## CONVENTIONS
- Keep docs aligned with current command surfaces (`Makefile`, `scripts/*`, `tools/*`).
- If adding a workflow-critical document, update `docs/README.md` classification pointers.
- Keep "mainline vs deferred" status explicit (especially armv7 CI/handoff topics).

## ANTI-PATTERNS (DOCS)
- Do not describe CI armv7 handoff as final release path.
- Do not duplicate long command sequences across many files; link to canonical runbook sections.
- Do not leave numbering/index references stale after moving or adding docs.

## QUICK CHECK
```bash
# verify docs entrypoints still resolve
ls docs/README.md docs/execution-checklist.md docs/local-production.md
```
