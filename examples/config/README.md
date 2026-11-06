# Machine config starter

This is a complete config checkout for Ender Chest. It installs shared agent instructions, a review skill, shell and Git defaults, and starter preferences for Claude Code, Codex, and Grok.

## Start here

On GitHub, choose **Use this template** on [ender-chest-template](https://github.com/KayleeWilliams/ender-chest-template), create a private repository, and clone it:

```sh
git clone https://github.com/YOUR-NAME/my-machine-config.git ~/my-machine-config
cd ~/my-machine-config
```

Or copy `examples/config` out of the Ender Chest source checkout and run `git init` in the copy.

Edit [agents/shared/AGENTS.md](agents/shared/AGENTS.md) to describe how you want agents to work across your projects. Review the agent preferences below, then apply the config:

```sh
ec sync --repo "$PWD" --skip-packages
ec verify
```

[ender-chest.toml](ender-chest.toml) lists what sync applies: home files, Brewfiles, setup steps, and plugins. Sync replaces the listed shell, Git, and SSH files and the shared instruction files. The first time it replaces a file that differs, it keeps your old copy under `~/.config/ender-chest/backup/`. `--skip-packages` skips the Brewfiles and setup steps. It still writes config and installs skills.

The initial sync needs no secrets, enables no plugins, and downloads no skills. Sign in through each agent's own login flow to use it directly. Add a Git remote when you want other machines to use this checkout; keep it private if you add personal hostnames or work details.

## Agent instructions

[agents/shared/AGENTS.md](agents/shared/AGENTS.md) contains working rules for writing, implementation, tests, and Git. Sync copies the same text to each agent:

| Source                    | Installed on this device |
| ------------------------- | ------------------------ |
| `agents/shared/AGENTS.md` | `~/.claude/CLAUDE.md`    |
| `agents/shared/AGENTS.md` | `~/.codex/AGENTS.md`     |
| `agents/shared/AGENTS.md` | `~/.grok/AGENTS.md`      |

Edit the source in this checkout. Changes to installed instruction files are overwritten on the next sync, and `ec push` does not collect them.

Keep project paths, architecture, and build commands in each project's own `AGENTS.md`. The separate `examples/project` directory in the Ender Chest source repo shows one for a pnpm workspace, including a `CLAUDE.md` that imports it.

This directory's [AGENTS.md](AGENTS.md) gives an agent instructions for editing the config checkout itself. It is not installed as your global agent instructions.

## Agent preferences

| Source | Installed path | Sync behavior |
| --- | --- | --- |
| [Claude settings](agents/claude/settings.json) | `~/.claude/settings.json` | Merges portable settings on every sync. Matching top-level keys are replaced; `env` merges by key. |
| [Codex config](agents/codex/config.toml) | `~/.codex/config.toml` | Seeds a missing file, then preserves existing preferences. |
| [Grok config](agents/grok/config.toml) | `~/.grok/config.toml` | Seeds a missing file, then preserves existing preferences. |

Claude starts in `acceptEdits` mode and omits generated commit and PR attribution. Codex starts with workspace write access, on-request approvals, cached web search, and terminal notifications. Grok enables CLI updates and uses a 120-column thoughts display. Choose models through each agent's own settings; the templates do not assume a subscription or available model.

If you change a Codex or Grok template after the first sync, make the same preference edit in that device's installed config. Do not delete an existing config to reapply a template; it can contain authentication and project settings. Keep the source templates portable, and leave account sessions, tokens, trusted project paths, and credentials in the installed files.

Enabled plugins can add an MCP server or a model provider to these settings, as described below. Generated agent settings stay on-device, and `ec push` does not export them into these templates.

See the [Codex configuration reference](https://developers.openai.com/codex/config-reference) and [Claude settings reference](https://code.claude.com/docs/en/settings-reference) for other supported options.

## Skills

The bundled [review-changes](skills/review-changes/SKILL.md) skill walks through a local diff review. Ask an agent to use `review-changes` to review your working tree. Edit its source here to change the review process.

Sync copies local skills into `~/.agents/skills/<name>` and creates links from the Claude, Codex, and Grok skill directories. Local skills apply to both the `mac` and `cloud` profiles. Add your own folder with a `SKILL.md`; it does not need an entry in the manifest.

[skills/manifest.json](skills/manifest.json) is empty because external skills are opt-in. After choosing a repository you trust, add an entry like this:

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
  ]
}
```

Replace the example source with a real GitHub repository and branch or tag. `skill` identifies the skill in that repository; `name` is its installed directory. Omit `profiles` to install it on every profile. Use `ec sync --update-skills` to refresh external skills. Removing an entry stops managing it but does not uninstall it; add `"remove": [{ "name": "team-review" }]` to the manifest to remove its installed copies on the next sync.

## Plugins

The end of [ender-chest.toml](ender-chest.toml) has a commented example for each plugin that ships with `ec`. Uncomment one, replace its example values, and save any secret it names on each device:

```sh
ec secret set cliproxyapi
ec sync --skip-packages
ec cliproxyapi models
```

`cliproxyapi` routes Claude Code, Codex, and Grok through a CLIProxyAPI server, and `executor` gives them a shared Executor MCP server. `wol` and `kde` wake, unlock, and shut down a desktop. `quiet` stops stale dev servers before a benchmark. Run `ec NAME --help` for a plugin's commands and settings. Removing a plugin and syncing removes what it added to agent settings.

Secrets stay in `~/.config/ender-chest/secrets/` on each device, never in this checkout. The Ender Chest setup guide covers running a proxy host and connecting it through Tailscale.

## Shell, Git, and device overrides

Each entry in the `files` list of [ender-chest.toml](ender-chest.toml) maps `home/<path>` to the same path under your home directory. A file under `home/` is installed only when it is listed there. `profiles = ["mac"]` limits the macOS shell and Zed files to the `mac` profile.

The `once` entries create device-local files from these templates:

| Source template | Device-local file | Use |
| --- | --- | --- |
| [git/gitconfig.local.example](git/gitconfig.local.example) | `~/.gitconfig.local` | Your Git identity and optional work-directory include. |
| [git/identity.work.example](git/identity.work.example) | `~/.config/git/identity.work` | Your work Git identity. |
| [shell/zshrc.local.example](shell/zshrc.local.example) | `~/.zshrc.local` | Private aliases and machine-specific paths. |
| [tools/ssh/config.local.example](tools/ssh/config.local.example) | `~/.ssh/config.local` | Private hosts, usernames, and SSH key paths. |

Sync creates a missing `once` file, including an empty `~/.zprofile.local`, and never overwrites one. Edit the installed files to enable their commented examples. `ec push` does not capture them.

Review [tools/Brewfile](tools/Brewfile) before running sync without `--skip-packages`. The `mac` profile also installs [tools/Brewfile.mac](tools/Brewfile.mac). The setup steps install Oh My Zsh and three zsh-users plugins, then the Node version in [tools/node-version](tools/node-version) through fnm when fnm is installed. A step whose `creates` path exists is skipped.

## Save changes

Edit shared instructions, agent templates, and skills in this checkout. Use `ec push --dry-run` to collect changes to listed home files and skills without committing. This still modifies the checkout, so review `git diff` afterwards. `ec push` commits and uploads changes when a remote is configured. Other machines pick them up when you run `ec sync` there.
