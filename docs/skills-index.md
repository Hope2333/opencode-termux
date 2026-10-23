# Termux skills index (concise)

Use this index in prompts to recall the right doc and known fixes quickly.

## Plugin + hook
- `plugin-management.md` — install/update/rollback commands; prefer `file://` plugin paths on Termux for stability.
- `plugin-packaging-design.md` — package-manager plugin model; avoid `dist` as plugin name by pointing file-plugin to root `index.js`.
- `system-skills-hook-architecture.md` — hook events, safe defaults (`network=0`, `strict=0`), registry + blocklist paths.

## Runtime + troubleshooting
- `execution-checklist.md` — install/test runbook; native mainline is zero-glibc (glibc packages only for the wrapper appendix); verify with `opencode --version`.
- `transplant.md` / `scripts/build-bionic.sh` — canonical runtime build flows (A line revival / B line compile); `13-opencode-runtime-build.md` is a historical wrapper-era snapshot.
- `22-termux-services-opencode-web.md` — service behavior; for runit issues, check `$PREFIX/var/service/opencode-web`.
- `incidents/2026-02-23-opencode-web-termux-so-avalanche.md` — `.so` restart storm RCA and mitigation.

## Build / packaging (URL only)
- DEB packaging: https://github.com/Hope2333/opencode-termux/blob/main/docs/20-packaging-deb.md
- Pacman packaging: https://github.com/Hope2333/opencode-termux/blob/main/docs/21-packaging-pkg-tar-xz.md
- Local production policy: https://github.com/Hope2333/opencode-termux/blob/main/docs/local-production.md
