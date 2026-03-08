# Plugin Management (Online install + self-update + rollback)

For Termux, user-friendly plugin management should be based on **local-plugin file URLs**, not direct package-name plugin install.

Main packaging/build route for external plugins now lives in:

- `https://github.com/Hope2333/opencode-plugins-termux`

## Why

`plugin: ["oh-my-opencode"]` can trigger runtime installation behavior and native dependency breakage on Termux/Bionic after upstream updates.

## Recommended path

- Online source of truth: plugin Git repo
- Local runtime path: `~/.config/opencode/local-plugins/<name>/index.js`
- Config registration: `file:///.../index.js`
- Snapshots for rollback before every update

## Commands

```bash
./tools/plugin-manager.sh install                  # install OMO from GitHub
./tools/plugin-manager.sh update                   # self-update (git pull + rebuild)
./tools/plugin-manager.sh migrate-installed        # switch HOME local-plugin entry to system package path
./tools/plugin-manager.sh list-snapshots           # view recoverable snapshots
./tools/plugin-manager.sh rollback                 # restore latest snapshot
./tools/plugin-manager.sh patch-export             # export local patch file
./tools/plugin-manager.sh patch-apply oh-my-opencode /path/to.patch
./tools/plugin-manager.sh verify-config 7600       # check MCPs/agents from /config
```

External plugin builder route (recommended for reproducible plugin packaging):

```bash
git clone https://github.com/Hope2333/opencode-plugins-termux.git
cd opencode-plugins-termux
make list
make all PLUGIN=omo MODE=source
```

## Recovery model (self patch + rollback)

1. Update plugin (snapshot auto-created)
2. If broken, rollback snapshot immediately
3. If custom fix is needed, patch local repo and export patch
4. Re-apply patch after future upstream updates as needed

This gives both convenience and recoverability.

## Resilience behavior (network / upstream instability)

`plugin-manager.sh` now includes additional safeguards:

- git clone/fetch/pull retry with exponential backoff (configurable)
- automatic rollback to latest snapshot when install/update fails
- state file output with last action/status/error metadata

Defaults and knobs:

- `PLUGIN_GIT_RETRY_MAX=3`
- `PLUGIN_GIT_RETRY_DELAY=2` (seconds, exponential backoff)
- `PLUGIN_FORCE_NPM=1` (force npm path, skip bun install when bun causes permission/platform issues)
- state file: `~/.config/opencode/plugin-manager-state.json`

Default safety recommendation:

- Prefer local file plugin registration (`file:///.../index.js`) on Termux.
- Avoid bare package-name plugin entries in `opencode.json` on Termux if plugin has native or postinstall-heavy deps.

Suggested replacement candidate for oauth-login style plugin flow:

- `https://github.com/andyvandaric/opencode-ag-auth`
  - active repository and explicit OpenCode auth plugin focus
  - supports local file plugin registration path for Termux-first setups

## Seamless migration to packaged plugin path

If you previously used a HOME local-plugin entry like:

- `file://~/.config/opencode/local-plugins/oh-my-opencode/index.js`

and now have the packaged plugin installed, you can migrate only the plugin entry while
leaving the rest of `opencode.json` untouched:

```bash
./tools/plugin-manager.sh migrate-installed
```

Current target path:

- `file:///data/data/com.termux/files/usr/lib/opencode/plugins/oh-my-opencode/dist/index.js`

The command snapshots `opencode.json` first and only rewrites matching OMO/plugin-manager
local entries.
