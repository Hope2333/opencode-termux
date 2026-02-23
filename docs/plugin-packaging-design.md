# Plugin Packaging Design (Phase C)

Goal: package-manager-driven plugin lifecycle for both termux-apt and termux-pacman.

## Package model

Primary package per plugin:

- `opencode-plugin-<name>`
- install built plugin files to:
  - `$PREFIX/lib/opencode/plugins/<name>/package/dist/index.js`

Optional source package for patch workflows:

- `opencode-plugin-<name>-source`
- contains source snapshot and patch metadata

## Registration strategy

Use explicit registration command instead of silent config mutation in package install.

Package post-install prints registration and verification commands.

## Update and rollback

- update via package manager version bump
- local snapshots via `tools/plugin-manager.sh`
- patch recovery via `patch-export` and `patch-apply`
