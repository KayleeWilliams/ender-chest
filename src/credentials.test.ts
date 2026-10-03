import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { gitInit, write, writeSourceRepo } from "./test/fixture.ts";

const executable = path.resolve("zig-out/bin/ec");
const endpoint = ".config/cliproxyapi/client.json";
const secret = ".config/ender-chest/secrets/cliproxyapi.json";
const roots: string[] = [];
afterEach(() => roots.splice(0).forEach(root => rmSync(root, { recursive: true, force: true })));

function fixture() {
  const root = mkdtempSync(path.join(tmpdir(), "ec-credentials-")); roots.push(root);
  const home = path.join(root, "home"), repo = path.join(root, "repo");
  mkdirSync(home); writeSourceRepo(repo); gitInit(repo);
  const env = { ...process.env, HOME: home, EC_REPO: repo, EC_NO_UPDATE: "1" };
  const run = (args: string[], input?: string) => spawnSync(executable, args, { cwd: root, env, input, encoding: "utf8", timeout: 15000 });
  const sync = () => run(["sync", "--skip-packages", "--json"]);
  return { root, home, repo, run, sync };
}

describe("device-local proxy credentials", () => {
  it("sets up from stdin without exposing the token or writing it to endpoint config", () => {
    const f = fixture(), token = "fixture-device-token";
    const r = f.run(["cliproxy", "setup", "--url", "https://proxy.example.test:8317", "--key-stdin", "--json"], `${token}\n`);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout + r.stderr).not.toContain(token);
    expect(JSON.parse(readFileSync(path.join(f.home, secret), "utf8"))).toEqual({ apiKey: token });
    expect(statSync(path.join(f.home, secret)).mode & 0o777).toBe(0o600);
    expect(statSync(path.dirname(path.join(f.home, secret))).mode & 0o777).toBe(0o700);
    expect(JSON.parse(readFileSync(path.join(f.home, endpoint), "utf8"))).toEqual({ baseURL: "https://proxy.example.test:8317" });
    expect(existsSync(path.join(f.repo, "home", secret))).toBe(false);
    const synced = f.sync(); expect(synced.status, synced.stdout + synced.stderr).toBe(0);
    expect(readFileSync(path.join(f.home, ".codex/config.toml"), "utf8")).toContain(token);
  });

  it("migrates the installed token before syncing and preserves it across repeated syncs", () => {
    const f = fixture();
    write(f.home, endpoint, JSON.stringify({ baseURL: "http://old.test", apiKey: "fixture-legacy-token" }));
    for (let n = 0; n < 2; n++) {
      const r = f.sync(); expect(r.status, r.stdout + r.stderr).toBe(0);
      expect(r.stdout + r.stderr).not.toContain("fixture-legacy-token");
      expect(JSON.parse(readFileSync(path.join(f.home, secret), "utf8")).apiKey).toBe("fixture-legacy-token");
      expect(JSON.parse(readFileSync(path.join(f.home, endpoint), "utf8"))).toEqual({ baseURL: "http://proxy.test:8317" });
    }
  });

  it("keeps a newer local token when a legacy client file is still present", () => {
    const f = fixture();
    write(f.home, secret, JSON.stringify({ apiKey: "fixture-new-token" }));
    write(f.home, endpoint, JSON.stringify({ baseURL: "http://old.test", apiKey: "fixture-old-token" }));
    const r = f.sync(); expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(JSON.parse(readFileSync(path.join(f.home, secret), "utf8")).apiKey).toBe("fixture-new-token");
  });

  it("syncs without proxy credentials and leaves existing agent authentication alone", () => {
    const f = fixture();
    write(f.home, ".claude/settings.json", JSON.stringify({ env: { ANTHROPIC_API_KEY: "fixture-direct-token" } }));
    const r = f.sync(); expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(r.stderr).toContain("ec cliproxy setup");
    expect(JSON.parse(readFileSync(path.join(f.home, ".claude/settings.json"), "utf8")).env.ANTHROPIC_API_KEY).toBe("fixture-direct-token");
    expect(readFileSync(path.join(f.home, ".codex/config.toml"), "utf8")).not.toContain("model_provider");
    expect(f.run(["cliproxy", "url"]).status).toBe(0);
    const missing = f.run(["cliproxy", "models", "--json"]);
    expect(JSON.parse(missing.stdout).error.code).toBe("interaction_required");
  });

  it("refuses tokens in repo config before changing home files", () => {
    const f = fixture();
    write(f.repo, `home/${endpoint}`, JSON.stringify({ baseURL: "http://proxy.test", apiKey: "fixture-repo-token" }));
    const r = f.sync(); expect(r.status).toBe(1);
    expect(r.stdout).toContain("only baseURL");
    expect(r.stdout + r.stderr).not.toContain("fixture-repo-token");
    expect(existsSync(path.join(f.home, ".gitconfig"))).toBe(false);
    expect(existsSync(path.join(f.home, secret))).toBe(false);
  });

  it("excludes legacy tokens and generated agent credentials from both dry-run and real pushes", () => {
    const f = fixture(), token = "fixture-never-publish-token";
    const git = (...args: string[]) => {
      const r = spawnSync("git", args, { cwd: f.repo, encoding: "utf8" });
      expect(r.status, r.stderr).toBe(0); return r.stdout;
    };
    git("add", "."); git("commit", "-m", "Initial fixture");
    const remote = path.join(f.root, "remote.git");
    expect(spawnSync("git", ["init", "--bare", remote]).status).toBe(0);
    git("remote", "add", "origin", remote); git("push", "-u", "origin", "HEAD");
    write(f.home, endpoint, JSON.stringify({ baseURL: "http://updated.test", apiKey: token, otherSecret: token }));
    write(f.home, secret, JSON.stringify({ apiKey: token }));
    write(f.home, ".codex/config.toml", `token = "${token}"`);
    for (const args of [["push", "--dry-run"], ["push"]]) {
      const r = f.run(args); expect(r.status, r.stdout + r.stderr).toBe(0);
      expect(r.stdout + r.stderr).not.toContain(token);
      expect(JSON.parse(readFileSync(path.join(f.repo, "home", endpoint), "utf8"))).toEqual({ baseURL: "http://updated.test" });
      expect(existsSync(path.join(f.repo, "home", secret))).toBe(false);
      expect(existsSync(path.join(f.repo, "home/.codex"))).toBe(false);
    }
    expect(git("show", `HEAD:home/${endpoint}`)).not.toContain(token);
    expect(git("log", "-p", "--all")).not.toContain(token);
  });

  it("refuses a manually staged credentials file before committing", () => {
    const f = fixture();
    write(f.repo, `home/${secret}`, '{"apiKey":"fixture-staged-token"}');
    expect(spawnSync("git", ["add", "."], { cwd: f.repo }).status).toBe(0);
    const r = f.run(["push", "--json"]);
    expect(r.status).toBe(1); expect(r.stdout).toContain("Refusing credential or runtime path");
    expect(r.stdout + r.stderr).not.toContain("fixture-staged-token");
  });

  it("rejects unsafe endpoints, invalid tokens, and noninteractive prompts without writes", () => {
    const f = fixture();
    const prompt = f.run(["cliproxy", "setup", "--json"]);
    expect(JSON.parse(prompt.stdout).error.code).toBe("interaction_required");
    for (const url of ["https://user:fixture-secret@proxy.test", "https://proxy.test?token=fixture-secret"]) {
      const r = f.run(["cliproxy", "setup", "--url", url, "--key-stdin"], "fixture-token");
      expect(r.status).toBe(1); expect(r.stdout + r.stderr).not.toContain("fixture-secret");
    }
    const bad = f.run(["cliproxy", "setup", "--url", "https://proxy.test", "--key-stdin"], "bad token");
    expect(bad.status).toBe(1);
    expect(existsSync(path.join(f.home, secret))).toBe(false);
  });
});
