# Ender Chest

The native CLI lives in `packages/cli/src`. Its integration tests live in `packages/cli/test`. Shared tooling lives in `tools/`; example machine config lives in `examples/config`.

Use pnpm and Turborepo for workspace commands. `pnpm check` runs Ultracite, Zig formatting checks, TypeScript checks, Vitest, and native Zig tests. `pnpm format` applies Oxfmt and Zig formatting. Keep the Oxlint anti-slop rules aligned with the shared Inth tooling.

Use temporary homes and config checkouts for tests. Do not apply examples to the developer's real home. Keep credentials, personal config, and private device details out of this repo. Use example.test domains, documentation IP ranges, and fake tokens in fixtures.

Proxy tokens belong in `~/.config/ender-chest/secrets/cliproxyapi.json`. Generated agent settings also contain credentials and must stay on-device. Preserve regression coverage for credential setup, migration, and upload exclusions.
