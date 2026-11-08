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
  hostTarget,
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

// A stand-in for GitHub's API behind curl: /releases/latest serves github/latest.json, and
// https://api.github.com/assets/NAME serves github/NAME. Anything else is a 404. ec sends its
// curl config on stdin. Each request is logged with its arguments and that config.
const fakeCurl = (
  github: string,
  log: string
) => `const fs = require("node:fs");
const args = process.argv.slice(2);
const config = fs.readFileSync(0, "utf-8");
const url = args.at(-1);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({ url, args, config }) + "\\n");
const file = url.endsWith("/releases/latest") ? "latest.json" : decodeURIComponent(url.split("/").at(-1));
const source = ${JSON.stringify(github)} + "/" + file;
if (!fs.existsSync(source)) process.exit(22);
process.stdout.write(fs.readFileSync(source));`;

// A release binary that prints its version for the post-download check and otherwise leaves
// a marker, so a test can tell it ran.
const binary = (version: string, runs = true) =>
  `#!/bin/sh\nif [ "\${1-}" = --version ]; then ${runs ? `echo "ec ${version} (abcdef0)"` : "exit 1"}; exit; fi\necho "$*" > "$HOME/ran-${version}"\n`;

const setup = () => {
  const root = mkdtempSync(path.join(tmpdir(), "ec-update-"));
  roots.push(root);
  const home = path.join(root, "home");
  const bin = path.join(root, "bin");
  const github = path.join(root, "github");
  const log = path.join(root, "requests.jsonl");
  mkdirSync(home);
  mkdirSync(bin);
  mkdirSync(github);
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
  fake("curl", fakeCurl(github, log));
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
  // A local release for EC_RELEASE_MANIFEST.
  const release = (
    version: string,
    { runs = true, sha256 }: { runs?: boolean; sha256?: string } = {}
  ) => {
    const asset = write(root, `release-${version}/ec`, binary(version, runs));
    chmodSync(asset, 0o755);
    const bytes = readFileSync(asset);
    const manifest = write(
      root,
      `release-${version}/manifest.json`,
      JSON.stringify({
        assets: {
          [hostTarget()]: {
            name: `ec-${hostTarget()}`,
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
  // Publishes a release on the fake GitHub, with its manifest and this machine's binary.
  const publish = (version: string) => {
    const bytes = binary(version);
    const name = `ec-${hostTarget()}`;
    write(github, name, bytes);
    write(
      github,
      "manifest.json",
      JSON.stringify({
        assets: {
          [hostTarget()]: {
            name,
            sha256: createHash("sha256").update(bytes).digest("hex"),
          },
        },
        source_hash: "b".repeat(64),
        version,
      })
    );
    write(
      github,
      "latest.json",
      JSON.stringify({
        assets: ["manifest.json", name].map((n) => ({
          name: n,
          url: `https://api.github.com/assets/${n}`,
        })),
        tag_name: `v${version}`,
      })
    );
  };
  const requests = (): { url: string; args: string[]; config: string }[] =>
    existsSync(log)
      ? readFileSync(log, "utf-8")
          .trim()
          .split("\n")
          .map((line) => JSON.parse(line))
      : [];
  return { bin, env, exe, home, publish, release, requests, root, run };
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

describe("sync in a config repo", () => {
  it("installs a newer release and resumes with it", () => {
    const f = setup();
    const repo = configRepo(f);
    const r = f.run(["sync", "--skip-packages"], {
      EC_RELEASE_MANIFEST: f.release("0.0.9").manifest,
      EC_REPO: repo,
    });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(r.stderr).toContain("Updating ec 0.0.5 to 0.0.9");
    const args = readFileSync(path.join(f.home, "ran-0.0.9"), "utf-8")
      .trim()
      .split(" ");
    expect(args[0]).toBe("sync");
    expect(args[args.indexOf("--repo") + 1]).toBe(repo);
    expect(args).toContain("--skip-packages");
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

  it("finishes with the running ec when the new release does not run", () => {
    const f = setup();
    const repo = configRepo(f);
    const r = f.run(["sync", "--skip-packages", "--json"], {
      EC_RELEASE_MANIFEST: f.release("0.0.9", { runs: false }).manifest,
      EC_REPO: repo,
    });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(r.stderr).toContain("did not run on this machine");
    expect(existsSync(path.join(f.home, "ran-0.0.9"))).toBe(false);
  });

  it("downloads a public release from GitHub without credentials", () => {
    const f = setup();
    const repo = configRepo(f);
    f.publish("0.0.9");
    const r = f.run(["sync", "--skip-packages"], { EC_REPO: repo });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(existsSync(path.join(f.home, "ran-0.0.9"))).toBe(true);
    expect(f.requests().some((q) => q.config.includes("Authorization"))).toBe(
      false
    );
  });

  it("sends a GitHub token to curl on stdin, never in its arguments", () => {
    const f = setup();
    f.publish("0.0.9");
    const token = "fixture-gh-token";
    const r = f.run(["update", "--check"], { GH_TOKEN: token });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    const requests = f.requests();
    expect(requests.length).toBeGreaterThan(0);
    for (const q of requests) {
      expect(q.config).toContain(`Authorization: Bearer ${token}`);
      expect(q.args.join(" ")).not.toContain(token);
    }
  });
});

describe("update notice", () => {
  it("says once a day that a newer release exists", () => {
    const f = setup();
    f.publish("0.0.9");
    expect(tty(f, ["secret", "list"])).toContain(notice);
    expect(tty(f, ["secret", "list"])).not.toContain(notice);
    expect(f.requests()).toHaveLength(1);
  });

  it("uses the release ec update found without asking GitHub again", () => {
    const f = setup();
    f.run(["update", "--check"], {
      EC_RELEASE_MANIFEST: f.release("0.0.9").manifest,
    });
    expect(tty(f, ["secret", "list"])).toContain(notice);
    expect(f.requests()).toHaveLength(0);
  });

  it.each([
    ["--json", ["secret", "list", "--json"], {}],
    ["CI", ["secret", "list"], { CI: "true" }],
    ["NO_UPDATE_NOTIFIER", ["secret", "list"], { NO_UPDATE_NOTIFIER: "1" }],
    ["EC_NO_UPDATE", ["secret", "list"], { EC_NO_UPDATE: "1" }],
  ])("stays quiet with %s", (_name, args, extra) => {
    const f = setup();
    f.publish("0.0.9");
    expect(tty(f, args, extra)).not.toContain(notice);
  });

  it("keeps the notice on with EC_NO_UPDATE=false", () => {
    const f = setup();
    f.publish("0.0.9");
    expect(tty(f, ["secret", "list"], { EC_NO_UPDATE: "false" })).toContain(
      notice
    );
  });

  it("stays quiet when output is not a terminal", () => {
    const f = setup();
    f.publish("0.0.9");
    const r = f.run(["secret", "list"]);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout + r.stderr).not.toContain("Update available");
  });
});
