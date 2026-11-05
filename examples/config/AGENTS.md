# Editing this config

This repository is a machine-config checkout consumed by `ec`. Global agent instructions live in `agents/shared/AGENTS.md`; this file describes work on the checkout itself.

Keep shared preferences in `agents/` and managed home files in `home/`. Put local skills in `skills/<name>/SKILL.md`, and record external skill sources in `skills/manifest.json`. A new home file needs both its copy under `home/` and an entry in `ender-chest.toml`'s `files` list. Setup steps, Brewfiles, and plugins are listed there too.

Keep tokens, account sessions, SSH private keys, generated agent configs, and personal device overrides out of Git. Plugin settings in `ender-chest.toml` refer to secrets as `{ secret = "NAME" }`; each device stores the value with `ec secret set NAME` in `~/.config/ender-chest/secrets/`.

Validate edits in a temporary home before applying them to a real device. From this checkout, with `ec` already installed:

```sh
test_home=$(mktemp -d)
EC_NO_UPDATE=1 HOME="$test_home" ec sync --repo "$PWD" --skip-packages
EC_NO_UPDATE=1 HOME="$test_home" ec verify --repo "$PWD"
```

Inspect the generated agent instructions, settings, and skill links in that temporary directory. The example has no external skill sources; if you add any, review the manifest before running this check because sync can download them. Delete the temporary directory after inspection.

Treat `ec push --dry-run` as a write to this checkout. Review its diff before committing, and preserve unrelated edits. Test plugin commands that reach other machines, such as `wol`, `kde`, and proxy restarts, only against devices the user asked to use.
