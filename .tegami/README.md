# Publishing

Tegami versions the `ender-chest` npm package in `packages/ec/npm`. The Zig development workspace stays private. Releases stay on `0.0.x`, with GitHub tags named `v0.0.x` so existing installers and updaters keep working.

## Add a changelog

Run `pnpm tegami`, or add `.tegami/YYYY-MM-DD-description.md`:

```md
---
packages:
  ender-chest: patch
---

### Describe the user-visible change

Explain what changed for someone using ec.
```

Use `patch`. The release policy rejects minor and major bumps. Tegami generates the package version, `CHANGELOG.md`, and `.tegami/publish-lock.yaml`; do not edit them by hand.

## Release flow

1. Merge a change and its changelog into `main`.
2. GitHub Actions runs lint, type checks, and tests on macOS and Linux, and builds all four native targets.
3. `pnpm tegami ci` opens or updates a version PR.
4. Merge the version PR. The next run validates the binaries, checksums, and source hash, installs the npm tarball offline, and runs `ec --version`.
5. Tegami publishes the single npm package with provenance. The workflow then uploads the same release's binaries, checksums, installer, and tarball to GitHub Releases.

The initial npm release has its version and publish lock generated with this setup, so it publishes when the setup reaches `main`.

Rerun a failed Release workflow from its original commit. Tegami skips npm versions already published. GitHub asset uploads resume only when the npm package's `gitHead` matches that workflow's commit, so later changes cannot overwrite an earlier release. When `TEMPLATE_TOKEN` is set, the workflow also updates ender-chest-template.

## Trusted publishing

The npm trusted publisher is `KayleeWilliams/ender-chest`, workflow `release.yml`, with no environment restriction. GitHub Actions may create version PRs. The publishing job runs on GitHub-hosted `ubuntu-24.04`, grants `id-token: write`, and requests provenance. It needs no `NPM_TOKEN`.

For a fork, change the Tegami repository and workflow guard, use your own npm package name, and configure its trusted publisher. Build and test jobs do not receive npm credentials.
