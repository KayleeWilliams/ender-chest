# Ender Chest CLI

This repository is intended for public release. Keep credentials, private hostnames, device inventories, personal config, and imported Git history out of it. Use example.test domains, documentation IP ranges, and clearly fake tokens in tests.

The CLI lives in src/*.zig. Node is a development dependency only. Run `nub run test`, `nub exec tsc --noEmit`, and `tools/zig fmt --check build.zig src/*.zig` after implementation changes. Test sync using temporary homes and config checkouts. Do not apply examples to the developer's real home.

Proxy tokens belong in ~/.config/ender-chest/secrets/cliproxyapi.json, never the config checkout. Add regression tests for credential migration, setup, and upload exclusions when those paths change. The CLI release repository and the user's config repository are separate.
