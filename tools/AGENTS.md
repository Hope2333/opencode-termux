# TOOLS KNOWLEDGE BASE

## OVERVIEW
`tools/` provides user-facing orchestration CLIs: runtime preparation, make wrapper, plugin lifecycle, self-check, and upgrade matrix simulation.

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| Make wrapper UX | `make-opencode` | maps `--all/--batch/--pkg/--mix/...` into make vars |
| Runtime source + wrapping | `produce-local.sh` | npm-first, GitHub fallback, loader wrapping, stale-dir cleanup |
| Plugin install/update/rollback | `plugin-manager.sh` | snapshot-first mutation model + retry/backoff + state file |
| Environment/plugin diagnostics | `plugin-selfcheck.sh` | read-only JSON checks for config/plugins/skills |
| Upgrade/downgrade lifecycle tests | `upgrade-matrix.sh` | cached deb distribution + remote install/upgrade/downgrade simulation |

## CONVENTIONS
- Preserve CLI compatibility: additive flags, stable defaults, and clear `usage` blocks.
- Keep mutation flows rollback-capable (snapshot before destructive operations).
- Keep `plugin-selfcheck.sh` output machine-readable (JSON lines) for automation.
- For remote matrix flow, treat cached `.deb` artifacts as input contract.

## ANTI-PATTERNS (TOOLS)
- Do not run plugin manager against unintended `$CFG_DIR`/plugin roots; it performs destructive cleanup before rebuild.
- Do not drop retry/backoff + state recording around git/network operations.
- Do not use matrix flow as package builder; it validates already-built artifacts on machine2.
- Do not skip runtime verification (`file` + `--version`) in `produce-local.sh`-driven flow.

## COMMANDS
```bash
# make wrapper
./tools/make-opencode --all --ver 1.2.10 --pkg both

# runtime preparation
./tools/produce-local.sh 1.2.10

# plugin lifecycle
./tools/plugin-manager.sh install
./tools/plugin-manager.sh update
./tools/plugin-manager.sh rollback

# diagnostics + matrix
./tools/plugin-selfcheck.sh
VERS='1.2.9 1.2.10' ./tools/upgrade-matrix.sh
```
