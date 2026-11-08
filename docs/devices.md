# Devices

## Set up a machine

Set up each machine as the [template README](../examples/config/README.md#start) describes. Later commands remember the checkout. Each machine fetches the config repo with its own Git credentials, and keeps its own secrets.

Your config's `DEVICES.md` lists your machines for agents; the template's copy shows the columns.

## Check and sync every machine

`ec status` finds your macOS and Linux machines with `tailscale status` and reads each one's `ec` version and config commit over SSH. `ec sync --all` syncs this machine, then runs `ec sync --skip-packages` on each other reachable machine that is behind, one at a time. Machines that are offline, unreachable, or current are skipped.

## SSH access

Both commands use batch-mode SSH, which cannot answer prompts. Connect to each new machine once by hand to accept its host key.

Enable Remote Login on a Mac and add your key to its `~/.ssh/authorized_keys`, for example with `ssh-copy-id HOST`. On Linux, run an SSH server or use Tailscale SSH, which follows your tailnet's SSH policy. If a machine's account name differs from yours, set `User` for its host in your managed `~/.ssh/config`.

## GitHub access over SSH

`ec sync --all` runs sync over SSH, and an SSH session cannot read a locked macOS Keychain. If a Mac keeps its `gh` token only in the Keychain, run this on that Mac to store the token in a file and point Git at `gh`:

```sh
gh auth login --hostname github.com --git-protocol https --web --insecure-storage
git config --file ~/.gitconfig.local --replace-all credential.https://github.com.helper ''
git config --file ~/.gitconfig.local --add credential.https://github.com.helper "!$(command -v gh) auth git-credential"
```

The token is then in `~/.config/gh/hosts.yml`, readable only by that account. The empty helper stops Git from trying the Keychain first. Use `~/.gitconfig.local` rather than `gh auth setup-git`, because sync replaces a managed `~/.gitconfig`.
