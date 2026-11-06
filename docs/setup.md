# Set up your machines

## Config on each device

Install `ec`, clone your config repo, and run `ec sync --repo PATH --skip-packages`. Subsequent commands remember that checkout. Each machine needs its own Git authentication if the config repo is private.

Edit the example before applying it. The [starter guide](../examples/config/README.md) maps each source file to its installed location and explains which preferences merge or only seed a missing config. Shared agent instructions live in `agents/shared/AGENTS.md`; sync installs them as Claude's `CLAUDE.md` and Codex/Grok's `AGENTS.md`. The separate [project example](../examples/project/README.md) shows instructions for a codebase.

`ender-chest.toml` lists the home files sync applies; each `home/<path>` maps to `~/<path>`. It also lists Brewfiles, setup steps, and plugins. The [README](../README.md#ender-chesttoml) describes each key. Add portable preferences under `agents/claude`, `agents/codex`, and `agents/grok`. Leave tokens, account sessions, project trust, and device-only settings out of those templates.

To share an MCP server or a model provider with every agent, enable a [plugin](plugins.md) such as `executor` or `cliproxyapi`. Skill sources belong in `skills/manifest.json`:

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

Enable the plugin in your private config repo's `ender-chest.toml`, with your endpoint and without `/v1`:

```toml
[plugins.cliproxyapi]
url = "https://proxy.example.test:8317"
key = { secret = "cliproxyapi" }
```

Replace the example hostname with your real one. Then, on each device:

```sh
ec secret set cliproxyapi
ec sync --skip-packages
ec cliproxyapi models
```

Enter a token accepted by the proxy. `ec secret set` saves it locally without contacting the server; `models` verifies authentication. If your server supports multiple client keys, assigning one to each device makes revocation easier.

Sync writes the endpoint and local token into agent settings. Open a new agent session afterwards. Programs that use OpenAI-compatible environment variables can run through `ec cliproxyapi run PROGRAM`. Applications with independent config directories need their own setup.

To replace a token, first add its replacement on the host, run `ec secret set cliproxyapi` and sync on each affected client, verify `models`, then retire the old token on the host. Token changes never travel through Git.

`ec cliproxyapi restart` expects a macOS launch agent named `io.cliproxyapi` on the host. From other machines it runs the same command on the host over SSH. It is not a generic service manager. For the Homebrew setup above, use `brew services restart cliproxyapi` on the host instead. Do not run both services on the same port.

## Other machines

`ec status` uses `tailscale status` to discover your account's macOS and Linux devices. Enable Remote Login on Macs, or SSH/Tailscale SSH on Linux. Connect over SSH once to verify host keys. `ec status` checks versions; `ec sync --all` runs sync on reachable devices that are behind. Each remote uses its own credentials and config checkout. There is no required central secrets server.

## Wake and shut down a desktop

The `wol` plugin wakes a machine, and the `kde` plugin unlocks its wallet and shuts it down. Enable Wake-on-LAN in firmware and the operating system, then add your values:

```toml
[plugins.wol]
mac = "00:00:5e:00:53:01"
broadcast = "192.0.2.255"
host = "desktop.example.test"
relay = "user@relay.example.test"
after_wake = "kde unlock --wait"

[plugins.kde]
host = "user@desktop.example.test"
```

On the machine's LAN, `ec wol wake` sends the packet directly. Elsewhere it asks the relay over SSH, so the relay needs `ec`, this config, and access to the desktop's LAN.

```sh
ec wol wake
ec wol status
ec kde shutdown
```

Shutdown uses KDE. Wallet unlock requires KWallet 6.29+, Python 3, and `python-dbus` on the desktop; `ec` sends its helper over SSH. Run `ec kde unlock --setup` from a Mac to store the wallet password in that Mac's Keychain. Passwords and SSH private keys stay on-device.
