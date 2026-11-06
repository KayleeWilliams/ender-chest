# Plugins

A plugin adds commands to `ec` and can contribute MCP servers and a model provider to Claude Code, Codex, and Grok. Plugins can be written in any language. The plugins that ship with `ec` use the same protocol as yours.

## Enable a plugin

List plugins in `ender-chest.toml` at the root of your config repo. Keys other than `source` are the plugin's settings.

```toml
[plugins.executor]
url = "https://mcp.example.test:4312"
key = { secret = "executor" }

[plugins.hello]
source = "plugins/hello"

[plugins.backup]
source = "someone/ec-backup#v1.2.0"
```

`source` selects where the plugin comes from:

| Source | Meaning |
| --- | --- |
| omitted | A plugin that ships with `ec`, such as `wol`, `kde`, `cliproxyapi`, `executor`, or `quiet` |
| `plugins/hello` | A directory in your config repo |
| `owner/repo#ref` | A GitHub repository at a tag, branch, or commit |

`ec sync` clones GitHub plugins into `~/.local/share/ender-chest/plugins` and records each resolved commit in `ender-chest.lock`. Commit that file. Later syncs use the recorded commit. `ec plugin update NAME` moves a plugin to the newest commit for its ref and prints a GitHub compare link from the old commit to the new one.

`ec plugin list` shows each enabled plugin, its source, commit, and commands.

## Secrets

Write a secret value as a table instead of a string:

```toml
key = { secret = "executor" }        # ~/.config/ender-chest/secrets/executor
token = { env = "BACKUP_TOKEN" }     # an environment variable
```

`ec secret set NAME` reads a value from a hidden prompt, or from stdin when piped, and stores it with mode `0600`. Secret files never enter the config repo, and `ec push` refuses them. A plugin receives only the secrets named in its own settings.

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
required = true
description = "Token for the hello service."

[[commands]]
name = "say"
description = "Print the greeting."
usage = "ec hello say [--loud]"
effects = ["Prints one line. Changes nothing."]
examples = ["ec hello say", "ec hello say --loud --json"]
options = [{ name = "loud", description = "Use capital letters." }]
```

`ec hello say --loud` runs `bin/hello say --loud`. Before it starts the plugin, `ec`:

- checks that `say` is a declared command and `--loud` a declared option, and that string options have values;
- resolves the plugin's settings, applies defaults, and fails if a required setting is missing;
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

A plugin can add MCP servers and one model provider. `ec sync` writes them into Claude Code, Codex, and Grok, and keeps the user's other settings. `{name}` inserts a resolved setting.

```toml
[[mcp_servers]]
name = "hello"
url = "{url}/mcp"
headers = { Authorization = "Bearer {token}" }

[provider]
base_url = "{url}"
api_key = "{token}"
```

A contribution that uses a setting with no value is skipped, with a note that says which setting is missing.

## Hooks

`[hooks]` names commands that `ec` runs at fixed points. Each runs with the same environment as a command.

```toml
[hooks]
sync = ["hook-sync"]       # after ec sync applies files and agent settings
verify = ["hook-verify"]   # during ec verify; a nonzero exit fails verification
```

## Trust

A plugin runs as you, with your files and network. Only enable plugins you would run by hand. Pin GitHub plugins to a tag or commit, and read the changes behind the compare link `ec plugin update` prints before you commit the new lock file.
