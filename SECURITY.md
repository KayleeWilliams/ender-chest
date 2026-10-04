# Credential handling

The source repo contains only code, documentation, and synthetic examples. Personal config belongs in a separate repository. Credentials belong on the devices that use them.

Proxy tokens live in `~/.config/ender-chest/secrets/cliproxyapi.json`, mode `0600`, inside a directory with mode `0700`. These are plaintext local credentials protected by filesystem permissions, not an encrypted vault. Generated Claude, Codex, and Grok settings also contain the local token with mode `0600`.

`ec push` exports only `baseURL` from the proxy endpoint file. It does not capture the secrets directory, generated agent settings, SSH private keys, or provider authentication directories. It refuses known credential paths if they are manually placed in its upload set. This is not a guarantee that arbitrary dotfiles or skills contain no secrets. Review config changes before committing them.

Setup reads tokens from a hidden prompt or stdin. It never accepts tokens as CLI arguments. HTTP requests pass authentication to curl through stdin. `ec cliproxy run` places the token in the child process's environment, so only run programs you trust.

The repository CI scans Git history with Gitleaks. Review examples, documentation, release artifacts, and new files for private hostnames and personal information. A clean scanner result does not prove that every possible secret has been detected.

Do not include live credentials in issues, logs, screenshots, or test fixtures. Revoke or replace a credential if it was exposed. Deleting it from the latest commit does not invalidate copies in history.
