# PACKAGING KNOWLEDGE BASE

## OVERVIEW
`packaging/` mixes source templates/manifests with generated package outputs. Keep edits confined to source-of-truth files.

## STRUCTURE
```text
packaging/
├── deb/DEBIAN/control                # template metadata (source-of-truth)
├── pacman/PKGBUILD*                  # template/build scripts (source-of-truth)
├── pacman/select_pkgbuild.sh         # architecture selector
├── manifests/system-skills/*.json    # hook/system-skill policy manifests
├── dpkg/*.deb                        # generated outputs (do not edit)
├── dpkg/work/                        # generated staging tree (do not edit)
└── pacman/pkg/, pacman/*.pkg.tar.xz  # generated outputs (do not edit)
```

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| Deb control metadata | `deb/DEBIAN/control` | placeholder-based template consumed during package build |
| Pacman package behavior | `pacman/PKGBUILD`, `pacman/PKGBUILD.aarch64`, `pacman/PKGBUILD.armv7l` | staged-prefix install + post hooks |
| Arch switch logic | `pacman/select_pkgbuild.sh` | selects concrete PKGBUILD by `uname -m` |
| Hook manifests/policy | `manifests/system-skills/*.json` | events, compatibility gates, idempotency policy |

## CONVENTIONS
- Treat `PKGBUILD*`, deb control template, and manifests as editable source.
- Keep package post-install/upgrade hook behavior aligned with safe defaults.
- Keep architecture-specific PKGBUILD variants semantically equivalent unless architecture requires divergence.

## ANTI-PATTERNS (PACKAGING)
- Do not edit generated paths: `dpkg/work/`, `dpkg/*.deb`, `pacman/pkg/`, versioned `pacman/*.pkg.tar.xz`.
- Do not hardcode one-off local paths into templates intended for staged-prefix packaging.
- Do not bypass runtime/launcher presence checks before packaging.
