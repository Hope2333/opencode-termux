[Español](./README.es.md) | [English](./README.md) | [简体中文](./README.zh.md) | [繁體中文](./README.zht.md) | [日本語](./README.ja.md)

# opencode-termux

OpenCode en Termux. Asistente de programación con IA, runtime bionic nativo, sin dependencias de glibc.

![opencode v2 TUI](./assets/screenshots/opencode-v2-tui.webp)

## Instalación rápida

```bash
curl -fsSL https://opencode.ai/install.sh | bash
```

Esto instala el comando `opencode`. Tras la instalación, actualiza con el gestor de paquetes:

```bash
# Termux (predeterminado)
pkg upgrade opencode

# pacman (si está inicializado)
pacman -Syu opencode
```

## Qué es esto

[OpenCode](https://opencode.ai) es un asistente de programación para terminal con IA. Este proyecto lo empaqueta para [Termux](https://termux.dev) en Android, ofreciendo binarios bionic nativos sin dependencias de glibc.

Cinco familias de paquetes en dos generaciones, instalables en paralelo (v1 y v2 coexisten):

| Paquete | Gen | Runtime | Tamaño | TUI | Notas |
|---------|-----|---------|--------|-----|-------|
| `opencode` | v2 | Bionic nativo | ~66 MB | Completa | Línea principal, recomendado |
| `opencode-wrapper` | v2 | Bun-termux-loader | ~50 MB | Completa | Apéndice wrapper v2 |
| `opencode1` | v1 | Bionic nativo | ~40 MB | Completa | Línea principal v1 |
| `opencode1-wrapper` | v1 | Payload runtime glibc | ~40 MB | Completa | Apéndice wrapper v1 |
| `opencode1-compressed` | v1 | Bionic nativo (UPX) | ~56 MB | Completa | UPX externalizado (`.pkg.tar.gz`) |

Dentro de una generación elige exactamente UNO de native / wrapper / compressed; v1 (`opencode1*`) y v2 (`opencode*`) coexisten.

**Línea principal** = bionic nativo (`opencode`). Cero glibc, Android API >= 28, TUI completa vía libopentui.so bionic.

## Instalar vía pacman (opcional)

Termux usa `apt` por defecto. Si prefieres `pacman`:

```bash
curl -fsSL https://opencode.ai/install-pacman.sh | bash
```

Luego instala:

```bash
pacman -S opencode
```

## Actualizar

```bash
# apt (predeterminado)
pkg upgrade opencode

# pacman
pacman -Syu opencode
```

## Requisitos

- Android API >= 28 (Android 9.0+)
- Termux (F-Droid o release de GitHub)
- ~200 MB de espacio libre

## Paquetes

### Lanzamientos estables

Los paquetes se publican en [GitHub Releases](https://github.com/Hope2333/opencode-termux/releases) con tags rotativos:

- `Push260922` -- **RC3**: v2.0.[0-12] native y wrapper + v1.18.[30-32] tres familias, todo PKGREL=3 (70 assets, verificados por digest)
- `Push260912` -- archivado (prerelease)

### Formatos de paquete

- **deb**: `opencode_<ver>_aarch64.deb` (Termux apt)
- **pacman**: `opencode-<ver>-<rel>-aarch64.pkg.tar.xz` (Termux pacman; `rel` actual = 3)
- v1 compressed: `opencode1-compressed-<ver>-<rel>-aarch64.pkg.tar.gz` (ojo al `.gz`)

## Compilar desde el código fuente

Requiere `make`, `python3`, `clang` y `upx` (opcional).

```bash
# Compilar binario bionic nativo
make build-native VER=2.0.0

# Compilar variante comprimida (UPX)
make build-native-upx VER=2.0.0

# Compilar paquete deb
make deb-native VER=2.0.0

# Compilar paquete pacman
make pacman-native VER=2.0.0
```

Consulta [docs/50-automation/50-make-maintainer.md](docs/50-automation/50-make-maintainer.md) para la referencia completa de compilación.

## v1 y v2 (dos generaciones)

v2 (`opencode*`, 2.0.x) es la línea principal; v1 (`opencode1*`, 1.18.30–32) se mantiene y **coexiste** con v2 — instala ambos en paralelo:

```bash
pacman -S opencode            # línea principal v2
pacman -S opencode1           # línea principal v1
```

Dentro de una generación, native / wrapper / compressed son mutuamente excluyentes (elige uno). El antiguo nombre `opencode-glibc` está retirado — renombrado a `opencode1-wrapper` (v1) / reemplazado por `opencode-wrapper` (v2).

## Documentación técnica

- [docs/10-build/14-transplant-pipeline.md](docs/10-build/14-transplant-pipeline.md) -- Pipeline de trasplante del runtime
- [docs/99-reference/comparison-runtime-lines.md](docs/99-reference/comparison-runtime-lines.md) -- Comparación de líneas de runtime
- [docs/20-packaging/23-dual-track-install.md](docs/20-packaging/23-dual-track-install.md) -- Guía de instalación de doble vía
- [docs/50-automation/50-make-maintainer.md](docs/50-automation/50-make-maintainer.md) -- Referencia del Makefile

## 💬 Comunidad y Discussions

![Discussions](https://raw.githubusercontent.com/Hope2333/opencode-termux/native-android/assets/discussions-banner.svg)

Charla, preguntas e ideas. RC3 renovó toda la familia en dos generaciones: 13 versiones v2 (native y wrapper) + 3 familias v1 (1.18.30–32), todo con PKGREL=3 y 70 assets verificados por digest. v1 (`opencode1*`) y v2 (`opencode*`) coexisten.

[![General](https://img.shields.io/badge/General-charlar-3fb950?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/general)
[![Q&A](https://img.shields.io/badge/Q%26A-ayuda-1f6feb?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/q-a)
[![Ideas](https://img.shields.io/badge/Ideas-ideas-9e6a03?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/ideas)
[![Announcements](https://img.shields.io/badge/Announcements-anuncios-db6d28?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/announcements)
[![Show and tell](https://img.shields.io/badge/Show_and_tell-muestra-8957e5?style=for-the-badge)](https://github.com/Hope2333/opencode-termux/discussions/categories/show-and-tell)

## Licencia

OpenCode es de código abierto. Este proyecto de empaquetado sigue la misma licencia.
