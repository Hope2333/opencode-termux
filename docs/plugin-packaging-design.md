# Plugin Packaging Design (Phase C)

Goal: package-manager-driven plugin lifecycle for both termux-apt and termux-pacman.

## Package model

Primary package per plugin:

- `opencode-plugin-<name>`
- install built plugin files to:
- `$PREFIX/lib/opencode/plugins/<name>/index.js`

Optional source package for patch workflows:

- `opencode-plugin-<name>-source`
- contains source snapshot and patch metadata

## Registration strategy

Use explicit registration command instead of silent config mutation in package install.

Package post-install prints registration and verification commands.

## System-level skills and hooks (package mode)

To improve plugin safety across core upgrades, package mode now supports a system-skill manifest + hook runner flow:

- Manifests location in source tree:
  - `packaging/manifests/system-skills/*.json`
- Installed location:
  - `$PREFIX/lib/opencode/system-skills/*.json`
- Hook runner (installed):
  - `$PREFIX/lib/opencode/tools/run-system-skills.sh`

Default policy is conservative:

- `OPENCODE_HOOK_STRICT=0` (soft-fail, warn and continue)
- `OPENCODE_HOOK_ENABLE_NETWORK=0` (no silent network install/update)
- user config mutation is avoided by default

Compatibility/registry policy (phase-2):

- per-skill manifest supports:
  - `minimum_core_version`
  - `maximum_core_version`
  - `blocked_core_versions`
- global blocklist:
  - `$PREFIX/lib/opencode/system-skills/blocklist.json`
- registry output:
  - `$PREFIX/share/opencode/system-skills-registry.json`

Optional networked auto actions can be enabled by environment:

```bash
OPENCODE_HOOK_ENABLE_NETWORK=1 opencode --version
```

Use this only in controlled environments (for example, machine1 experimental builds).

## Update and rollback

- update via package manager version bump
- local snapshots via `tools/plugin-manager.sh`
- patch recovery via `patch-export` and `patch-apply`
