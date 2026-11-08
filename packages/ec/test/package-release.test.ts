import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
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

import {
  ec,
  filePermissions,
  hostTarget,
  targets,
  workspaceRoot,
  write,
} from "./fixture.ts";

const roots: string[] = [];
const names = targets.map((t) => `ec-${t.key}`);
const digest = (data: Buffer) =>
  createHash("sha256").update(data).digest("hex");
afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

// Real headers, written out here rather than read from targets.json, so a wrong
// value in that table fails packaging instead of agreeing with itself.
const elf = (machine: number) => {
  const data = Buffer.alloc(32);
  Buffer.from("7f454c460201", "hex").copy(data);
  data.writeUInt16LE(machine, 18);
  return data;
};
const machO = (hex: string) => {
  const data = Buffer.alloc(32);
  Buffer.from(hex, "hex").copy(data);
  return data;
};
const headers = new Map([
  ["aarch64-linux", elf(183)],
  ["aarch64-macos", machO("cffaedfe0c000001")],
  ["x86_64-linux", elf(62)],
  ["x86_64-macos", machO("cffaedfe07000001")],
]);

const fixture = () => {
  const root = mkdtempSync(path.join(tmpdir(), "ec-package-test-"));
  roots.push(root);
  const artifacts = path.join(root, "artifacts");
  const output = path.join(root, "publish");
  for (const target of targets) {
    const name = `ec-${target.key}`;
    const header = headers.get(target.key);
    if (!header) {
      throw new Error(`No known binary header for ${target.key}.`);
    }
    const data = target.key === hostTarget() ? readFileSync(ec) : header;
    const dir = path.join(artifacts, name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, name), data);
    write(dir, `${name}.sha256`, `${digest(data)}\n`);
    write(dir, "source_hash.txt", "a".repeat(64));
  }
  const run = () =>
    spawnSync(
      "python3",
      [
        path.join(workspaceRoot, "tools/package-release.py"),
        "--artifacts",
        artifacts,
        "--output",
        output,
        "--version",
        "0.0.1",
        "--commit",
        "b".repeat(40),
        "--source-hash",
        "a".repeat(64),
      ],
      { encoding: "utf-8", timeout: 10_000 }
    );
  return { artifacts, output, root, run };
};

describe("release packaging", () => {
  it("produces checked release assets and a self-contained npm package", () => {
    const f = fixture();
    const r = f.run();
    expect(r.status, r.stderr).toBe(0);
    const tarball = path.join(f.output, "ender-chest-0.0.1.tgz");
    for (const name of [...names, "install.sh", path.basename(tarball)]) {
      expect(
        readFileSync(path.join(f.output, `${name}.sha256`), "utf-8").trim()
      ).toBe(digest(readFileSync(path.join(f.output, name))));
    }
    const manifest = JSON.parse(
      readFileSync(path.join(f.output, "manifest.json"), "utf-8")
    );
    expect(manifest.version).toBe("0.0.1");
    expect(manifest.commit).toBe("b".repeat(40));
    expect(manifest.source_hash).toBe("a".repeat(64));
    expect(Object.values(manifest.assets)).toEqual(
      names.map((name) => ({
        name,
        sha256: digest(readFileSync(path.join(f.output, name))),
      }))
    );
    const list = spawnSync("tar", ["-tzf", tarball], { encoding: "utf-8" });
    expect(list.status, list.stderr).toBe(0);
    expect(list.stdout.trim().split("\n").toSorted()).toEqual(
      [
        "package/LICENSE",
        "package/README.md",
        "package/THIRD_PARTY_NOTICES.txt",
        "package/bin/ec.mjs",
        "package/package.json",
        ...names.map((name) => `package/native/${name}`),
      ].toSorted()
    );
    const extract = spawnSync("tar", ["-xzf", tarball, "-C", f.root], {
      encoding: "utf-8",
    });
    expect(extract.status, extract.stderr).toBe(0);
    const pkg = JSON.parse(
      readFileSync(path.join(f.root, "package/package.json"), "utf-8")
    );
    expect(pkg).toMatchObject({
      bin: { ec: "bin/ec.mjs" },
      engines: { node: ">=20" },
      gitHead: "b".repeat(40),
      name: "ender-chest",
      repository: {
        directory: "packages/ec/npm",
        type: "git",
        url: "git+https://github.com/KayleeWilliams/ender-chest.git",
      },
      version: "0.0.1",
    });
    for (const field of [
      "private",
      "scripts",
      "dependencies",
      "devDependencies",
    ]) {
      expect(pkg).not.toHaveProperty(field);
    }
    for (const name of names) {
      expect(filePermissions(path.join(f.root, "package/native", name))).toBe(
        0o755
      );
    }
    const repacked = path.join(f.root, "pnpm packed");
    mkdirSync(repacked);
    const workspacePackage = JSON.parse(
      readFileSync(path.join(workspaceRoot, "package.json"), "utf-8")
    );
    write(
      f.root,
      "package.json",
      JSON.stringify({
        packageManager: workspacePackage.packageManager,
        private: true,
      })
    );
    write(f.root, "pnpm-workspace.yaml", "packages:\n  - package\n");
    const packageManager = spawnSync("pnpm", ["--version"], {
      cwd: path.join(f.root, "package"),
      encoding: "utf-8",
    });
    expect(packageManager.status, packageManager.stderr).toBe(0);
    expect(`pnpm@${packageManager.stdout.trim()}`).toBe(
      workspacePackage.packageManager
    );
    const pack = spawnSync("pnpm", ["pack", "--pack-destination", repacked], {
      cwd: path.join(f.root, "package"),
      encoding: "utf-8",
      timeout: 30_000,
    });
    expect(pack.status, pack.stdout + pack.stderr).toBe(0);
    const publishedTarball = path.join(repacked, "ender-chest-0.0.1.tgz");
    const publishedFiles = path.join(f.root, "published files");
    mkdirSync(publishedFiles);
    const unpack = spawnSync(
      "tar",
      ["-xzf", publishedTarball, "-C", publishedFiles],
      { encoding: "utf-8" }
    );
    expect(unpack.status, unpack.stderr).toBe(0);
    const publishedPackage = JSON.parse(
      readFileSync(path.join(publishedFiles, "package/package.json"), "utf-8")
    );
    expect(publishedPackage.gitHead).toBe("b".repeat(40));
    for (const name of names) {
      expect(
        filePermissions(path.join(publishedFiles, "package/native", name))
      ).toBe(0o755);
    }

    const prefix = path.join(f.root, "npm prefix");
    const env = {
      ...process.env,
      EC_NO_UPDATE: "1",
      HOME: f.root,
      NPM_CONFIG_CACHE: path.join(f.root, "cache"),
      NPM_CONFIG_USERCONFIG: path.join(f.root, "npmrc"),
    };
    const install = spawnSync(
      "npm",
      [
        "install",
        "--global",
        "--prefix",
        prefix,
        "--offline",
        "--ignore-scripts",
        "--no-audit",
        "--no-fund",
        publishedTarball,
      ],
      { encoding: "utf-8", env, timeout: 15_000 }
    );
    expect(install.status, install.stdout + install.stderr).toBe(0);
    const installed = path.join(prefix, "bin/ec");
    const help = spawnSync(installed, ["--help", "--json"], {
      encoding: "utf-8",
      env,
    });
    expect(help.status, help.stderr).toBe(0);
    expect(JSON.parse(help.stdout).ok).toBe(true);
    const bad = spawnSync(installed, ["unknown-command"], {
      encoding: "utf-8",
      env,
    });
    expect(bad.status).toBe(2);
    expect(bad.stderr).toContain("Unknown command unknown-command");
  });

  it.each(["checksum", "source hash", "native target"])(
    "rejects a %s mismatch before writing release files",
    (kind) => {
      const f = fixture();
      const name = "ec-aarch64-linux";
      const dir = path.join(f.artifacts, name);
      if (kind === "checksum") {
        write(dir, `${name}.sha256`, "0".repeat(64));
      } else if (kind === "source hash") {
        write(dir, "source_hash.txt", "0".repeat(64));
      } else {
        const wrongTarget = Buffer.from("not a native binary");
        writeFileSync(path.join(dir, name), wrongTarget);
        write(dir, `${name}.sha256`, digest(wrongTarget));
      }
      const r = f.run();
      expect(r.status).not.toBe(0);
      expect(r.stderr).toContain(kind);
      expect(existsSync(f.output)).toBe(false);
    }
  );
});
