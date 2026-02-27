# System Skills + Hook Architecture (Phase C extension)

This document defines the package-mode system skill and hook model used to reduce plugin breakage during install/upgrade.

## Goals

- keep package install/upgrade **non-interactive**
- keep hook behavior **idempotent**
- default to **fail-soft** (warn, continue)
- avoid silent user config mutation by default
- support machine1 -> machine2 upgrade/downgrade simulation with hook visibility

## Installed components

- Hook runner:
  - `$PREFIX/lib/opencode/tools/run-system-skills.sh`
- System skill manifests:
  - `$PREFIX/lib/opencode/system-skills/*.json`
- Source manifests in repo:
  - `packaging/manifests/system-skills/*.json`

## Current manifest model

Example: `packaging/manifests/system-skills/omo.json`

Key fields:

- `plugin_id`, `repo`
- `events` (`post_install`, `post_upgrade`)
- `auto_install_latest` / `auto_update`
- `minimum_core_version`, `maximum_core_version`, `blocked_core_versions`
- `policy`, `idempotency_key`

Global blocklist file:

- `$PREFIX/lib/opencode/system-skills/blocklist.json`

## Hook policy defaults (safe)

- `OPENCODE_HOOK_STRICT=0`
  - hook failures are logged and do not fail package transactions
- `OPENCODE_HOOK_ENABLE_NETWORK=0`
  - no automatic network install/update during package install/upgrade

This keeps apt/pacman upgrades stable when network or plugin upstream is unstable.

## Enabling experimental networked automation

Only for controlled environments (e.g., machine1):

```bash
OPENCODE_HOOK_ENABLE_NETWORK=1 OPENCODE_HOOK_STRICT=0 opencode --version
```

## Lifecycle flow

1. package install/upgrade triggers post hook (`postinst` / `post_install` / `post_upgrade`)
2. hook runner loads system/user manifests
3. compatibility gate checks run (`min/max`, manifest blocked versions, global blocklist)
4. idempotency marker check runs (`$PREFIX/var/lib/opencode/hooks/*.done`)
5. matching event manifests are processed
6. optional plugin-manager install/update runs only if network enable flag is set
7. self-check runs as read-only verification
8. registry is updated (`$PREFIX/share/opencode/system-skills-registry.json`)

Note: blocklist source of truth is currently:

- `$PREFIX/lib/opencode/system-skills/blocklist.json`

## Simulation integration (machine1 -> machine2)

`tools/upgrade-matrix.sh` now:

- validates deb payload structure (must contain runtime binary)
- executes install/upgrade/downgrade/reinstall sequence
- calls hook runner after baseline install and after each upgrade step
- logs matrix output on machine2

## Recommended document split for system-skillization

- High-level policy: `README.md` (brief)
- Canonical architecture: this file
- Operational runbook: `docs/execution-checklist.md`
- Plugin package model: `docs/plugin-packaging-design.md`
- Day-to-day plugin operations: `docs/plugin-management.md`
