# Devices

List the machines you sync here, so agents know which machine to reach and how. Replace the example rows with your own. Keep this repository private once it lists real hostnames. No secrets belong in this file.

`ec status` finds your macOS and Linux machines through `tailscale status` and shows each one's ec version and config commit. This file records what Tailscale does not know: what each machine is for, who logs in, and where its config checkout lives.

All machines are on the `tailnet-name.ts.net` tailnet. Use the Tailscale names below, not LAN addresses.

| Machine | Tailscale host | OS | SSH user | SSH server | Config checkout | Role |
| --- | --- | --- | --- | --- | --- | --- |
| Laptop | `laptop.tailnet-name.ts.net` | macOS | `you` | Remote Login off | `~/my-machine-config` | Primary machine. Runs `ec status` and `ec sync --all` |
| Relay | `relay.tailnet-name.ts.net` | macOS | `you` | Remote Login | `~/my-machine-config` | Always on. Hosts shared services such as CLIProxyAPI or Executor |
| Desktop | `desktop.tailnet-name.ts.net` | Linux | `you` | Tailscale SSH | `~/my-machine-config` | Workstation that the `wol` and `kde` plugins wake and shut down |

```sh
ssh relay.tailnet-name.ts.net
ec status          # ec version and config commit on each machine
ec sync --all      # sync every reachable machine that is behind
```

## SSH access

`ec status` and `ec sync --all` connect with batch-mode SSH, which cannot answer prompts. Before they can reach a new machine, connect to it once by hand to accept its host key.

A Mac with Remote Login accepts the keys in its `~/.ssh/authorized_keys`. Run `ssh-copy-id relay.tailnet-name.ts.net` from each machine that needs access. A machine on Tailscale SSH follows your tailnet's SSH policy instead.

If a machine's account name differs from your own, set `User` for its host in `home/.ssh/config`. Sync installs that file on every machine.

## GitHub access

Each machine fetches this repository with its own GitHub credentials. `ec sync --all` runs sync over SSH, and an SSH session cannot read a locked macOS Keychain. If a Mac keeps its `gh` token only in the Keychain, run this on that Mac to store the token in a file and point Git at `gh`:

```sh
gh auth login --hostname github.com --git-protocol https --web --insecure-storage
git config --file ~/.gitconfig.local --replace-all credential.https://github.com.helper ''
git config --file ~/.gitconfig.local --add credential.https://github.com.helper "!$(command -v gh) auth git-credential"
```

The token is then in `~/.config/gh/hosts.yml`, readable only by that account. The empty helper stops Git from trying the Keychain first. Use `~/.gitconfig.local` rather than `gh auth setup-git`, because sync replaces `~/.gitconfig`.
