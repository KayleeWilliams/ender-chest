# Plugins

A plugin adds commands to `ec` and can contribute MCP servers to your agents and a model provider to Claude Code, Codex, and Grok. Enable one with a `[plugins.NAME]` table in `ender-chest.toml`; the keys in that table are its settings. Once a plugin is enabled, `ec NAME --help` lists its commands and settings, and `ec plugin list` shows what is enabled and which settings still have no value. Removing a plugin and syncing removes what it added to agent settings and keeps your other MCP servers and providers.

## Built-in plugins

These ship with `ec`. The values below are placeholders; replace them with your own.

### cliproxyapi

Routes Claude Code, Codex, and Grok through a [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) server. `url` is the proxy's origin, without `/v1`.

```toml
[plugins.cliproxyapi]
url = "https://proxy.example.test:8317"
key = { secret = "cliproxyapi" }
```

On each machine, save a client key the proxy accepts, sync, and check it:

```sh
ec secret set cliproxyapi
ec sync --skip-packages
ec cliproxyapi models
```

Sync writes the endpoint and key into the agents' settings; open a new agent session afterwards. `ec cliproxyapi run PROGRAM` runs other programs with `OPENAI_BASE_URL` and `OPENAI_API_KEY` set. To replace a key, add the new one on the proxy, run `ec secret set cliproxyapi` and sync on each machine, check `models`, then retire the old key.

#### Run the proxy on a Mac

`ec cliproxyapi restart` restarts a launch agent labelled `io.cliproxyapi` on the proxy's host, and from other machines runs the same command on the host over SSH. Set the host up with that launch agent:

```sh
brew install cliproxyapi
cp tools/cliproxyapi/config.yaml.example "$(brew --prefix)/etc/cliproxyapi.conf"
chmod 600 "$(brew --prefix)/etc/cliproxyapi.conf"
cp tools/cliproxyapi/io.cliproxyapi.plist ~/Library/LaunchAgents/
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/io.cliproxyapi.plist
```

Run these from an Ender Chest source checkout. Before starting it, replace the placeholder in `api-keys` with a new random client key, and log in to your providers following the [CLIProxyAPI docs](https://github.com/router-for-me/CLIProxyAPIDocs/blob/main/docs/en/configuration/basic.md). The plist uses Homebrew's Apple silicon path; on an Intel Mac, change `/opt/homebrew` to `/usr/local`. If `brew services` already runs the proxy, stop it first so the two don't share a port.

The example config listens on `127.0.0.1:8317` with the management panel off. To reach it from your other machines, publish it on your tailnet with `tailscale serve --bg --https=8317 http://127.0.0.1:8317` and use the HTTPS name Tailscale prints as `url`. Don't use Funnel.

### executor

Shares one Executor MCP server with every agent, on every machine. `key` is the server's API key.

```toml
[plugins.executor]
url = "https://mcp.example.test:4312"
key = { secret = "executor" }
```

Run `ec secret set executor` on each machine, then sync. `ec executor status` checks the server and key.

### wol and kde

`wol` wakes a machine with Wake-on-LAN and waits until it answers. `kde` unlocks KWallet on a KDE Plasma machine and shuts it down. Enable Wake-on-LAN in the machine's firmware and operating system first.

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

```sh
ec wol wake
ec wol status
ec kde shutdown
```

On the machine's LAN, `ec wol wake` sends the packet directly. Elsewhere it asks `relay` over SSH, so the relay needs `ec`, this config, and access to that LAN. Wallet unlock needs KWallet 6.29+, Python 3, and `python-dbus` on the KDE machine; run `ec kde unlock --setup` on a Mac to save the wallet password in its Keychain.

### quiet

Stops stale dev servers, watchers, headless browsers, and containers before a benchmark. It has no settings.

```toml
[plugins.quiet]
```

## Plugin sources

`source` selects where a plugin comes from. Other keys are its settings.

```toml
[plugins.hello]
source = "plugins/hello"

[plugins.backup]
source = "someone/ec-backup#v1.2.0"
```

| Source           | Meaning                                         |
| ---------------- | ----------------------------------------------- |
| omitted          | A built-in plugin                               |
| `plugins/hello`  | A directory in your config repo                 |
| `owner/repo#ref` | A GitHub repository at a tag, branch, or commit |

`ec sync` clones GitHub plugins into `~/.local/share/ender-chest/plugins` and records each resolved commit in `ender-chest.lock`. Commit that file. Later syncs use the recorded commit. `ec plugin update NAME` moves a plugin to the newest commit for its ref and prints a GitHub compare link from the old commit to the new one.

## Secrets

Write a secret setting as a table instead of a string:

```toml
key = { secret = "executor" }        # ~/.config/ender-chest/secrets/executor
token = { env = "BACKUP_TOKEN" }     # an environment variable
```

`ec secret set NAME` reads a value from a hidden prompt, or from stdin when piped, and stores it in `~/.config/ender-chest/secrets/NAME`. `ec secret list` prints names only, and `ec secret remove NAME` deletes one. Each machine stores its own secrets; they never travel through Git.

Sync writes the secrets that plugins contribute into agent settings, so those files stay on the machine too. [Credential handling](../SECURITY.md) covers file modes, what each plugin receives, and what `ec push` refuses.

## Write a plugin

A plugin is a directory with a `plugin.toml` and an executable.

```text
hello/
  plugin.toml
  bin/hello
```

```toml
name = "hello"
description = "Say hello to a machine."
run = "bin/hello"

[settings.greeting]
type = "string"
description = "Greeting to print."
default = "Hello"

[settings.token]
type = "secret"
description = "Token for the hello service."

[[commands]]
name = "say"
description = "Print the greeting."
usage = "ec hello say [--loud]"
effects = ["Prints one line. Changes nothing."]
examples = ["ec hello say", "ec hello say --loud --json"]
options = [{ name = "loud", description = "Use capital letters." }]

[[commands]]
name = "send"
description = "Send the greeting to the hello service."
needs = ["token"]
```

A setting's `type` is `string` (the default), `secret`, `url`, `integer`, or `boolean`. A `url` is a string without its trailing slashes, so templates can append a path. `required = true` means every command needs the setting; `needs` lists settings that only some commands need.

`ec hello say --loud` runs `bin/hello say --loud`. Before it starts the plugin, `ec`:

- checks that `say` is a declared command and `--loud` a declared option, and that string options have values;
- resolves the plugin's settings, applies defaults, and fails if a required setting, or one the command `needs`, has no value;
- prints help from the manifest for `ec hello --help` and `ec hello say --help`, without running the plugin.

The plugin inherits stdin, stdout, and stderr, and `ec` exits with its exit code. These variables describe the call:

| Variable             | Value                                                |
| -------------------- | ---------------------------------------------------- |
| `EC_PROTOCOL`        | `1`                                                  |
| `EC_PLUGIN`          | The plugin's name                                    |
| `EC_PLUGIN_DIR`      | The plugin directory                                 |
| `EC_PLUGIN_SETTINGS` | Resolved settings as a JSON object, secrets included |
| `EC_JSON`            | `1` when the user passed `--json`                    |
| `EC_BIN`             | Path to the running `ec`                             |
| `EC_REPO`            | The config checkout                                  |

```sh
#!/bin/sh
greeting=$(printf '%s' "$EC_PLUGIN_SETTINGS" | jq -r .greeting)
[ "${2-}" = --loud ] && greeting=$(printf '%s' "$greeting" | tr a-z A-Z)
if [ "${EC_JSON-}" = 1 ]; then
  jq -cn --arg m "$greeting" '{schema_version:1,command:"hello say",ok:true,message:$m,data:null,error:null}'
else
  echo "$greeting"
fi
```

With `--json`, print exactly one result object on stdout in the same shape as core commands, and send diagnostics to stderr. Exit `0` on success, `1` on failure, and `2` for invalid arguments.

## Contribute to agents

A plugin can add MCP servers and one model provider. `ec sync` writes MCP servers into every agent and the provider into Claude Code, Codex, and Grok, and keeps the user's other settings. [Config](config.md#agent-instructions-and-settings) lists where each agent keeps them. `{name}` inserts a resolved setting.

```toml
[[mcp_servers]]
name = "hello"
url = "{url}/mcp"
headers = { Authorization = "Bearer {token}" }

[provider]
base_url = "{url}"
api_key = "{token}"
```

`base_url` is the server's origin. Claude Code uses it as is; Codex and Grok, which speak the OpenAI API, use it with `/v1` appended.

A contribution that uses a setting with no value is skipped, and sync prints a note that names the plugin.

## Hooks

`[hooks]` names commands that `ec` runs at fixed points. Each runs with the same environment as a command, except `EC_JSON`, and its output goes to stderr. A hook is skipped while a required setting has no value.

```toml
[hooks]
sync = ["hook-sync"]       # after ec sync applies files and agent settings
verify = ["hook-verify"]   # during ec verify; a nonzero exit fails verification
```

## Trust

A plugin runs as you, with your files and network. Only enable plugins you would run by hand. Pin GitHub plugins to a tag or commit, and read the changes behind the compare link `ec plugin update` prints before you commit the new lock file.
