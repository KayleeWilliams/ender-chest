# Project instructions

Copy [AGENTS.md](AGENTS.md) into a codebase to give agents project-specific commands and conventions. This example assumes a pnpm workspace. Replace the package paths and scripts with ones that exist in your project before using it.

[CLAUDE.md](CLAUDE.md) imports the same file for Claude Code. Copy both files together if you use Claude. Agents that read `AGENTS.md` can use it directly.

Keep preferences that apply to every project in your machine config's `agents/shared/AGENTS.md`. Keep build commands, package boundaries, generated-file rules, and project exceptions here. Add a more specific `AGENTS.md` inside a package when its instructions differ.

These files are examples to copy manually. `ec sync` does not create or change instruction files inside your code repositories.
