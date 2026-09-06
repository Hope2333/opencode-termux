# Make Maintainer Surface

Maintainer-only targets and tools for release operations, fleet UPX orchestration, and cache cleanup.

## Family Array Dispatch

Run multiple family chains in order with a single command:

```bash
make family=glibc,native,compressed VER=1.18.27
```

- Accepts comma or space separated family names
- Valid families: `glibc`, `native`, `compressed`
- Runs each family's full chain IN ORDER (glibc → native → compressed)
- Backward compatible: `make family-glibc VER=...`, `make family-native VER=...`, `make family-compressed VER=...` still work
- Requires `VER` (errors if unset)

## Upload / Fleet Orchestration

### Simple Upload (glibc / native)

Uploads `.deb` and `.pkg.tar.xz` directly from the make machine:

```bash
make maintain-upload TAG=Push260906
# or specific family
make maintain-upload TAG=Push260906 FAMILY=native
```

- Uses `gh release upload --clobber` per file
- Creates the release if missing (prerelease)
- Consistent with `scripts/push-stage.sh` behavior

### Fleet Compressed Upload

Distributes UPX production across configured nodes:

```bash
# initialize node config (creates template if missing)
tools/maintain.sh --nodes-init

# dry-run fleet
make maintain-upload TAG=Push260906 FAMILY=compressed DRY=1

# real fleet run
make maintain-upload TAG=Push260906 FAMILY=compressed
```

**Node config:** `artifacts/fleet-nodes.yaml` (untracked, gitignored)

Per-node fields:
- `host` / `port` / `user` / `auth` — SSH connection
- `mode`: `gh` (node runs fleet-push.py itself) or `compute` (node does UPX only; make machine ships inputs)
- `slots` — parallel UPX slots on the node
- `enabled` — whether to include this node

**Resumable production:** State tracked in `artifacts/fleet-state.json` (untracked). Reruns skip completed (node, version) pairs and retry failed ones.

**tmux hardening:** All remote work runs inside a tmux session on the node so dropped SSH connections never kill production.

## Cache Clear

Inspect or clean cache layers without touching production outputs.

### Statistics Only (default)

```bash
make clear
# or
tools/maintain.sh --clear
```

Prints per-layer `du` sizes and total. No files deleted.

### Destructive Cleanup

```bash
# clean specific layers (dry-run first)
make clear LAYERS=compressed-work,staged-trees DRY=1
# real cleanup
make clear LAYERS=compressed-work,staged-trees CONFIRM=1

# or directly
tools/maintain.sh --clear LAYERS=dpkg-work,makepkg-temp CONFIRM=1
```

**Available layers:**

| Layer | What it cleans |
|---|---|
| `transplant-work` | Module graph, revived ELF, pre-crhandler, strip.so (PRESERVES opencode-native-tui + libopencode-crhandler.so + report.json) |
| `compressed-work` | `artifacts/compressed-work/{bin,upx,stale}` |
| `staged-trees` | `artifacts/staged/*` |
| `makepkg-temp` | `packing/pacman/{src,pkg}` |
| `dpkg-work` | `packing/dpkg*/work` |
| `tmp-smoke` | TMPDIR smoke/bench/release-staging dirs |
| `gh-download-cache` | Fleet inbox download cache |
| `npm-cacache` | npm download-chain cache (`~/.npm/_cacache`; `npm pack` fetches during build) |
| `npx-cache` | npx execution cache (`~/.npm/_npx`) |

**Mutual exclusion:** `make clear` is mutually exclusive with `VER`, `VERS`, `BATCH`, `PUSH`, `family`, and any other make target. Running with these set produces a hard error.

### Post-Upload Auto-Clean

```bash
tools/maintain.sh --upload --tag PushXXXXXX --family compressed --auto-clean
```

- Precondition: `--auto-clean` requires `--upload` (hard error otherwise — caches are only
  cleaned for a build this run actually uploaded)
- Runs ONLY after a successful upload; skipped in `--dry-run` / `--no-upload` rehearsals
- Cleans THIS build's local caches: npm/npx download-chain caches + build-side clear layers
  (`gh-download-cache`, `tmp-smoke`, `transplant-work`, `compressed-work`, `staged-trees`,
  `makepkg-temp`, `dpkg-work`)
- `packing/` deliverables are never touched

## New Files

| File | Purpose | Git status |
|---|---|---|
| `tools/maintain.sh` | Unified maintainer CLI (upload + clear engines) | Tracked (new source) |
| `tools/clear-layers.tsv` | Layer index for clear engine | Tracked (new source) |
| `artifacts/fleet-nodes.yaml` | Node config for fleet upload | Untracked (gitignored) |
| `artifacts/fleet-state.json` | Fleet production state journal | Untracked (gitignored) |

## Unified DB Sync

Refresh the unified `hope2333.db.tar.gz` on all 5 release CDNs (CDN-first,
Pages-fallback doctrine). Fetches the CI-built db from the Pages fallback,
sanity-checks it (>=8 entries), then clobber-uploads to each repo's rolling
release (MiMoCode pinned to Push260829; the other four resolve latest at
runtime). Run after any repo ships a new release.

```bash
# dry-run
make sync-db DRY=1
# real run
make sync-db
```
