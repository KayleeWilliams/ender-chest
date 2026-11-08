import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { tegami } from "tegami";
import type { TegamiPlugin } from "tegami";
import { runCli } from "tegami/cli";
import { github } from "tegami/plugins/github";

const packageName = "ender-chest";
const packageDirectory = "packages/ec/npm";
const stagedFiles = [
  "package.json",
  "README.md",
  "LICENSE",
  "THIRD_PARTY_NOTICES.txt",
  "bin",
  "native",
];

const command = (
  cwd: string,
  program: string,
  args: string[],
  env = process.env
) => {
  const result = spawnSync(program, args, {
    cwd,
    encoding: "utf-8",
    env,
    timeout: 30_000,
  });
  assert.equal(result.status, 0, result.stderr || `Could not run ${program}.`);
  return result.stdout.trim();
};

export const stageRelease = async (cwd: string): Promise<void> => {
  const destination = path.join(cwd, packageDirectory);
  const source = JSON.parse(
    await readFile(path.join(destination, "package.json"), "utf-8")
  );
  assert.equal(source.name, packageName);
  const archive = path.join(
    cwd,
    "publish",
    `${packageName}-${source.version}.tgz`
  );
  const metadata = JSON.parse(
    command(cwd, "tar", ["-xOf", archive, "package/package.json"])
  );
  assert.equal(
    metadata.name,
    source.name,
    "The npm archive has the wrong name."
  );
  assert.equal(
    metadata.version,
    source.version,
    "The npm archive has a stale version."
  );
  assert.equal(
    metadata.gitHead,
    command(cwd, "git", ["rev-parse", "HEAD"]),
    "The npm archive was built from a different commit."
  );

  const temporary = await mkdtemp(path.join(tmpdir(), "ec-npm-release-"));
  try {
    command(cwd, "tar", ["-xzf", archive, "-C", temporary]);
    await Promise.all(
      stagedFiles.map((file) =>
        cp(
          path.join(temporary, "package", file),
          path.join(destination, file),
          {
            recursive: true,
          }
        )
      )
    );
  } finally {
    await rm(temporary, { force: true, recursive: true });
  }
};

export const verifyPackage = async (cwd: string): Promise<void> => {
  const directory = path.join(cwd, packageDirectory);
  const manifest = JSON.parse(
    await readFile(path.join(directory, "package.json"), "utf-8")
  );
  const temporary = await mkdtemp(path.join(tmpdir(), "ec-npm-package-"));
  try {
    command(directory, "pnpm", ["pack", "--pack-destination", temporary]);
    const prefix = path.join(temporary, "install");
    command(temporary, "npm", [
      "install",
      "--prefix",
      prefix,
      "--cache",
      path.join(temporary, "cache"),
      "--offline",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      path.join(temporary, `${packageName}-${manifest.version}.tgz`),
    ]);
    const output = command(
      temporary,
      path.join(prefix, "node_modules/.bin/ec"),
      ["--version"],
      { ...process.env, EC_NO_UPDATE: "1" }
    );
    assert.ok(
      output.startsWith(`ec ${manifest.version} (`),
      `The packed npm CLI reports the wrong version: ${output}`
    );
  } finally {
    await rm(temporary, { force: true, recursive: true });
  }
};

const nativeRelease: TegamiPlugin = {
  async beforePublishAll({ plan }) {
    if (
      !plan.options.dryRun &&
      plan.getPackagesToPublish().some((pkg) => pkg.name === packageName)
    ) {
      await stageRelease(this.cwd);
      await verifyPackage(this.cwd);
    }
  },
  enforce: "pre",
  initDraft(draft) {
    draft.addPolicy({
      id: "patch-only",
      onUpdate({ packageDraft, pkg }) {
        if (
          pkg.name === packageName &&
          packageDraft.type &&
          packageDraft.type !== "patch"
        ) {
          throw new Error(
            "Ender Chest releases must use a patch version bump."
          );
        }
      },
    });
  },
  initPublishPlan({ plan }) {
    for (const [id, entry] of plan.packages) {
      const pkg = this.graph.get(id);
      if (pkg?.name !== packageName || !pkg.version) {
        continue;
      }
      entry.git = { tag: `v${pkg.version}` };
    }
  },
  name: "native-release",
};

export const createRelease = (
  cwd = fileURLToPath(new URL("../", import.meta.url))
) =>
  tegami({
    cwd,
    ignore: ["ender-chest-monorepo", "@ender-chest/native"],
    npm: {
      client: "pnpm",
      trustedPublish: { provider: "github", workflow: "release.yml" },
      updateLockFile: true,
    },
    plugins: [
      nativeRelease,
      github({
        createTags: false,
        release: false,
        repo: "KayleeWilliams/ender-chest",
        versionPr: { base: "main" },
      }),
    ],
  });

if (import.meta.main) {
  await runCli(createRelease());
}
