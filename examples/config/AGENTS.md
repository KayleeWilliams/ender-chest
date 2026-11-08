# Editing this config

This repository is a machine-config checkout that `ec` applies. `agents/shared/AGENTS.md` holds the user's global agent instructions; this file is about editing the checkout itself. `ender-chest.toml` lists what sync applies, and its first lines link to the reference for each key.

A new home file needs both its copy under `home/` and an entry in `files`. Put local skills in `skills/<name>/SKILL.md`. Keep tokens, account sessions, SSH private keys, and generated agent settings out of Git; plugins read secrets from each machine, as [secrets](https://github.com/KayleeWilliams/ender-chest/blob/main/docs/plugins.md#secrets) describes.

Check edits in a temporary home before applying them to a real machine. Sync verifies what it applied:

```sh
test_home=$(mktemp -d)
EC_NO_UPDATE=1 HOME="$test_home" ec sync --repo "$PWD" --skip-packages
```

Inspect the installed files in that directory, then delete it.

`ec push --dry-run` writes into this checkout. Review its diff before committing, and preserve unrelated edits. Update `DEVICES.md` when the user adds, renames, or retires a machine.
