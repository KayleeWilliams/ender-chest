# Editing this config

This repository is a machine-config checkout consumed by `ec`. Global agent instructions live in `agents/shared/AGENTS.md`; this file describes work on the checkout itself.

Keep shared preferences in `agents/` and managed home files in `home/`. Put local skills in `skills/<name>/SKILL.md`, and record external skill sources in `skills/manifest.json`. The CLI has a fixed managed-file list, so check support before adding a new home-file path.

Keep tokens, account sessions, SSH private keys, generated agent configs, and personal device overrides out of Git. Proxy config in Git may contain only `baseURL`. A device's proxy token belongs in `~/.config/ender-chest/secrets/cliproxyapi.json`.

Validate edits in a temporary home before applying them to a real device. From this checkout, with `ec` already installed:

```sh
test_home=$(mktemp -d)
EC_NO_UPDATE=1 HOME="$test_home" ec sync --repo "$PWD" --skip-packages
EC_NO_UPDATE=1 HOME="$test_home" ec verify --repo "$PWD"
```

Inspect the generated agent instructions, settings, and skill links in that temporary directory. The example has no external skill sources; if you add any, review the manifest before running this check because sync can download them. Delete the temporary directory after inspection.

Treat `ec push --dry-run` as a write to this checkout. Review its diff before committing, and preserve unrelated edits. Test optional desktop, SSH, and proxy operations only against devices the user asked to use.
