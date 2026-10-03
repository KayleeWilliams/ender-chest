# Set up your machines

## Config on each device

Install `ec`, clone your config repo, and run `ec sync --repo PATH --skip-packages`. Subsequent commands remember that checkout. Each machine needs its own Git authentication if the config repo is private.

Edit the example before applying it. `home/` paths map directly to your home directory. Shared agent instructions live in `agents/shared/AGENTS.md`. Add portable preferences under `agents/claude`, `agents/codex`, and `agents/grok`. Leave tokens, account sessions, project trust, and device-only settings out of those templates.

The optional `agents/shared/mcp.toml` can define `[mcp_servers.executor]` with an HTTP `url`. Leave it empty if you do not use that server. Skill sources belong in `skills/manifest.json`:

```json
{
  "version": 1,
  "skills": [
    { "name": "example", "source": "owner/repo#main", "skill": "example" }
  ]
}
```

Install only sources you trust. Sync clones third-party skills with Git; `--update-skills` refreshes them. Personal skills go under `skills/<name>/SKILL.md`.

## CLIProxyAPI host

You can use an existing CLIProxyAPI server or install one on a Mac. Follow the [upstream configuration docs](https://github.com/router-for-me/CLIProxyAPIDocs/blob/main/docs/en/configuration/basic.md) for provider login commands and current server options.

On a new Mac host:

```sh
brew bundle --file tools/cliproxyapi/Brewfile
```

Copy `tools/cliproxyapi/config.yaml.example` to `$(brew --prefix)/etc/cliproxyapi.conf`. Replace the placeholder with a new random client token. Store this populated file only on the host and set its mode to `0600`. Do not overwrite a working server configuration.

Log in to your chosen providers on the host, then start the server:

```sh
brew services start cliproxyapi
```

The example listens on `127.0.0.1:8317` and disables the management control panel. Provider logins stay under `~/.cli-proxy-api/auth`. The proxy client token is separate from provider credentials and any management password.

For access across your own devices, install Tailscale, join the same tailnet, and enable HTTPS if prompted:

```sh
tailscale serve --bg --https=8317 http://127.0.0.1:8317
```

Use the HTTPS hostname reported by Tailscale Serve. Keep tailnet access limited to devices that should use the proxy. Do not use Funnel for this setup. The host must stay awake and connected.

On Linux, install and manage CLIProxyAPI using its upstream instructions. Client commands work on macOS and Linux.

## Connect a client

Put your endpoint, without `/v1`, in your private config repo:

```json
{ "baseURL": "https://proxy.example.test:8317" }
```

The path is `home/.config/cliproxyapi/client.json`. Replace the example hostname with your real one. Then, on each device:

```sh
ec sync --skip-packages
ec cliproxy setup
ec sync --skip-packages
ec cliproxy models
```

Enter a token accepted by the proxy. Setup saves it locally without contacting the server; `models` verifies authentication. If your server supports multiple client keys, assigning one to each device makes revocation easier.

Sync writes the endpoint and local token into agent settings. Open a new agent session afterwards. Programs that use OpenAI-compatible environment variables can run through `ec cliproxy run PROGRAM`. Applications with independent config directories need their own setup.

To replace a token, first add its replacement on the host, run setup and sync on each affected client, verify `models`, then retire the old token on the host. Token changes never travel through Git.

`ec cliproxy restart` currently expects a macOS launch agent named `io.cliproxyapi`. It is not a generic service manager. For the Homebrew setup above, use `brew services restart cliproxyapi` on the host instead. Do not run both services on the same port.

## Fleet and desktop commands

Fleet uses `tailscale status` to discover your account's macOS and Linux devices. Enable Remote Login on Macs, or SSH/Tailscale SSH on Linux. Connect over SSH once to verify host keys. `ec fleet` checks versions; `ec fleet sync` invokes sync on reachable devices that are behind. Each remote uses its own credentials and config checkout. There is no required central secrets server.

For desktop commands, edit `home/.config/desktop/config.json` with your host, SSH user, MAC address, LAN broadcast address, and optional always-on relay. Enable Wake-on-LAN in firmware and the operating system. The relay must have `ec`, SSH access, and access to the desktop's LAN.

```sh
ec desktop start --no-auth
ec desktop status
ec desktop stop
```

Shutdown uses KDE. Optional wallet unlock requires KWallet 6.29+, Python 3, and `python-dbus` on the desktop. Run `ec desktop auth --setup` from a Mac to store its password in that Mac's Keychain. Passwords and SSH private keys stay on-device.
