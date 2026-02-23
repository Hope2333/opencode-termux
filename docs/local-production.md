# Local Production Blueprint (No GitHub Actions)

This repo intentionally disables GitHub Actions for release builds because the verified runtime path depends on a **real Termux/Android environment**.

## Canonical inputs

- Source repo: `~/develop/opencode-termux`
- Upstream runtime source: `opencode-linux-arm64@<version>` (npm package)
- Wrapper tool: `~/bun-termux-loader` (or equivalent repo with `build.py`)

## Canonical outputs

- Wrapped runtime: `artifacts/opencode/runtime/opencode-termux`
- Staged tree: `artifacts/staged/...`
- Package work dirs (generated, disposable): `packaging/deb/work`, `packaging/pacman/src`

## Rules

- **Do not use musl** as primary Termux runtime path
- **Do not use proot** as official build path
- Always verify runtime with `file` and `--version`
- Always clean generated staging/package work dirs before packaging to avoid stale version contamination

## Entrypoint

Use:

```bash
./tools/produce-local.sh 1.2.10
```

This prepares the wrapped runtime and cleans stale generated directories before package assembly.

## Plugin install/update UX

Use local-plugin mode with online fetch + local build + snapshot rollback:

```bash
./tools/plugin-manager.sh install
./tools/plugin-manager.sh update
./tools/plugin-manager.sh rollback
```

See also: `docs/plugin-management.md`.
