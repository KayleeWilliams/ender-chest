import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { afterEach, beforeAll, describe, expect, it } from "vitest";

import {
  cliRoot,
  gitInit,
  workspaceRoot,
  write,
  writeSourceRepo,
} from "./fixture.ts";

// Update policy depends on the running version, so these tests use a build that reports 0.0.5.
const prefix = path.join(cliRoot, "zig-out/release-test");
const released = path.join(prefix, "bin/ec");
const roots: string[] = [];

beforeAll(() => {
  const r = spawnSync(
    path.join(workspaceRoot, "tools/zig"),
    ["build", "-Doptimize=ReleaseSafe", "-Dversion=0.0.5", "-p", prefix],
    { cwd: cliRoot, encoding: "utf-8", timeout: 280_000 }
  );
  expect(r.status, r.stderr).toBe(0);
}, 300_000);

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

const assetKey = (): string => {
  const arch = process.arch === "arm64" ? "aarch64" : "x86_64";
  return `${arch}-${process.platform === "darwin" ? "macos" : "linux"}`;
};

const setup = () => {
  const root = mkdtempSync(path.join(tmpdir(), "ec-update-"));
  roots.push(root);
  const home = path.join(root, "home");
  const bin = path.join(root, "bin");
  mkdirSync(home);
  mkdirSync(bin);
  // Each test runs its own copy, so ec update replaces that copy.
  const exe = path.join(bin, "ec");
  copyFileSync(released, exe);
  chmodSync(exe, 0o755);
  const fake = (name: string, code: string) => {
    const file = write(
      root,
      `fakes/${name}`,
      `#!${process.execPath}\n${code}\n`
    );
    chmodSync(file, 0o755);
  };
  fake("gh", "process.exit(1);");
  const env = {
    CI: "",
    EC_NO_UPDATE: "",
    EC_RELEASE_REPO: "example/ec",
    GH_TOKEN: "",
    GITHUB_TOKEN: "",
    HOME: home,
    NO_UPDATE_NOTIFIER: "",
    PATH: `${path.join(root, "fakes")}:/usr/bin:/bin`,
  };
  const run = (args: string[], extra: Record<string, string> = {}) =>
    spawnSync(exe, args, {
      cwd: root,
      encoding: "utf-8",
      env: { ...env, ...extra },
      timeout: 15_000,
    });
  // A release whose binary prints its version for the post-download check and otherwise
  // leaves a marker, so a test can tell it ran.
  const release = (
    version: string,
    { runs = true, sha256 }: { runs?: boolean; sha256?: string } = {}
  ) => {
    const asset = write(
      root,
      `release-${version}/ec`,
      `#!/bin/sh\nif [ "\${1-}" = --version ]; then ${runs ? `echo "ec ${version} (abcdef0)"` : "exit 1"}; exit; fi\necho "$*" > "$HOME/ran-${version}"\n`
    );
    chmodSync(asset, 0o755);
    const bytes = readFileSync(asset);
    const manifest = write(
      root,
      `release-${version}/manifest.json`,
      JSON.stringify({
        assets: {
          [assetKey()]: {
            name: `ec-${assetKey()}`,
            path: asset,
            sha256: sha256 ?? createHash("sha256").update(bytes).digest("hex"),
          },
        },
        source_hash: "b".repeat(64),
        version,
      })
    );
    return { bytes, manifest };
  };
  const state = path.join(home, ".config/ender-chest/update-check.json");
  return { bin, env, exe, fake, home, release, root, run, state };
};

type Setup = ReturnType<typeof setup>;

const configRepo = (f: Setup) => {
  const repo = path.join(f.root, "repo");
  writeSourceRepo(repo);
  gitInit(repo);
  return repo;
};

// Runs ec in a pseudo-terminal, since the notice appears only in interactive use.
const tty = (f: Setup, args: string[], extra: Record<string, string> = {}) => {
  const env = { ...f.env, ...extra };
  const argv =
    process.platform === "darwin"
      ? ["-q", "/dev/null", f.exe, ...args]
      : ["-qec", [f.exe, ...args].join(" "), "/dev/null"];
  const r = spawnSync("script", argv, {
    cwd: f.root,
    encoding: "utf-8",
    env,
    // script reads the terminal from stdin; /dev/null keeps it from probing a socket.
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 15_000,
  });
  expect(r.status, r.stdout + r.stderr).toBe(0);
  return r.stdout;
};

const notice = "Update available 0.0.5 → 0.0.9 · Run ec update";
const seed = (f: Setup, checkedAt: number, latest = "0.0.9") =>
  write(
    f.home,
    ".config/ender-chest/update-check.json",
    JSON.stringify({
      checked_at: checkedAt,
      latest,
      notified_at: 0,
    })
  );

describe("ec update", () => {
  it("reports a newer release without installing it", () => {
    const f = setup();
    const before = readFileSync(f.exe);
    const r = f.run(["update", "--check", "--json"], {
      EC_RELEASE_MANIFEST: f.release("0.0.9").manifest,
    });
    expect(r.status, r.stderr).toBe(0);
    expect(JSON.parse(r.stdout).data).toEqual({
      current: "0.0.5",
      latest: "0.0.9",
      method: "standalone",
      release_notes: "https://github.com/example/ec/releases/tag/v0.0.9",
      update_available: true,
      updated: false,
    });
    expect(readFileSync(f.exe)).toEqual(before);
    expect(JSON.parse(readFileSync(f.state, "utf-8")).latest).toBe("0.0.9");
  });

  it.each(["0.0.5", "0.0.4"])(
    "keeps 0.0.5 when the latest release is %s",
    (version) => {
      const f = setup();
      const before = readFileSync(f.exe);
      const r = f.run(["update"], {
        EC_RELEASE_MANIFEST: f.release(version).manifest,
      });
      expect(r.status, r.stderr).toBe(0);
      expect(r.stdout.trim()).toBe("ec 0.0.5 is up to date.");
      expect(readFileSync(f.exe)).toEqual(before);
    }
  );

  it("replaces the running binary with a verified newer release", () => {
    const f = setup();
    const next = f.release("0.0.9");
    const r = f.run(["update"], { EC_RELEASE_MANIFEST: next.manifest });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(r.stdout).toContain("Updated ec 0.0.5 → 0.0.9");
    expect(readFileSync(f.exe)).toEqual(next.bytes);
    expect(readdirSync(f.bin)).toEqual(["ec"]);
  });

  it.each([
    [
      "a checksum mismatch",
      { sha256: "0".repeat(64) },
      "checksum did not match",
    ],
    [
      "a binary that does not run",
      { runs: false },
      "did not run on this machine",
    ],
  ])("keeps the old binary after %s", (_name, options, message) => {
    const f = setup();
    const before = readFileSync(f.exe);
    const r = f.run(["update", "--json"], {
      EC_RELEASE_MANIFEST: f.release("0.0.9", options).manifest,
    });
    expect(r.status).toBe(1);
    expect(r.stdout + r.stderr).toContain(message);
    expect(readFileSync(f.exe)).toEqual(before);
    expect(readdirSync(f.bin)).toEqual(["ec"]);
  });
});

describe("sync in a config repo without ec's sources", () => {
  it("installs a newer release and resumes with it", () => {
    const f = setup();
    const repo = configRepo(f);
    const r = f.run(["sync", "--skip-packages"], {
      EC_RELEASE_MANIFEST: f.release("0.0.9").manifest,
      EC_REPO: repo,
    });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(r.stderr).toContain("Updating ec 0.0.5 to 0.0.9");
    expect(readFileSync(path.join(f.home, "ran-0.0.9"), "utf-8")).toBe(
      `sync --repo ${repo} --skip-packages\n`
    );
  });

  it("never installs an older release", () => {
    const f = setup();
    const repo = configRepo(f);
    const r = f.run(["sync", "--skip-packages", "--json"], {
      EC_RELEASE_MANIFEST: f.release("0.0.4").manifest,
      EC_REPO: repo,
    });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(JSON.parse(r.stdout).ok).toBe(true);
    expect(existsSync(path.join(f.home, "ran-0.0.4"))).toBe(false);
    expect(readFileSync(path.join(f.home, ".local/bin/ec"))).toEqual(
      readFileSync(released)
    );
  });

  it("downloads a public release from GitHub without credentials", () => {
    const f = setup();
    const repo = configRepo(f);
    const next = f.release("0.0.9");
    const manifest = JSON.parse(readFileSync(next.manifest, "utf-8"));
    manifest.assets[assetKey()].path = undefined;
    write(f.root, "github/manifest.json", JSON.stringify(manifest));
    write(f.root, "github/binary", next.bytes.toString());
    write(
      f.root,
      "github/release.json",
      JSON.stringify({
        assets: [
          { name: "manifest.json", url: "https://api.github.com/assets/1" },
          { name: `ec-${assetKey()}`, url: "https://api.github.com/assets/2" },
        ],
        tag_name: "v0.0.9",
      })
    );
    f.fake(
      "curl",
      `const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.HOME + "/requests", fs.readFileSync(args[args.indexOf("--config") + 1], "utf-8"));
const url = args.at(-1);
const file = url.endsWith("/latest") ? "release.json" : url.endsWith("/1") ? "manifest.json" : "binary";
fs.copyFileSync(${JSON.stringify(path.join(f.root, "github"))} + "/" + file, args[args.indexOf("-o") + 1]);`
    );
    const r = f.run(["sync", "--skip-packages"], { EC_REPO: repo });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(existsSync(path.join(f.home, "ran-0.0.9"))).toBe(true);
    const requests = readFileSync(path.join(f.home, "requests"), "utf-8");
    expect(requests).toContain("Accept: application/octet-stream");
    expect(requests).not.toContain("Authorization");
  });
});

describe("update notice", () => {
  it("appears once a day after an interactive command", () => {
    const f = setup();
    seed(f, Math.floor(Date.now() / 1000));
    expect(tty(f, ["secret", "list"])).toContain(notice);
    expect(
      JSON.parse(readFileSync(f.state, "utf-8")).notified_at
    ).toBeGreaterThan(0);
    expect(tty(f, ["secret", "list"])).not.toContain(notice);
  });

  it.each([
    ["--json", ["secret", "list", "--json"], {}],
    ["CI", ["secret", "list"], { CI: "true" }],
    ["NO_UPDATE_NOTIFIER", ["secret", "list"], { NO_UPDATE_NOTIFIER: "1" }],
    ["EC_NO_UPDATE", ["secret", "list"], { EC_NO_UPDATE: "1" }],
  ])("stays quiet with %s", (_name, args, extra) => {
    const f = setup();
    seed(f, Math.floor(Date.now() / 1000));
    expect(tty(f, args, extra)).not.toContain(notice);
  });

  it("stays quiet when output is not a terminal", () => {
    const f = setup();
    seed(f, Math.floor(Date.now() / 1000));
    const r = f.run(["secret", "list"]);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout + r.stderr).not.toContain("Update available");
  });

  it("checks GitHub when the last check is a day old", () => {
    const f = setup();
    seed(f, 0, "0.0.5");
    write(f.root, "latest.json", JSON.stringify({ tag_name: "v0.0.9" }));
    f.fake(
      "curl",
      `const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.HOME + "/requests", args.join(" ") + "\\n");
fs.copyFileSync(${JSON.stringify(path.join(f.root, "latest.json"))}, args[args.indexOf("-o") + 1]);`
    );
    expect(tty(f, ["secret", "list"])).toContain(notice);
    const requests = readFileSync(path.join(f.home, "requests"), "utf-8");
    expect(requests.trim().split("\n")).toHaveLength(1);
    expect(requests).toContain("--max-time 3");
  });
});
