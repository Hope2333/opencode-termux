# Termux skills index (concise)

Use this index in prompts to recall the right doc and known fixes quickly.

## Plugin + hook
- `../50-automation/53-plugin-management.md` — install/update/rollback commands; prefer `file://` plugin paths on Termux for stability.
- `../20-packaging/25-plugin-packaging-design.md` — package-manager plugin model; avoid `dist` as plugin name by pointing file-plugin to root `index.js`.
- `../20-packaging/26-system-skills-hook-architecture.md` — hook events, safe defaults (`network=0`, `strict=0`), registry + blocklist paths.

## Runtime + troubleshooting
- `../40-release/40-execution-checklist.md` — install/test runbook; if runtime missing, verify `glibc` + `openssl-glibc` and `opencode --version`.
- `../10-build/13-opencode-runtime-build.md` — runtime build flow (official arm64 + loader); use this if `opencode` fails to start.
- `../20-packaging/22-termux-services-opencode-web.md` — service behavior; for runit issues, check `$PREFIX/var/service/opencode-web`.
- `../90-incidents/90-2026-02-23-opencode-web-termux-so-avalanche.md` — `.so` restart storm RCA and mitigation.

## Build / packaging (URL only)
- DEB packaging: https://github.com/Hope2333/opencode-termux/blob/main/docs/20-packaging/20-packaging-deb.md
- Pacman packaging: https://github.com/Hope2333/opencode-termux/blob/main/docs/20-packaging/21-packaging-pacman.md
- Local production policy: https://github.com/Hope2333/opencode-termux/blob/main/docs/00-scope/03-local-production.md
