# Examples

[config/](config/README.md) is a complete machine-config starter. Copy it into its own Git repo, edit the shared agent instructions and preferences, then apply it with `ec sync`. It includes a local skill, shell and Git defaults, and templates for settings that stay on each device.

[project/](project/README.md) shows instructions for an individual codebase. Copy and adapt its `AGENTS.md` into a project; `ec` does not install project instructions into your working directories.

The config starter works without a proxy token or a third-party skill source. MCP, proxy access, desktop control, and additional skill downloads are optional. The [config guide](config/README.md) shows the source files, installed paths, and opt-in steps.
