# Credential handling

The source repo contains only code, documentation, and synthetic examples. Personal config belongs in a separate repository. Credentials belong on the devices that use them.

Secrets that plugin settings use live in `~/.config/ender-chest/secrets/NAME`, mode `0600`, inside a directory with mode `0700`. These are plaintext local credentials protected by filesystem permissions, not an encrypted vault. A plugin receives only the secrets named in its own settings. Generated Claude, Codex, and Grok settings contain the secrets that plugins contribute, with mode `0600`.

`ec push` captures only the files listed in `ender-chest.toml`, never `once` files, and stages only the config repo's own paths. It does not capture the secrets directory, generated agent settings, SSH private keys, or provider authentication directories. It refuses a checkout that contains a secret or another known credential path. This is not a guarantee that arbitrary dotfiles or skills contain no secrets. Review config changes before committing them.

`ec secret set` reads a value from a hidden prompt or stdin. It never accepts secrets as CLI arguments. Plugin HTTP requests pass authentication to curl through stdin. Release checks pass a GitHub token to curl in a temporary config file with mode `0600`, never as an argument. `ec kde unlock` sends the wallet password over SSH stdin and keeps it in the Mac's Keychain. `ec cliproxyapi run` places the proxy key in the child process's environment, so only run programs you trust.

`ec update` and `ec sync` install a release binary only after its sha256 matches the release manifest. `ec update` also runs the new binary once before it replaces the old one. The release manifest comes from the same GitHub release as the binary, so the checksum detects a damaged download, not a compromised release.

CI scans every commit with Gitleaks and with `tools/check-private.sh`. That script matches a list of the maintainer's real hostnames, addresses, and keys, stored outside the repo and in the `PRIVATE_PATTERNS` Actions secret. The same check runs in the pre-commit and pre-push hooks in `.githooks`. Review examples, documentation, release artifacts, and new files for private hostnames and personal information. A clean scanner result does not prove that every possible secret has been detected.

Do not include live credentials in issues, logs, screenshots, or test fixtures. Revoke or replace a credential if it was exposed. Deleting it from the latest commit does not invalidate copies in history.
