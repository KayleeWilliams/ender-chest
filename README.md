# Ender Chest

`ec` keeps development machines in sync. It applies a Git-backed config checkout, installs shared agent skills, and checks or updates machines over Tailscale and SSH.

The CLI is native Zig for macOS and Linux. Installed binaries need neither Node nor Zig. Git, curl, and SSH handle repository, HTTP, and remote operations.

## Install

The recommended installer downloads a native binary for macOS 13+ or Linux, on ARM64 or x86-64. It verifies the release's SHA-256 checksum and installs `ec` in `~/.local/bin`. It needs no compiler, Node, or sudo.

The repository is currently private. With [GitHub CLI](https://cli.github.com/) authenticated to an account that has access, run:

```sh
gh release download --repo KayleeWilliams/ender-chest --pattern install.sh --output - | sh
export PATH="$HOME/.local/bin:$PATH"
ec --help
```

Once the repository is public, users can install with curl:

```sh
curl -fsSL https://github.com/KayleeWilliams/ender-chest/releases/latest/download/install.sh | sh
```

Add the PATH line to your shell profile if needed. The installer leaves shell profiles and machine config untouched. It uses `sha256sum` or `shasum` for verification. A failed download or checksum leaves the existing binary in place.

Pass `--version 0.0.1` to pin a release or `--install-dir /your/bin` to choose a destination. Append these options to `sh -s --`:

```sh
gh release download --repo KayleeWilliams/ender-chest --pattern install.sh --output - \
  | sh -s -- --version 0.0.1 --install-dir "$HOME/.local/bin"
```

`EC_VERSION` and `EC_INSTALL_DIR` set the same defaults. `EC_RELEASE_REPO=owner/repo` selects a fork's releases. The installer uses authenticated `gh` when available and curl for public downloads otherwise.

### npm

Each [release](https://github.com/KayleeWilliams/ender-chest/releases) also includes an npm tarball with all four native binaries. It requires Node 20+ and runs without install scripts or additional downloads:

```sh
gh release download v0.0.1 --repo KayleeWilliams/ender-chest --pattern ender-chest-0.0.1.tgz
npm install --global ./ender-chest-0.0.1.tgz
ec --help
```

The package is prepared as `ender-chest`, with the command `ec`. It has not been published to the npm registry. `npm install -g ender-chest` becomes available after a separate public publication.

## Create your config repo

Clone the examples and copy the starter to a separate directory:

```sh
git clone --depth 1 https://github.com/KayleeWilliams/ender-chest.git ~/ender-chest
cp -R ~/ender-chest/examples/config ~/my-machine-config
git -C ~/my-machine-config init
```

The [starter guide](examples/config/README.md) explains the shared `AGENTS.md`, Claude/Codex/Grok preferences, bundled review skill, and device-local overrides. Edit the shared instructions to match how you work. Set your Git identity in `~/.gitconfig.local`. The example contains no credentials and enables no plugins.

For instructions tied to an individual codebase, see the separate [project example](examples/project/README.md).

```sh
ec sync --repo ~/my-machine-config --skip-packages
ec verify
```

Sync writes the home files listed in `ender-chest.toml`, including shell and Git config. The first time it replaces a file that differs, it keeps your old copy under `~/.config/ender-chest/backup/`.

`--skip-packages` skips Brewfiles and setup steps. Without it, the starter's sync installs Homebrew if needed, its Brewfiles, Oh My Zsh, shell plugins, and a Node version through fnm.

Add a remote for your config repo if you want to sync between machines. Keep that repo private if it contains personal hostnames or other private settings. The CLI source and release history remain separate from your config.

## Commands

```sh
ec sync                     # pull and apply this machine's config
ec push                     # capture portable config, commit, and push
ec push --dry-run           # capture into the checkout without committing
ec verify                   # read-only checks
ec fleet                    # inspect machines over Tailscale and SSH
ec fleet sync               # sync reachable machines that are behind
ec plugin list              # show enabled plugins and their commands
ec secret set NAME          # save a secret that plugin settings use
```

`push --dry-run` still writes files into the checkout. A push does not update other machines. A dirty checkout skips pulling and applies local files. A failed pull also applies local files with a warning.

Use `ec <command> --help` for options and effects. `--json` produces one result on stdout, with diagnostics on stderr. `ec --help --json` describes commands, typed options, defaults, and side effects without reading config or making network requests.

Config selection is `--repo`, then `EC_REPO`, then a config checkout in the current directory, then the path saved by the last sync. An implicitly selected linked worktree resolves to its primary checkout. Use `--repo` to apply a particular worktree.

## ender-chest.toml

`ender-chest.toml` at the root of your config repo lists what sync applies:

```toml
files = [
  ".zshrc",
  { path = ".ssh/config", mode = "600" },
  { path = ".config/zed/settings.json", profiles = ["mac"] },
  { path = ".gitconfig.local", from = "git/gitconfig.local.example", once = true },
]

[packages]
brewfiles = ["tools/Brewfile", { path = "tools/Brewfile.mac", profiles = ["mac"] }]

[[setup]]
name = "Oh My Zsh"
creates = "~/.oh-my-zsh"
run = "curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh"

[plugins.executor]
url = "https://mcp.example.test:4312"
key = { secret = "executor" }
```

- `files` copies `home/<path>` in the checkout to `~/<path>`. `mode`, `os` (`macos` or `linux`), and `profiles` narrow an entry, and `from` reads a different checkout path. A `once` file is created when missing and then belongs to the machine: sync never overwrites it and push never captures it.
- `[packages]` Brewfiles and `[[setup]]` steps run on each sync. Steps run with `/bin/sh` from the checkout. A step whose `creates` path exists is skipped. `os` and `profiles` work here too.
- `ec push` copies the other listed files back into the checkout. It stages only `home/`, `skills/`, `agents/`, `plugins/`, `ender-chest.toml`, `ender-chest.lock`, and `from` paths.

The profile is `mac` on macOS and `cloud` elsewhere, or when a CI or cloud-agent variable is set. Pass `--profile NAME` to choose one.

## Plugins

Plugins add commands to `ec`, and can give Claude Code, Codex, and Grok an MCP server or a model provider. These ship with `ec`:

| Plugin | Use |
| --- | --- |
| `cliproxyapi` | Route the agents through a [CLIProxyAPI](docs/setup.md#cliproxyapi-host) server. |
| `executor` | Share one Executor MCP server across machines. |
| `wol` | Wake a machine with Wake-on-LAN and wait until it answers. |
| `kde` | Unlock KWallet and shut down a KDE Plasma machine over SSH. |
| `quiet` | Stop stale dev servers and containers before a benchmark. |

Enable one with a `[plugins.NAME]` table. `ec NAME --help` lists its commands and settings. When you remove a plugin and sync, `ec` removes what it added to agent settings and keeps your other MCP servers and providers.

You can write your own plugin in any language and load it from your config repo or a GitHub repository. See [plugins](docs/plugins.md).

## Secrets

`ec secret set NAME` reads a value from a hidden prompt, or from stdin when piped, and stores it in `~/.config/ender-chest/secrets/NAME` with mode `0600`. Refer to it from a plugin setting as `{ secret = "NAME" }`. `ec secret list` prints names only, and `ec secret remove NAME` deletes one.

Secrets stay on the machine. Sync writes the ones that plugins contribute into agent settings, so those settings stay on-device too. Push does not capture them, and it refuses a checkout that contains a secret file. See [credential handling](SECURITY.md).

## Updates

CLI releases come from `KayleeWilliams/ender-chest`, independently of your config remote. `EC_RELEASE_REPO=owner/repo` selects a fork's releases. While releases are private, downloads need `GH_TOKEN`, `GITHUB_TOKEN`, or `gh auth login` on each device. These credentials stay local.

Sync checks for the latest CLI release, verifies its checksum, installs it in `~/.local/bin/ec`, and resumes. `EC_NO_UPDATE=1` disables release checks. Public release checks need no GitHub credentials.

If you installed through npm or chose a custom directory, rerun that installation method to replace its copy. For npm, download and install the tarball from the newer release.

The manual release workflow builds ARM64 and x86-64 binaries for macOS 13+ and Linux musl.

## Development

Use Node 24 and pnpm 11.25.0, pinned in the repository. Workspace commands run through Turborepo. Ultracite supplies Oxlint and Oxfmt, with the same custom anti-slop rules as Inth. Zig uses its native formatter.

```sh
git clone https://github.com/KayleeWilliams/ender-chest.git
cd ender-chest
pnpm install
git config core.hooksPath .githooks
pnpm check
pnpm format
pnpm build
```

The source launcher `./ec` builds and runs the CLI. The build wrapper downloads Zig 0.16.0 when needed and verifies its pinned checksum. The first build needs Git, curl, tar, and xz. To install your build:

```sh
mkdir -p ~/.local/bin
install -m 755 packages/ec/zig-out/bin/ec ~/.local/bin/ec
```

The hooks in `.githooks` run `tools/check-private.sh` before each commit and push. It runs Gitleaks when installed, and blocks any fixed string listed in `~/.config/ender-chest/private-patterns`. Use that file for your own hostnames, addresses, and keys; it stays outside the repo.

`pnpm check` runs lint, type checks, Vitest integration tests, and native Zig tests. The integration tests exercise the compiled CLI in temporary homes and Git repos, including HTTP requests, UDP packets, config uploads, and local credential handling.

```text
packages/ec/src/      native Zig implementation
packages/ec/test/     Vitest integration tests and fixtures
examples/config/     example machine config
tools/               shared build and lint tooling
docs/                setup guides
```

Run `pnpm --filter ender-chest <script>` to target the CLI package. `./ec` builds and runs it without requiring Node. CI checks the workspace on macOS and Linux, builds all four native targets, and scans Git history for secrets.

The manual release workflow packages the binaries, checksums, installer, and npm tarball. It checks the native targets and shared source hash, then installs the tarball offline and runs `ec --version` before publishing to GitHub Releases. It does not publish to npm or change repository visibility.

[FX](https://github.com/vercel-labs/fx) informed the native binary and Zig test setup. [Inth](https://github.com/inthhq/inth/tree/main/packages/cli) informed grouped commands, scoped help, typed discovery, and stable errors. Ender Chest uses its own implementation.

MIT licensed. The native binaries include the components listed in [third-party notices](THIRD_PARTY_NOTICES.txt).
