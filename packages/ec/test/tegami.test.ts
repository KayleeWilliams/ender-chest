import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { createRelease, stageRelease } from "../../../tools/tegami.ts";
import { listen } from "./fixture.ts";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

const write = (root: string, file: string, text: string) => {
  const destination = path.join(root, file);
  mkdirSync(path.dirname(destination), { recursive: true });
  writeFileSync(destination, text);
};

const command = (root: string, program: string, args: string[]) => {
  const result = spawnSync(program, args, {
    cwd: root,
    encoding: "utf-8",
    timeout: 10_000,
  });
  expect(result.status, result.stderr).toBe(0);
  return result.stdout.trim();
};

const fixture = () => {
  const root = mkdtempSync(path.join(tmpdir(), "ec-tegami-test-"));
  roots.push(root);
  write(
    root,
    "package.json",
    JSON.stringify({
      name: "ender-chest-monorepo",
      packageManager: "pnpm@11.25.0",
      private: true,
    })
  );
  write(
    root,
    "pnpm-workspace.yaml",
    "packages:\n  - packages/*\n  - packages/ec/npm\n"
  );
  write(
    root,
    "packages/ec/package.json",
    JSON.stringify({
      name: "@ender-chest/native",
      private: true,
      version: "0.0.0",
    })
  );
  write(
    root,
    "packages/ec/npm/package.json",
    JSON.stringify({
      bin: { ec: "bin/ec.mjs" },
      files: ["bin", "native", "LICENSE", "THIRD_PARTY_NOTICES.txt"],
      name: "ender-chest",
      version: "0.0.4",
    })
  );
  command(root, "git", ["init", "-q"]);
  command(root, "git", ["config", "user.name", "Release Test"]);
  command(root, "git", ["config", "user.email", "release@example.test"]);
  command(root, "git", ["add", "."]);
  command(root, "git", ["commit", "-qm", "Initial package"]);
  return root;
};

const archive = (root: string, version = "0.0.4", commit?: string) => {
  const metadata = {
    gitHead: commit ?? command(root, "git", ["rev-parse", "HEAD"]),
    name: "ender-chest",
    version,
  };
  const directory = "archive/package";
  write(root, `${directory}/package.json`, JSON.stringify(metadata));
  for (const file of [
    "README.md",
    "LICENSE",
    "THIRD_PARTY_NOTICES.txt",
    "bin/ec.mjs",
    "native/ec-aarch64-macos",
  ]) {
    write(root, `${directory}/${file}`, `release ${file}\n`);
  }
  mkdirSync(path.join(root, "publish"));
  command(root, "tar", [
    "-czf",
    path.join(root, "publish/ender-chest-0.0.4.tgz"),
    "-C",
    path.join(root, "archive"),
    "package",
  ]);
  return metadata;
};

describe("Tegami releases", () => {
  it("versions only the npm package without requiring release artifacts", async () => {
    const root = fixture();
    write(
      root,
      ".tegami/change.md",
      '---\npackages:\n  "ender-chest": patch\n---\n\n### Publish the CLI\n\nInstall the native CLI from npm.\n'
    );
    const release = createRelease(root);
    const draft = await release.draft();
    expect([...draft.getPackageDrafts().keys()]).toEqual(["npm:ender-chest"]);
    await draft.apply();
    const manifest = JSON.parse(
      readFileSync(path.join(root, "packages/ec/npm/package.json"), "utf-8")
    );
    expect(manifest.version).toBe("0.0.5");
    expect(
      JSON.parse(
        readFileSync(path.join(root, "packages/ec/package.json"), "utf-8")
      ).version
    ).toBe("0.0.0");
    expect(
      readFileSync(path.join(root, ".tegami/publish-lock.yaml"), "utf-8")
    ).toContain("id: npm:ender-chest");
    expect(existsSync(path.join(root, "packages/ec/npm/native"))).toBe(false);
  });

  it.each(["minor", "major"])("rejects a %s release", async (type) => {
    const root = fixture();
    write(
      root,
      ".tegami/change.md",
      `---\npackages:\n  "ender-chest": ${type}\n---\n\n### Change the CLI\n`
    );
    await expect(createRelease(root).draft()).rejects.toThrow(
      "Ender Chest releases must use a patch version bump."
    );
  });

  it("validates an unpublished release without staging files during a dry run", async () => {
    const root = fixture();
    const requests: string[] = [];
    const registry = await listen((request, response) => {
      requests.push(request.method ?? "");
      response.writeHead(404).end();
    });
    const file = path.join(root, "packages/ec/npm/package.json");
    const manifest = JSON.parse(readFileSync(file, "utf-8"));
    manifest.publishConfig = { registry };
    writeFileSync(file, JSON.stringify(manifest));
    write(
      root,
      ".tegami/change.md",
      "---\npackages:\n  ender-chest: patch\n---\n\n### Publish the CLI\n"
    );
    const release = createRelease(root);
    const draft = await release.draft();
    await draft.apply();
    const before = readFileSync(file);
    await release.publish({ dryRun: true });
    expect(requests.length).toBeGreaterThan(0);
    expect(requests.every((method) => method === "GET")).toBe(true);
    expect(readFileSync(file)).toEqual(before);
    expect(existsSync(path.join(root, "packages/ec/npm/bin"))).toBe(false);
  });

  it("stages the current archive and preserves the generated changelog", async () => {
    const root = fixture();
    const metadata = archive(root);
    write(root, "packages/ec/npm/CHANGELOG.md", "# Existing release notes\n");
    await stageRelease(root);
    expect(
      JSON.parse(
        readFileSync(path.join(root, "packages/ec/npm/package.json"), "utf-8")
      )
    ).toEqual(metadata);
    expect(
      readFileSync(
        path.join(root, "packages/ec/npm/native/ec-aarch64-macos"),
        "utf-8"
      )
    ).toBe("release native/ec-aarch64-macos\n");
    expect(
      readFileSync(path.join(root, "packages/ec/npm/CHANGELOG.md"), "utf-8")
    ).toBe("# Existing release notes\n");
  });

  it("rejects a stale archive version before changing the publishing package", async () => {
    const root = fixture();
    archive(root, "0.0.3");
    const manifest = readFileSync(
      path.join(root, "packages/ec/npm/package.json")
    );
    await expect(stageRelease(root)).rejects.toThrow(
      "The npm archive has a stale version."
    );
    expect(
      readFileSync(path.join(root, "packages/ec/npm/package.json"))
    ).toEqual(manifest);
    expect(existsSync(path.join(root, "packages/ec/npm/bin"))).toBe(false);
  });

  it("rejects an archive from an earlier commit before changing the publishing package", async () => {
    const root = fixture();
    archive(root);
    command(root, "git", [
      "commit",
      "--allow-empty",
      "-qm",
      "Change release source",
    ]);
    const manifest = readFileSync(
      path.join(root, "packages/ec/npm/package.json")
    );
    await expect(stageRelease(root)).rejects.toThrow(
      "The npm archive was built from a different commit."
    );
    expect(
      readFileSync(path.join(root, "packages/ec/npm/package.json"))
    ).toEqual(manifest);
    expect(existsSync(path.join(root, "packages/ec/npm/bin"))).toBe(false);
  });
});
