# Config reference

A config checkout is a Git repository that `ec sync` applies to a machine. Start from [ender-chest-template](https://github.com/KayleeWilliams/ender-chest-template); its source is [examples/config](../examples/config/README.md).

## Layout

| Path | Use |
| --- | --- |
| `ender-chest.toml` | What sync applies: home files, Brewfiles, setup steps, and plugins. Required. |
| `home/<path>` | A home file's portable copy, installed as `~/<path>` when `files` lists it. |
| `agents/shared/AGENTS.md` | Instructions for every agent. Required. |
| `agents/<name>/` | One agent's settings file, named as in [Agent instructions and settings](#agent-instructions-and-settings). Applied only on machines where that agent is installed. Optional. |
| `skills/<name>/SKILL.md` | A local skill. |
| `skills/manifest.json` | Skills from GitHub repositories. Optional. |
| `plugins/<name>/` | A plugin kept in the checkout. See [plugins](plugins.md). |
| `ender-chest.lock` | The commits of GitHub plugins. Commit it. |

Each sync saves its checkout's path in `~/.config/ender-chest/repo`. `ec sync --help` lists how commands pick a checkout when you don't pass `--repo`.

## ender-chest.toml

```toml
files = [
  ".zshrc",
  { path = ".ssh/config", mode = "600" },
  { path = ".config/zed/settings.json", profiles = ["mac"] },
  { path = ".gitconfig.local", from = "git/gitconfig.local.example", once = true },
]

[packages]
brewfiles = ["Brewfile", { path = "Brewfile.linux", os = "linux" }]

[[setup]]
name = "Oh My Zsh"
creates = "~/.oh-my-zsh"
run = "curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh"
```

### files

Each entry copies `home/<path>` in the checkout to `~/<path>`. A bare string is a path with no options.

| Key | Meaning |
| --- | --- |
| `path` | The file, relative to your home directory. |
| `from` | Read this checkout path instead of `home/<path>`. |
| `mode` | File mode, such as `"600"`. |
| `once` | Create the file when it is missing, then leave it to the machine. Sync never overwrites it and push never captures it. Without `from`, the file starts empty. |
| `os` | `macos` or `linux`. |
| `profiles` | Profile names the entry applies to. |

### packages and setup

`[packages] brewfiles` lists Brewfiles that sync installs with `brew bundle`. On macOS, sync installs Homebrew first if it is missing; elsewhere, a machine without Homebrew skips Brewfiles. An entry is a path, or a table with `path`, `os`, and `profiles`.

Each `[[setup]]` step has a `name` and a `run` command. Sync runs it with `/bin/sh` from the checkout, and skips it when its `creates` path exists. `os` and `profiles` narrow a step too. A failed step fails the sync and names the step.

`ec sync --skip-packages` skips Brewfiles and setup steps. It still applies files, agent settings, skills, and plugins.

### plugins

`[plugins.NAME]` tables enable plugins. See [plugins](plugins.md).

## Profiles

The profile is `mac` on macOS and `cloud` elsewhere, or when a CI, Codespaces, or cloud-agent variable is set. `--profile NAME` chooses one. Profile names are yours: `profiles = ["work"]` applies with `ec sync --profile work`.

## Sync and push

`ec sync` pulls a clean checkout, then applies it. A dirty checkout skips the pull, and a failed pull applies the local files with a warning. The first time sync replaces a home file or agent instructions that differ, it keeps your copy under `~/.config/ender-chest/backup/`.

`ec push` copies the listed home files and your personal skills back into the checkout, commits, and pushes when a remote is set. It never captures `once` files, and stages only `home/`, `skills/`, `agents/`, `plugins/`, `ender-chest.toml`, `ender-chest.lock`, and `from` paths; commit other files, such as Brewfiles, with Git. `ec push --dry-run` writes into the checkout without committing, so review `git diff` afterwards. To start managing a file you already have, add it to `files` and run `ec push --dry-run`.

## Agent instructions and settings

Sync sets up an agent only when its directory exists on the machine, which the agent creates when you install it. Other agents are left alone, so a folder under `agents/` for an agent you don't use does nothing. For each one, it copies `agents/shared/AGENTS.md` to the agent's instructions file and applies `agents/<name>/` to its settings. Edit the source; sync overwrites the installed copies. Keep project paths and build commands in each project's own `AGENTS.md`, as in [examples/project](../examples/project/AGENTS.md).

| Agent (`<name>`) | Instructions | Settings | MCP servers | Model provider |
| --- | --- | --- | --- | --- |
| Claude Code (`claude`) | `~/.claude/CLAUDE.md` | `~/.claude/settings.json`, merged | `~/.claude.json` | Yes |
| Codex (`codex`) | `~/.codex/AGENTS.md` | `~/.codex/config.toml`, copied when missing | In the settings file | Yes |
| Grok (`grok`) | `~/.grok/AGENTS.md` | `~/.grok/config.toml`, copied when missing | In the settings file | Yes |
| Cursor (`cursor`) | None. Cursor keeps global rules only in its app's settings. | `~/.cursor/cli-config.json`, merged | `~/.cursor/mcp.json` | No |
| Meta Muse Code (`muse`) | `~/.config/muse/AGENTS.md`. Unconfirmed: Muse's docs don't list a global instructions file. | `~/.config/muse/settings.json`, merged | In the settings file | No |
| Gemini CLI (`gemini`) | `~/.gemini/GEMINI.md` | `~/.gemini/settings.json`, merged | In the settings file | No |
| OpenCode (`opencode`) | `~/.config/opencode/AGENTS.md` | `~/.config/opencode/opencode.json`, merged | In the settings file, under `mcp.servers` | No |

Muse, OpenCode, and Cursor's `cli-config.json` live under `$XDG_CONFIG_HOME` when it is set. Sync targets OpenCode 2, which replaced OpenCode 1 on install.

Merged means objects merge by key and the checkout's values win. Lists such as Claude's `permissions.allow` and `hooks` groups keep the machine's entries and add the checkout's. For example, `agents/claude/settings.json`:

```json
{
  "attribution": { "commit": "", "pr": "" },
  "permissions": { "allow": ["Bash(git status:*)"] }
}
```

Sync leaves a JSON settings file alone, and prints a note, when it has comments or a `.jsonc` file sits beside it. It also leaves a file alone when it holds MCP servers in an older format: a Muse file with the legacy `mcp_servers` key, because Muse turns MCP off when a file has both that key and `mcpServers`, and an OpenCode file with OpenCode 1 servers directly under `mcp`.

Codex and Grok files are copied only when missing, because they also hold sign-ins and trusted projects. After you change one, make the same edit on each machine that already has it. Don't delete an installed file to reapply it.

Plugins can add MCP servers to every agent, and a model provider to Claude Code, Codex, and Grok. Sync writes those into the installed files, which stay on the machine, and `ec push` never exports them.

## Skills

Sync copies each local `skills/<name>` into `~/.agents/skills/<name>` and links it from the Claude, Codex, and Grok skill directories, on every profile. The other agents read `~/.agents/skills` directly.

`skills/manifest.json` adds skills from GitHub repositories you trust. Sync downloads them, so review a change to this file before you sync it:

```json
{
  "version": 1,
  "skills": [
    {
      "name": "team-review",
      "source": "your-org/agent-skills#v1.0.0",
      "skill": "review",
      "profiles": ["mac", "cloud"]
    }
  ],
  "remove": [{ "name": "old-skill" }]
}
```

`source` is a repository and a branch, tag, or commit; `skill` names the skill in that repository; `name` is its installed directory. Omit `profiles` to install it everywhere. `ec sync --update-skills` refreshes these skills. Removing an entry stops managing the skill without uninstalling it; list it under `remove` to delete its installed copies on the next sync.

## Recipes

Oh My Zsh and the zsh-users plugins. Add one step per plugin, and load them from your `.zshrc`:

```toml
[[setup]]
name = "zsh-autosuggestions"
creates = "~/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
run = 'git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"'
```

Node through fnm. Put `brew "fnm"` in the Brewfile and the version in `node-version`:

```toml
[[setup]]
name = "Node"
run = 'command -v fnm >/dev/null 2>&1 || exit 0; fnm install "$(cat node-version)"; fnm list | grep -q default || fnm default "$(cat node-version)"'
```

A separate Git identity for work repositories. Add a `once` file and include it from `~/.gitconfig.local`:

```toml
files = [
  { path = ".config/git/identity.work", from = "git/identity.work.example", once = true },
]
```

```ini
[includeIf "gitdir:~/work/"]
    path = ~/.config/git/identity.work
```

Private SSH hosts. Manage `.ssh/config` with `Include ~/.ssh/config.local` at the top, and add `{ path = ".ssh/config.local", mode = "600", once = true }` for the hosts and keys that stay on one machine.
