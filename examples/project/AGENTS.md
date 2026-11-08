# Project instructions

## Workspace

This example assumes a pnpm workspace with an application in `apps/web` and shared code in `packages/`. Copy it into a codebase, with `CLAUDE.md` for Claude Code, and adapt these paths and the commands below to that repository. `ec sync` does not install project instructions; preferences for every project belong in your config's `agents/shared/AGENTS.md`.

Use the pnpm version pinned by `packageManager` and the Node version in `.node-version`. Keep the root lockfile as the dependency source of truth. Install with `pnpm install --frozen-lockfile` when checking an existing change.

Put application behavior in its app and reusable code in the package that owns it. Import another package through its exports rather than reaching into its internal files. Look for a local example before introducing a new pattern.

## Validation

Run `pnpm check` from the root before publishing. It should run the project's lint, type, and test checks. Use `pnpm --filter <package-name> <script>` for focused checks while iterating.

Use the existing Vitest setup for TypeScript tests. For a bug fix, reproduce the failing input before changing the code, then verify the corrected behavior. Exercise shared-package changes through their callers when the failure depends on integration.

Do not edit generated files to repair their output. Change the source or generator, run the generation command, and inspect the resulting diff.

## User-facing changes

Follow existing components, copy, and styling conventions. Check keyboard use and the loading, empty, success, and failure states affected by the change. Explain any states that could not be exercised.

## Publishing

Preserve unrelated working-tree changes. Before staging, inspect the diff for generated output, local settings, and secrets. Commit only the requested work.

Write the PR for a reviewer who has not read the conversation. Describe the problem, the resulting behavior, and the checks that ran. Use the repository's PR template when present.
