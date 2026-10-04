import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { filePermissions, workspaceRoot, write } from "./fixture.ts";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

const fixture = () => {
  const root = mkdtempSync(path.join(tmpdir(), "ec-install-test-"));
  roots.push(root);
  const home = path.join(root, "home");
  const bin = path.join(root, "bin");
  const downloads = path.join(root, "downloads");
  const requests = path.join(root, "requests.jsonl");
  mkdirSync(home);
  mkdirSync(downloads);
  const fake = (name: string, code: string) => {
    chmodSync(write(bin, name, `#!${process.execPath}\n${code}\n`), 0o755);
  };
  fake(
    "uname",
    'console.log(process.argv[2] === "-s" ? process.env.TEST_OS : process.env.TEST_ARCH);'
  );
  fake(
    "gh",
    `
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.TEST_REQUESTS, JSON.stringify(["gh", ...args]) + "\\n");
if (args[0] === "auth") process.exit(process.env.TEST_AUTH === "1" ? 0 : 1);
if (args[1] === "view") console.log("v0.0.1");
else if (args[1] === "download") {
  const name = args[args.indexOf("--pattern") + 1];
  fs.copyFileSync(process.env.TEST_DOWNLOADS + "/" + name, args[args.indexOf("--output") + 1]);
} else process.exit(2);
`
  );
  fake(
    "curl",
    `
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.TEST_REQUESTS, JSON.stringify(["curl", ...args]) + "\\n");
if (process.env.TEST_DOWNLOAD_FAIL === "1") process.exit(22);
const url = args.at(-1);
if (url.endsWith("/latest")) process.stdout.write(process.env.TEST_RELEASE_URL || "https://github.com/example/ec/releases/tag/v0.0.1");
else {
  const name = url.split("/").at(-1);
  fs.copyFileSync(process.env.TEST_DOWNLOADS + "/" + name, args[args.indexOf("--output") + 1]);
}
`
  );
  const bytes = "#!/bin/sh\nprintf '%s\\n' installed\n";
  for (const os of ["macos", "linux"]) {
    for (const arch of ["aarch64", "x86_64"]) {
      const name = `ec-${arch}-${os}`;
      write(downloads, name, bytes);
      write(
        downloads,
        `${name}.sha256`,
        `${createHash("sha256").update(bytes).digest("hex")}\n`
      );
    }
  }
  const run = (args: string[] = [], overrides: NodeJS.ProcessEnv = {}) =>
    spawnSync("/bin/sh", ["-s", "--", ...args], {
      cwd: root,
      encoding: "utf-8",
      env: {
        EC_RELEASE_REPO: "example/ec",
        HOME: home,
        PATH: `${bin}:/usr/bin:/bin`,
        TEST_ARCH: "x86_64",
        TEST_DOWNLOADS: downloads,
        TEST_OS: "Linux",
        TEST_REQUESTS: requests,
        ...overrides,
      },
      input: readFileSync(path.join(workspaceRoot, "install.sh")),
      timeout: 10_000,
    });
  return { bytes, downloads, home, requests, root, run };
};

describe("curl installer", () => {
  it.each([
    ["Darwin", "arm64", "aarch64-macos"],
    ["Darwin", "x86_64", "x86_64-macos"],
    ["Linux", "aarch64", "aarch64-linux"],
    ["Linux", "x86_64", "x86_64-linux"],
  ])(
    "installs the %s/%s asset and pins all downloads to one release",
    (os, arch, target) => {
      const f = fixture();
      const r = f.run([], { TEST_ARCH: arch, TEST_OS: os });
      expect(r.status, r.stdout + r.stderr).toBe(0);
      const dest = path.join(f.home, ".local/bin/ec");
      expect(readFileSync(dest, "utf-8")).toBe(f.bytes);
      expect(filePermissions(dest)).toBe(0o755);
      const requests = readFileSync(f.requests, "utf-8")
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line));
      expect(
        requests
          .filter((request) => request[0] === "curl")
          .map((request) => request.at(-1))
      ).toEqual([
        "https://github.com/example/ec/releases/latest",
        `https://github.com/example/ec/releases/download/v0.0.1/ec-${target}`,
        `https://github.com/example/ec/releases/download/v0.0.1/ec-${target}.sha256`,
      ]);
      expect(readdirSync(path.dirname(dest))).toEqual(["ec"]);
    }
  );

  it("supports a pinned version and a custom directory containing spaces", () => {
    const f = fixture();
    const dir = path.join(f.root, "custom bin");
    write(dir, "ec", "old binary");
    const r = f.run(["--version", "v1.2.3", "--install-dir", dir]);
    expect(r.status, r.stderr).toBe(0);
    expect(readFileSync(path.join(dir, "ec"), "utf-8")).toBe(f.bytes);
    expect(readFileSync(f.requests, "utf-8")).toContain("/download/v1.2.3/");
    expect(readFileSync(f.requests, "utf-8")).not.toContain("/latest");
  });

  it("downloads private releases through authenticated gh", () => {
    const f = fixture();
    const r = f.run([], { TEST_AUTH: "1" });
    expect(r.status, r.stderr).toBe(0);
    const requests = readFileSync(f.requests, "utf-8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    expect(requests).toEqual([
      ["gh", "auth", "status", "--hostname", "github.com"],
      [
        "gh",
        "release",
        "view",
        "--repo",
        "example/ec",
        "--json",
        "tagName",
        "--jq",
        ".tagName",
      ],
      [
        "gh",
        "release",
        "download",
        "v0.0.1",
        "--repo",
        "example/ec",
        "--pattern",
        "ec-x86_64-linux",
        "--output",
        expect.stringContaining("/ec-x86_64-linux"),
      ],
      [
        "gh",
        "release",
        "download",
        "v0.0.1",
        "--repo",
        "example/ec",
        "--pattern",
        "ec-x86_64-linux.sha256",
        "--output",
        expect.stringContaining("/ec-x86_64-linux.sha256"),
      ],
    ]);
  });

  it.each([
    ["0".repeat(64), "Checksum mismatch"],
    ["not a checksum", "Invalid release checksum"],
  ])(
    "preserves an existing binary for rejected checksum %s",
    (checksum, message) => {
      const f = fixture();
      const dest = write(f.home, ".local/bin/ec", "old binary");
      write(f.downloads, "ec-x86_64-linux.sha256", checksum);
      const r = f.run();
      expect(r.status).not.toBe(0);
      expect(r.stderr).toContain(message);
      expect(readFileSync(dest, "utf-8")).toBe("old binary");
      expect(readdirSync(path.dirname(dest))).toEqual(["ec"]);
    }
  );

  it("preserves an existing binary when a download fails", () => {
    const f = fixture();
    const dest = write(f.home, ".local/bin/ec", "old binary");
    const r = f.run(["--version", "0.0.1"], { TEST_DOWNLOAD_FAIL: "1" });
    expect(r.status).not.toBe(0);
    expect(r.stderr).toContain("Binary download failed");
    expect(readFileSync(dest, "utf-8")).toBe("old binary");
  });

  it("replaces a symlink without modifying its target", () => {
    const f = fixture();
    const target = write(f.root, "other-ec", "keep me");
    const dir = path.join(f.home, ".local/bin");
    mkdirSync(dir, { recursive: true });
    symlinkSync(target, path.join(dir, "ec"));
    const r = f.run();
    expect(r.status, r.stderr).toBe(0);
    expect(readFileSync(target, "utf-8")).toBe("keep me");
    expect(readFileSync(path.join(dir, "ec"), "utf-8")).toBe(f.bytes);
  });

  it.each(["", "1.2", "1.2.3.4", "01.2.3", "1.2.3-beta", "../1.2.3"])(
    "rejects invalid version %s",
    (version) => {
      const f = fixture();
      const r = f.run(["--version", version]);
      expect(r.status).not.toBe(0);
      expect(existsSync(path.join(f.home, ".local/bin/ec"))).toBe(false);
    }
  );

  it.each([
    { TEST_OS: "Windows" },
    { TEST_ARCH: "riscv64" },
    { EC_RELEASE_REPO: "example/ec/extra" },
    { TEST_RELEASE_URL: "https://example.test/releases/tag/v0.0.1" },
  ])("rejects unsupported targets or release locations: %j", (env) => {
    const f = fixture();
    const r = f.run([], env);
    expect(r.status).not.toBe(0);
    expect(existsSync(path.join(f.home, ".local/bin/ec"))).toBe(false);
  });
});
