# Credential handling

The source repo contains only code, documentation, and synthetic examples. Personal config belongs in a separate repository. Credentials belong on the devices that use them.

Secrets that plugin settings use live in `~/.config/ender-chest/secrets/NAME`, mode `0600`, inside a directory with mode `0700`. These are plaintext local credentials protected by filesystem permissions, not an encrypted vault. A plugin receives only the secrets named in its own settings. Generated agent settings contain the secrets that plugins contribute, with mode `0600`.

`ec push` captures and stages only the paths [sync and push](docs/config.md#sync-and-push) lists. It does not capture the secrets directory, generated agent settings, SSH private keys, or provider authentication directories. It refuses a checkout that contains a secret or another known credential path. This is not a guarantee that arbitrary dotfiles or skills contain no secrets. Review config changes before committing them.

`ec secret set` reads a value from a hidden prompt or stdin. It never accepts secrets as CLI arguments. Plugin HTTP requests pass authentication to curl through stdin. Release checks pass a GitHub token to curl through stdin, never as an argument. `ec kde unlock` sends the wallet password over SSH stdin and keeps it in the Mac's Keychain. `ec cliproxyapi run` places the proxy key in the child process's environment, so only run programs you trust.

`ec update` and `ec sync` install a release binary only after its sha256 matches the release manifest and the new binary runs once. The release manifest comes from the same GitHub release as the binary, so the checksum detects a damaged download, not a compromised release.

CI and the hooks in `.githooks` scan commits with Gitleaks and `tools/check-private.sh`, which blocks the maintainer's real hostnames, addresses, and keys. A clean scan does not prove that every secret was caught.

Do not include live credentials in issues, logs, screenshots, or test fixtures. Revoke or replace a credential if it was exposed. Deleting it from the latest commit does not invalidate copies in history.
