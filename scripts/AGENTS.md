# SCRIPTS KNOWLEDGE BASE

## OVERVIEW
`scripts/` owns staging, packaging invocation, hook execution, and CI helper scripts.

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| Stage install prefix | `build.sh`, `common.sh` | copies sources/runtime into staged prefix and writes build metadata |
| Runtime launcher behavior | `launcher.sh` | tty cleanup, lock cleanup, runtime/CLI dispatch |
| Debian packaging | `package/package_deb.sh` | validates staged tree, writes control/postinst, builds `.deb` |
| Pacman packaging | `package/package_pacman.sh` | rewrites pkgver/pkgrel and runs `makepkg` |
| System skill hooks | `hooks/run-system-skills.sh` | manifest load, compatibility gate, idempotency/state logging |
| armv7 CI attempts | `ci/*.sh` | Bun/opencode compile attempts + JSON status outputs |

## CONVENTIONS
- Keep strict shell mode (`set -euo pipefail`) and explicit command checks (`command -v ...`).
- Keep staging/package scripts deterministic: validate staged runtime/launcher before packaging.
- Hook invocations in package lifecycle stay safe-by-default (`OPENCODE_HOOK_STRICT=0`, `OPENCODE_HOOK_ENABLE_NETWORK=0`).
- Shared helpers belong in `common.sh`; avoid duplicating logging/path helpers across scripts.

## ANTI-PATTERNS (SCRIPTS)
- Do not point staging prefixes to shared install trees; `build.sh` removes target subtrees with `rm -rf`.
- Do not run `package_*` scripts before `scripts/build.sh` (missing staged runtime/launcher fails packaging).
- Do not assume CI helper outputs (`scripts/ci/*`) are final release artifacts.
- Do not bypass hook compatibility/idempotency checks in `hooks/run-system-skills.sh`.

## COMMANDS
```bash
# stage prefix
./scripts/build.sh

# package builds
./scripts/package/package_deb.sh
./scripts/package/package_pacman.sh

# manual hook run
OPENCODE_HOOK_STRICT=0 OPENCODE_HOOK_ENABLE_NETWORK=0 \
  ./scripts/hooks/run-system-skills.sh post_install
```
