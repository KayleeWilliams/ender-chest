# Migrate from a combined config repository

The CLI and your config can live in separate repos. Keep your existing config repo private. Copy only reviewed source files into a fresh CLI repo; do not fork or push its old history into a repo intended for public release.

Before removing a tracked proxy token, confirm every existing client has an installed copy in `~/.config/cliproxyapi/client.json`, or another way to obtain a replacement. Remove `apiKey` from the tracked file so it contains only `baseURL`.

Install the updated CLI and sync each device. It migrates an installed legacy token to `~/.config/ender-chest/secrets/cliproxyapi.json` before replacing the endpoint file. An existing separate local token wins. The migration is idempotent and does not read credentials from Git.

New devices run `ec cliproxy setup`. Devices that lost their old local copy also use setup. Missing credentials do not prevent portable config from syncing; existing agent authentication remains unchanged.

Upgrade all clients before using push from them. Old CLI versions can still capture the legacy key file. The new version exports only `baseURL` and refuses known credential directories in the upload set.

Removing a file or field does not remove it from old Git commits. Retire any previously tracked token after its replacement works on every client. Keep old history private even after migration, since it may contain other personal data.

A config-only repo does not need Zig sources or build tooling. Its CLI updates come from the separate release repo. Keep the combined checkout during the transition if you still need local source builds. Move to config-only after the first standalone release is available.
