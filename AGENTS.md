# Ender Chest

The native CLI lives in `packages/ec/src`, with its built-in plugins in `packages/ec/src/plugins`. Its integration tests live in `packages/ec/test`. Shared tooling lives in `tools/`; example machine config lives in `examples/config`.

Use pnpm and Turborepo for workspace commands. `pnpm check` runs Ultracite, Zig formatting checks, TypeScript checks, Vitest, and native Zig tests. `pnpm format` applies Oxfmt and Zig formatting. Keep the Oxlint anti-slop rules aligned with the shared Inth tooling.

Use temporary homes and config checkouts for tests. Do not apply examples to the developer's real home. Keep credentials, personal config, and private device details out of this repo. Use example.test domains, documentation IP ranges, and fake tokens in fixtures.

Plugin secrets belong in `~/.config/ender-chest/secrets/NAME`, written by `ec secret set`. Generated agent settings also contain credentials and must stay on-device. Preserve regression coverage for secret storage and upload exclusions.

This repo is public. Run `git config core.hooksPath .githooks` once per clone. The hooks run `tools/check-private.sh`, which blocks fixed strings listed in `~/.config/ender-chest/private-patterns` and runs Gitleaks. Never copy the pattern file into the repo or print its contents. When a new real hostname, address, account, or key appears, add it to that file and to the `PRIVATE_PATTERNS` Actions secret.
