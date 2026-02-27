# Plugin Management (Online install + self-update + rollback)

For Termux, user-friendly plugin management should be based on **local-plugin file URLs**, not direct package-name plugin install.

## Why

`plugin: ["oh-my-opencode"]` can trigger runtime installation behavior and native dependency breakage on Termux/Bionic after upstream updates.

## Recommended path

- Online source of truth: plugin Git repo
- Local runtime path: `~/.config/opencode/local-plugins/<name>/package/dist/index.js`
- Config registration: `file:///.../dist/index.js`
- Snapshots for rollback before every update

## Commands

```bash
./tools/plugin-manager.sh install                  # install OMO from GitHub
./tools/plugin-manager.sh update                   # self-update (git pull + rebuild)
./tools/plugin-manager.sh list-snapshots           # view recoverable snapshots
./tools/plugin-manager.sh rollback                 # restore latest snapshot
./tools/plugin-manager.sh patch-export             # export local patch file
./tools/plugin-manager.sh patch-apply oh-my-opencode /path/to.patch
./tools/plugin-manager.sh verify-config 7600       # check MCPs/agents from /config
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
