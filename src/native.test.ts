import { createHash } from "node:crypto";
import { execFile, spawnSync } from "node:child_process";
import { createSocket, type Socket } from "node:dgram";
import { once } from "node:events";
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, readdirSync, realpathSync, rmSync, statSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { afterEach, describe, expect, it } from "vitest";
import { parse as toml } from "smol-toml";
import { writeSourceRepo, write, gitInit } from "./test/fixture.ts";

const executable = path.resolve("zig-out/bin/ec");
const roots: string[] = [];
const sockets: Socket[] = [];
const exec = promisify(execFile);
afterEach(() => {
  for (const s of sockets.splice(0)) s.close();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});
function fixture() {
  const root = mkdtempSync(path.join(tmpdir(), "ec-test-")); roots.push(root);
  const repo = path.join(root, "repo"); const home = path.join(root, "home");
  writeSourceRepo(repo); mkdirSync(home, { recursive: true });
  write(home, ".config/ender-chest/secrets/cliproxyapi.json", JSON.stringify({ apiKey: "test-client-key" }));
  gitInit(repo);
  const env = { ...process.env, HOME: home, EC_REPO: repo, DESKTOP_CONFIG: "", DESKTOP_RELAY: undefined, EC_NO_UPDATE: "1" };
  const run = (args: string[], overrides = {}) => spawnSync(executable, args, { env: { ...env, ...overrides }, cwd: root, encoding: "utf8", timeout: 15000 });
  const apply = () => { const r = run(["sync", "--skip-packages", "--profile", "mac"]); expect(r.status, r.stdout + r.stderr).toBe(0); };
  const fake = (name: string, code: string) => { const file = write(home, `bin/${name}`, `#!${process.execPath}\n${code}\n`); chmodSync(file, 0o755); return { PATH: `${path.dirname(file)}:/usr/bin:/bin` }; };
  return { root, repo, home, env, run, apply, fake };
}
function desktop() {
  const f = fixture();
  const configFile = write(f.home, ".config/desktop/config.json", JSON.stringify({ mac: "02:00:00:00:00:01", broadcast: "127.0.0.1", host: "desktop.test", relay: "relay.test", sshUser: "user" }));
  return { ...f, configFile, config: JSON.parse(readFileSync(configFile, "utf8")) };
}
function releaseAssetKey(): string {
  const arch = process.arch === "arm64" ? "aarch64" : process.arch === "x64" ? "x86_64" : process.arch;
  return `${arch}-${process.platform === "darwin" ? "macos" : "linux"}`;
}
function sourceHash(repo: string): string {
  const files = ["build.zig", "build.zig.zon", ".zig-version"];
  for (const name of readdirSync(path.join(repo, "src"))) if (name.endsWith(".zig")) files.push(path.join("src", name));
  files.sort();
  const hash = createHash("sha256");
  for (const rel of files) {
    hash.update(rel);
    hash.update("\0");
    hash.update(readFileSync(path.join(repo, rel)));
    hash.update("\0");
  }
  return hash.digest("hex");
}
async function receiver() {
  const socket = createSocket("udp4"); sockets.push(socket); socket.bind(0, "127.0.0.1"); await once(socket, "listening");
  return { port: socket.address().port, message: once(socket, "message") };
}

describe("native ec", () => {
  it("prints discoverable help without a runtime, HOME, repo, or config", () => {
    const r = spawnSync(executable, [], { env: { PATH: "/nonexistent" }, cwd: tmpdir(), encoding: "utf8" });
    expect(r.status, r.stderr).toBe(0); expect(r.stdout).toContain("ec <command>"); expect(r.stdout).toContain("--json");
    expect(r.stdout).toContain("desktop");
  });
  it("prints structured help and version without configuration", () => {
    const { run } = fixture();
    expect(JSON.parse(run(["--json", "--help"]).stdout)).toMatchObject({ schema_version: 1, command: "help", ok: true });
    expect(run(["--version"]).stdout.trim()).toBe(`ec dev (${sourceHash(process.cwd()).slice(0, 7)})`);
    expect(JSON.parse(run(["--json", "--version"]).stdout).data).toMatchObject({ version: "dev", source_hash: sourceHash(process.cwd()) });
    expect(run(["desktop", "auth", "--help"], { DESKTOP_CONFIG: "/missing" }).stdout).toContain("auth --setup");
  });
  it.each([
    { args: ["sync"], flags: ["repo", "profile", "skip-packages", "update-skills", "json", "help"] },
    { args: ["push"], flags: ["repo", "profile", "dry-run", "json", "help"] },
    { args: ["verify"], flags: ["repo", "profile", "json", "help"] },
    { args: ["desktop", "start"], flags: ["local", "via", "no-wait", "no-auth", "json", "help"] },
    { args: ["desktop", "stop"], flags: ["no-wait", "json", "help"] },
    { args: ["desktop", "status"], flags: ["json", "help"] },
    { args: ["desktop", "auth"], flags: ["setup", "forget", "local", "json", "help"] },
    { args: ["fleet", "status"], flags: ["json", "help"] },
    { args: ["fleet", "sync"], flags: ["json", "help"] },
  ])("scopes offline help and machine discovery to $args", ({ args, flags }) => {
    const run = (extra: string[]) => spawnSync(executable, extra, { env: { PATH: "/missing", DESKTOP_CONFIG: "/missing" }, cwd: tmpdir(), encoding: "utf8" });
    const human = run([...args, "--help"]);
    expect(human.status, human.stderr).toBe(0);
    expect(human.stdout).toContain(`Usage: ec ${args.join(" ")}`);
    expect(human.stdout).toContain("Examples:");
    expect(human.stdout).toContain("Effects:");
    const machine = run(["--json", ...args, "--help"]);
    expect(machine.status, machine.stderr).toBe(0);
    expect(machine.stderr).toBe("");
    const result = JSON.parse(machine.stdout);
    expect(result.error).toBeNull();
    expect(result.message + "\n").toBe(human.stdout);
    const definitions = result.data.command_definitions;
    expect(definitions).toHaveLength(1);
    expect(definitions[0]).toMatchObject({ command: args[0], action: args[1] ?? "" });
    expect(definitions[0].options.map((option: { name: string }) => option.name)).toEqual(flags);
    expect(run(["help", ...args]).stdout).toBe(human.stdout);
  });
  it("discovers command effects, defaults, and profile choices without running commands", () => {
    const f = fixture();
    const result = JSON.parse(f.run(["--help", "--json"]).stdout);
    const definitions = result.data.command_definitions;
    const sync = definitions.find((d: { command: string }) => d.command === "sync");
    expect(sync.options.find((o: { name: string }) => o.name === "profile")).toMatchObject({ type: "string", values: ["mac", "cloud"], default: "detected", required: false });
    const push = definitions.find((d: { command: string }) => d.command === "push");
    expect(push.effects.join(" ")).toContain("including with --dry-run");
    const desktop = JSON.parse(f.run(["help", "desktop", "--json"]).stdout).data.command_definitions;
    expect(desktop.map((d: { action: string }) => d.action)).toEqual(["start", "stop", "status", "auth"]);
    expect(existsSync(path.join(f.home, ".gitconfig"))).toBe(false);
  });
  it.each([
    { args: ["sync", "--profile"], message: "--profile needs mac or cloud." },
    { args: ["sync", "--repo", ""], message: "--repo needs a checkout path." },
    { args: ["desktop", "halt"], message: "Use start, stop, status, or auth." },
    { args: ["fleet", "update"], message: "Use status or sync." },
    { args: ["desktop", "start", "--local", "--via", "relay"], message: "either --local or --via" },
  ])("explains invalid arguments in human and JSON output: $args", ({ args, message }) => {
    const f = fixture();
    const human = f.run(args);
    expect(human.status).toBe(2); expect(human.stdout).toBe(""); expect(human.stderr).toContain(message);
    const machine = f.run([...args, "--json"]);
    expect(machine.status).toBe(2); expect(machine.stderr).toBe("");
    expect(JSON.parse(machine.stdout)).toMatchObject({ schema_version: 1, ok: false, error: { code: "usage_error", message: expect.stringContaining(message) } });
  });
  it("reports verification failures with a stable code", () => {
    const f = fixture(); const r = f.run(["verify", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout)).toMatchObject({ ok: false, error: { code: "verification_failed" } });
  });
  it.each([
    ["sync", "--profile"], ["sync", "--profile", "windows"], ["verify", "--dry-run"], ["desktop", "start", "--local", "--via", "relay"],
    ["desktop", "status", "--local"], ["desktop", "status", "--repo", "/missing"], ["desktop", "auth", "--setup", "--forget"], ["desktop", "stop", "--local"], ["fleet", "--no-wait"], ["sync", "push"], ["--nope"],
  ])("rejects invalid arguments without writes: %j", (...args) => {
    const { run, home } = fixture(); const r = run([...args, "--json"]);
    expect(r.status).toBe(2); expect(JSON.parse(r.stdout)).toMatchObject({ ok: false, command: "arguments" });
    expect(existsSync(path.join(home, ".gitconfig"))).toBe(false);
  });
  it("applies a clean machine, installs a native binary, and verifies without Node", () => {
    const f = fixture(); const r = f.run(["sync", "--skip-packages", "--json"], { PATH: "/usr/bin:/bin" });
    expect(r.status, r.stdout + r.stderr).toBe(0); expect(JSON.parse(r.stdout)).toMatchObject({ ok: true, command: "sync" });
    expect(statSync(path.join(f.home, ".ssh/config")).mode & 0o777).toBe(0o600);
    expect(statSync(path.join(f.home, ".ssh")).mode & 0o777).toBe(0o700);
    expect(statSync(path.join(f.home, ".config/cliproxyapi/client.json")).mode & 0o777).toBe(0o600);
    expect(readFileSync(path.join(f.home, ".local/bin/ec"))).toEqual(readFileSync(executable));
    for (const agent of [".claude", ".codex", ".grok"]) expect(readlinkSync(path.join(f.home, agent, "skills/note"))).toBe(path.join(f.home, ".agents/skills/note"));
    const installed = spawnSync(path.join(f.home, ".local/bin/ec"), ["verify", "--json"], { env: { HOME: f.home, PATH: "/usr/bin:/bin" }, cwd: tmpdir(), encoding: "utf8" });
    expect(installed.status, installed.stderr).toBe(0); expect(JSON.parse(installed.stdout).ok).toBe(true);
    const legacy = spawnSync(path.join(f.home, ".local/bin/desktop"), ["--help"], { env: { HOME: f.home, PATH: "/usr/bin:/bin" }, encoding: "utf8" });
    expect(legacy.status).toBe(0); expect(legacy.stdout).toContain("ec desktop start");
  });
  it("syncs the primary checkout from a linked worktree without a failed pull", () => {
    const f = fixture();
    const git = (cwd: string, ...args: string[]) => {
      const r = spawnSync("git", args, { cwd, encoding: "utf8" });
      expect(r.status, r.stderr).toBe(0);
      return r;
    };
    git(f.repo, "add", ".");
    git(f.repo, "commit", "-m", "init");
    git(f.repo, "branch", "-M", "main");
    const remote = path.join(f.root, "remote.git");
    expect(spawnSync("git", ["init", "--bare", remote], { encoding: "utf8" }).status).toBe(0);
    git(f.repo, "remote", "add", "origin", remote);
    git(f.repo, "push", "-u", "origin", "main");
    git(f.repo, "branch", "feature");
    const worktree = path.join(f.root, "worktree");
    git(f.repo, "worktree", "add", worktree, "feature");
    const env: NodeJS.ProcessEnv = { ...f.env };
    delete env.EC_REPO;
    const r = spawnSync(executable, ["sync", "--skip-packages", "--json"], { env, cwd: worktree, encoding: "utf8", timeout: 15000 });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(JSON.parse(r.stdout)).toMatchObject({ ok: true, command: "sync" });
    expect(r.stderr).not.toContain("git pull failed");
    expect(realpathSync(readFileSync(path.join(f.home, ".config/ender-chest/repo"), "utf8").trim())).toBe(realpathSync(f.repo));
  });
  it("does not treat a missing upstream as a failed pull", () => {
    const f = fixture();
    const git = (...args: string[]) => {
      const r = spawnSync("git", args, { cwd: f.repo, encoding: "utf8" });
      expect(r.status, r.stderr).toBe(0);
    };
    git("add", ".");
    git("commit", "-m", "init");
    git("branch", "-M", "feature");
    const remote = path.join(f.root, "remote.git");
    expect(spawnSync("git", ["init", "--bare", remote], { encoding: "utf8" }).status).toBe(0);
    git("remote", "add", "origin", remote);
    git("push", "origin", "feature");
    const r = f.run(["sync", "--skip-packages", "--json"]);
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(JSON.parse(r.stdout).ok).toBe(true);
    expect(r.stderr).not.toContain("git pull failed");
  });
  it("sync is idempotent and preserves local settings, trust, hooks, and credentials", () => {
    const f = fixture();
    write(f.home, ".gitconfig.local", "# machine-local\n"); write(f.home, ".ssh/id_ed25519", "PRIVATE KEY");
    write(f.home, ".claude/.credentials.json", '{"token":"PRIVATE"}');
    write(f.home, ".claude/settings.json", JSON.stringify({ hooks: { Start: [] }, env: { LOCAL: "keep" }, model: "old" }));
    write(f.home, ".claude.json", JSON.stringify({ oauth: "keep", mcpServers: { local: { command: "local" } } }));
    write(f.home, ".codex/config.toml", 'model="personal"\n[projects."/work/a.b"]\ntrust_level="trusted"\n[model_providers.cliproxyapi]\nenv_key="OLD"\n');
    f.apply();
    const settings = JSON.parse(readFileSync(path.join(f.home, ".claude/settings.json"), "utf8"));
    expect(settings).toMatchObject({ hooks: { Start: [] }, env: { LOCAL: "keep", ANTHROPIC_AUTH_TOKEN: "test-client-key" } });
    expect(JSON.parse(readFileSync(path.join(f.home, ".claude.json"), "utf8"))).toMatchObject({ oauth: "keep", mcpServers: { local: { command: "local" }, executor: { url: "https://example.test/mcp" } } });
    const before = readFileSync(path.join(f.home, ".codex/config.toml"), "utf8");
    expect(toml(before)).toMatchObject({ model: "personal", projects: { "/work/a.b": { trust_level: "trusted" } } }); expect(before).not.toContain("OLD");
    f.apply(); expect(readFileSync(path.join(f.home, ".codex/config.toml"), "utf8")).toBe(before);
    expect(readFileSync(path.join(f.home, ".gitconfig.local"), "utf8")).toBe("# machine-local\n");
    expect(readFileSync(path.join(f.home, ".ssh/id_ed25519"), "utf8")).toBe("PRIVATE KEY");
    expect(readFileSync(path.join(f.home, ".claude/.credentials.json"), "utf8")).toContain("PRIVATE");
  });
  it("writes agent TOML that Codex can extend when it trusts a new project", () => {
    const f = fixture();
    write(f.home, ".codex/config.toml", '"projects" = { "/work/a" = { "trust_level" = "trusted" } }\n');
    f.apply();
    const file = path.join(f.home, ".codex/config.toml");
    const extended = `${readFileSync(file, "utf8")}\n[projects."/work/b"]\ntrust_level = "trusted"\n`;
    expect(toml(extended)).toMatchObject({ projects: { "/work/a": { trust_level: "trusted" }, "/work/b": { trust_level: "trusted" } } });
  });
  it("writes bare table names so Orca finds projects that are already trusted", () => {
    const f = fixture();
    write(f.home, ".codex/config.toml", '[projects."/work/a"]\ntrust_level = "trusted"\n[hooks.state."/work/a:stop:0:0"]\nenabled = true\n');
    f.apply();
    const text = readFileSync(path.join(f.home, ".codex/config.toml"), "utf8");
    // Orca matches /^\[[ \t]*projects[ \t]*\./ before deciding to append a new [projects."..."] table.
    expect(text).toContain('\n[projects."/work/a"]\ntrust_level = "trusted"\n');
    expect(text).toContain('\n[hooks.state."/work/a:stop:0:0"]\nenabled = true\n');
    expect(text).toContain('\n[model_providers.cliproxyapi]\n');
  });
  it("leaves malformed local TOML intact and reports its path without secret contents", () => {
    const f = fixture(); const file = write(f.home, ".codex/config.toml", 'bad = [ PRIVATE_SECRET');
    const r = f.run(["sync", "--skip-packages", "--json"]);
    expect(r.status).toBe(1); expect(JSON.parse(r.stdout).message).toContain(file);
    expect(r.stdout + r.stderr).not.toContain("PRIVATE_SECRET"); expect(readFileSync(file, "utf8")).toBe('bad = [ PRIVATE_SECRET');
  });
  it("rebuilds an installed CLI after source changes, then syncs without a compiler", () => {
    const f = fixture();
    for (const name of ["build.zig", "build.zig.zon", ".zig-version"]) cpSync(path.resolve(name), path.join(f.repo, name));
    mkdirSync(path.join(f.repo, "src"));
    for (const name of readdirSync(path.resolve("src"))) if (name.endsWith(".zig")) cpSync(path.resolve("src", name), path.join(f.repo, "src", name));
    cpSync(path.resolve("zig-pkg"), path.join(f.repo, "zig-pkg"), { recursive: true });
    cpSync(path.resolve("tools/zig"), path.join(f.repo, "tools/zig"));
    const main = path.join(f.repo, "src/main.zig"); writeFileSync(main, readFileSync(main, "utf8") + "\n// Fixture source update.\n");
    const compilerEnv = spawnSync(path.resolve("tools/zig"), ["env"], { encoding: "utf8" });
    expect(compilerEnv.status, compilerEnv.stderr).toBe(0);
    const compiler = /\.zig_exe = "([^"]+)"/.exec(compilerEnv.stdout)![1]!;
    write(f.home, ".local/lib/desktop/cli.mjs", "obsolete"); write(f.home, ".local/lib/desktop/auth.mjs", "obsolete");
    const r = spawnSync(executable, ["sync", "--skip-packages", "--json"], {
      env: { ...f.env, ZIG: compiler, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? path.join(homedir(), ".cache/zig") },
      encoding: "utf8", timeout: 90000,
    });
    expect(r.status, r.stdout + r.stderr).toBe(0); expect(JSON.parse(r.stdout).ok).toBe(true); expect(r.stderr).toContain("CLI sources changed");
    const installed = path.join(f.home, ".local/bin/ec"); expect(readFileSync(installed)).not.toEqual(readFileSync(executable));
    expect(readFileSync(installed)).toEqual(readFileSync(path.join(f.repo, "zig-out/bin/ec")));
    expect(existsSync(path.join(f.home, ".local/lib/desktop/cli.mjs"))).toBe(false);
    const second = spawnSync(installed, ["sync", "--skip-packages", "--json"], { env: { HOME: f.home, EC_REPO: f.repo, PATH: "/usr/bin:/bin", ZIG: "/missing/compiler" }, encoding: "utf8", timeout: 15000 });
    expect(second.status, second.stdout + second.stderr).toBe(0); expect(JSON.parse(second.stdout).ok).toBe(true); expect(second.stderr).not.toContain("rebuilding");
  }, 100000);
  it("installs a matching release binary instead of rebuilding", () => {
    const f = fixture();
    for (const name of ["build.zig", "build.zig.zon", ".zig-version"]) cpSync(path.resolve(name), path.join(f.repo, name));
    mkdirSync(path.join(f.repo, "src"));
    for (const name of readdirSync(path.resolve("src"))) if (name.endsWith(".zig")) cpSync(path.resolve("src", name), path.join(f.repo, "src", name));
    writeFileSync(path.join(f.repo, "src/main.zig"), readFileSync(path.join(f.repo, "src/main.zig"), "utf8") + "\n// Release fixture.\n");
    const asset = path.join(f.root, "ec-release");
    writeFileSync(asset, "#!/bin/sh\nprintf '%s\\n' release-installed > \"$HOME/release-marker\"\nexit 0\n");
    chmodSync(asset, 0o755);
    const bytes = readFileSync(asset);
    const manifest = write(f.root, "manifest.json", JSON.stringify({
      schema_version: 1,
      version: "0.0.2",
      source_hash: sourceHash(f.repo),
      assets: { [releaseAssetKey()]: { name: "ec-test", sha256: createHash("sha256").update(bytes).digest("hex"), path: asset } },
    }));
    const r = f.run(["sync", "--skip-packages", "--json"], { EC_NO_UPDATE: "", EC_RELEASE_MANIFEST: manifest });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(r.stderr).toContain("Updating ec to 0.0.2");
    expect(readFileSync(path.join(f.home, "release-marker"), "utf8").trim()).toBe("release-installed");
    expect(readFileSync(path.join(f.home, ".local/bin/ec"))).toEqual(bytes);
  });
  it("updates the CLI from its release when the config repo contains no source", () => {
    const f = fixture();
    const asset = write(f.root, "ec-release", "#!/bin/sh\nprintf '%s\\n' upgraded > \"$HOME/upgrade-marker\"\n");
    chmodSync(asset, 0o755);
    const manifest = write(f.root, "manifest.json", JSON.stringify({
      version: "0.0.2", source_hash: "a".repeat(64),
      assets: { [releaseAssetKey()]: { name: "ec-test", sha256: createHash("sha256").update(readFileSync(asset)).digest("hex"), path: asset } },
    }));
    const r = f.run(["sync", "--skip-packages"], { EC_NO_UPDATE: "", EC_RELEASE_MANIFEST: manifest });
    expect(r.status, r.stderr).toBe(0);
    expect(readFileSync(path.join(f.home, "upgrade-marker"), "utf8").trim()).toBe("upgraded");
  });
  it("refuses a release whose checksum does not match", () => {
    const f = fixture();
    for (const name of ["build.zig", "build.zig.zon", ".zig-version"]) cpSync(path.resolve(name), path.join(f.repo, name));
    mkdirSync(path.join(f.repo, "src"));
    for (const name of readdirSync(path.resolve("src"))) if (name.endsWith(".zig")) cpSync(path.resolve("src", name), path.join(f.repo, "src", name));
    writeFileSync(path.join(f.repo, "src/main.zig"), readFileSync(path.join(f.repo, "src/main.zig"), "utf8") + "\n// Bad checksum fixture.\n");
    const asset = write(f.root, "ec-release", "not a binary\n");
    const manifest = write(f.root, "manifest.json", JSON.stringify({
      schema_version: 1,
      version: "0.0.2",
      source_hash: sourceHash(f.repo),
      assets: { [releaseAssetKey()]: { name: "ec-test", sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", path: asset } },
    }));
    const r = f.run(["sync", "--skip-packages", "--json"], { EC_NO_UPDATE: "", EC_RELEASE_MANIFEST: manifest, ZIG: "/missing/compiler" });
    expect(r.status, r.stdout + r.stderr).not.toBe(0);
    expect(r.stderr).toContain("checksum did not match");
    expect(existsSync(path.join(f.home, ".local/bin/ec"))).toBe(false);
  });
  it("numbers patch releases from 0.0.1", () => {
    const script = path.resolve("tools/release-version.sh");
    const run = (arg?: string) => spawnSync(script, arg === undefined ? [] : [arg], { encoding: "utf8" });
    expect(run().stdout).toBe("0.0.1\n");
    expect(run("v0.0.1").stdout).toBe("0.0.2\n");
    expect(run("0.0.9").stdout).toBe("0.0.10\n");
    expect(run("0.1.0").status).not.toBe(0);
  });
  it("verify detects missing files and incorrect skill links without fixing them", () => {
    const f = fixture(); f.apply(); unlinkSync(path.join(f.home, ".gitconfig"));
    const link = path.join(f.home, ".codex/skills/note"); unlinkSync(link); symlinkSync(f.repo, link);
    const r = f.run(["verify", "--json"]); expect(r.status).toBe(1); expect(JSON.parse(r.stdout).ok).toBe(false);
    expect(r.stderr).toContain(".gitconfig"); expect(r.stderr).toContain("must link"); expect(existsSync(path.join(f.home, ".gitconfig"))).toBe(false);
  });
  it("push dry-run captures only portable files and personal skills without committing", () => {
    const f = fixture(); f.apply();
    write(f.home, ".gitconfig", "# captured\n"); write(f.home, ".gitconfig.local", "SECRET"); write(f.home, ".ssh/id_ed25519", "PRIVATE KEY");
    write(f.home, ".agents/skills/personal/SKILL.md", "# personal\n"); write(f.home, ".claude/.credentials.json", "SECRET");
    const r = f.run(["push", "--dry-run", "--json"]); expect(r.status, r.stdout + r.stderr).toBe(0); expect(JSON.parse(r.stdout).message).toContain("Dry-run");
    expect(readFileSync(path.join(f.repo, "home/.gitconfig"), "utf8")).toBe("# captured\n");
    expect(existsSync(path.join(f.repo, "skills/personal/SKILL.md"))).toBe(true);
    for (const rel of ["home/.gitconfig.local", "home/.ssh/id_ed25519", "home/.claude/.credentials.json", "home/.local/bin/ec"]) expect(existsSync(path.join(f.repo, rel))).toBe(false);
    expect(spawnSync("git", ["log", "-1"], { cwd: f.repo }).status).not.toBe(0);
  });
  it("push commits and uploads managed changes to a local bare remote", () => {
    const f = fixture();
    const git = (...args: string[]) => { const r = spawnSync("git", args, { cwd: f.repo, encoding: "utf8" }); expect(r.status, r.stderr).toBe(0); return r.stdout.trim(); };
    const remote = path.join(f.root, "remote.git"); git("init", "--bare", remote); git("add", "."); git("commit", "-m", "Initial config"); git("remote", "add", "origin", remote); git("push", "-u", "origin", "HEAD");
    f.apply(); write(f.home, ".gitconfig", "# captured change\n"); write(f.repo, "unrelated.txt", "keep local");
    const r = f.run(["push", "--json"]); expect(r.status, r.stdout + r.stderr).toBe(0); expect(JSON.parse(r.stdout).message).toContain("Uploaded");
    expect(git("show", "HEAD:home/.gitconfig")).toBe("# captured change"); expect(git("status", "--short")).toContain("?? unrelated.txt");
    expect(git("log", "-1", "--format=%H")).toBe(git("log", "-1", "--format=%H", "@{upstream}"));
  });
  it("push refuses to commit unrelated staged files", () => {
    const f = fixture(); f.apply(); write(f.repo, "unrelated.txt", "keep staged");
    expect(spawnSync("git", ["add", "unrelated.txt"], { cwd: f.repo }).status).toBe(0);
    const r = f.run(["push", "--json"]); expect(r.status).toBe(1); expect(JSON.parse(r.stdout).message).toContain("Unrelated staged file");
    expect(spawnSync("git", ["diff", "--cached", "--name-only"], { cwd: f.repo, encoding: "utf8" }).stdout.trim()).toBe("unrelated.txt");
  });
  it("harvests installed skill sources and honors explicit removals", () => {
    const f = fixture(); f.apply();
    write(f.home, ".agents/skills/third/SKILL.md", "# Third"); write(f.home, ".agents/skills/removed/SKILL.md", "# removed");
    write(f.home, ".agents/.skill-lock.json", JSON.stringify({ skills: { third: { source: "owner/repo" }, removed: { source: "owner/no" } } }));
    write(f.repo, "skills/manifest.json", JSON.stringify({ version: 1, skills: [], remove: [{ name: "removed" }] }));
    expect(f.run(["push", "--dry-run"]).status).toBe(0);
    expect(JSON.parse(readFileSync(path.join(f.repo, "skills/manifest.json"), "utf8")).skills).toEqual([{ name: "third", source: "owner/repo", skill: "third" }]);
    expect(existsSync(path.join(f.repo, "skills/third"))).toBe(false); expect(existsSync(path.join(f.repo, "skills/removed"))).toBe(false);
  });
  it("migrates Claude-local skills and removes obsolete files when a personal skill changes", () => {
    const f = fixture();
    write(f.repo, "skills/manifest.json", JSON.stringify({ version: 1, skills: [{ name: "third", source: "owner/repo", skill: "third" }], remove: [{ name: "removed" }] }));
    write(f.home, ".claude/skills/third/SKILL.md", "# Third"); write(f.home, ".agents/skills/note/stale.md", "stale");
    write(f.home, ".agents/skills/removed/SKILL.md", "# removed");
    f.apply(); expect(lstatSync(path.join(f.home, ".claude/skills/third")).isSymbolicLink()).toBe(true);
    expect(readFileSync(path.join(f.home, ".agents/skills/third/SKILL.md"), "utf8")).toBe("# Third");
    expect(existsSync(path.join(f.home, ".agents/skills/note/stale.md"))).toBe(false); expect(existsSync(path.join(f.home, ".agents/skills/removed"))).toBe(false);
  });
  it("installs third-party skills through git, groups sources, and excludes profiles", () => {
    const f = fixture(); const log = path.join(f.root, "git.log");
    const env = f.fake("git", `const fs=require('node:fs'),p=require('node:path'),a=process.argv.slice(2); fs.appendFileSync(${JSON.stringify(log)},JSON.stringify(a)+'\\n'); if(a[0]==='clone'){for(const name of ['one','two']) {const dest=p.join(a.at(-1),'skills',name);fs.mkdirSync(dest,{recursive:true});fs.writeFileSync(p.join(dest,'SKILL.md'),'---\\nname: '+name+'\\n---\\n# Skill');}}`);
    write(f.repo, "skills/manifest.json", JSON.stringify({ version: 1, skills: [{ name: "one", source: "owner/repo#main", skill: "one" }, { name: "two", source: "owner/repo#main", skill: "two" }, { name: "mac-only", source: "owner/mac", skill: "mac-only", profiles: ["mac"] }] }));
    const r = f.run(["sync", "--skip-packages", "--profile", "cloud"], env); expect(r.status, r.stdout + r.stderr).toBe(0);
    const calls = readFileSync(log, "utf8").trim().split("\n").map(s => JSON.parse(s));
    expect(calls.filter(a => a[0] === "clone")).toHaveLength(1); expect(calls.flat()).toContain("https://github.com/owner/repo.git");
    expect(existsSync(path.join(f.home, ".agents/skills/two/SKILL.md"))).toBe(true);
    expect(existsSync(path.join(f.home, ".agents/skills/mac-only"))).toBe(false);
  });
  it("rejects traversal in skill removals before deleting anything", () => {
    const f = fixture(); const keep = write(f.home, "keep", "safe");
    write(f.repo, "skills/manifest.json", JSON.stringify({ version: 1, skills: [], remove: [{ name: "../../keep" }] }));
    const r = f.run(["sync", "--skip-packages", "--json"]); expect(r.status).toBe(1); expect(readFileSync(keep, "utf8")).toBe("safe");
  });
});

describe("native desktop", () => {
  it("sends a real 102-byte UDP magic packet with no runtime on PATH", async () => {
    const f = desktop(); const { port, message } = await receiver(); writeFileSync(f.configFile, JSON.stringify({ ...f.config, port }));
    const r = await exec(executable, ["desktop", "start", "--local", "--no-wait", "--json"], { env: { ...f.env, PATH: "/nonexistent" } });
    const [packet] = await message; expect(packet).toEqual(Buffer.from("ff".repeat(6) + "020000000001".repeat(16), "hex"));
    expect(JSON.parse(r.stdout)).toMatchObject({ ok: true, command: "desktop start" }); expect(r.stdout).not.toContain("is reachable");
  });
  it("relays through the installed native command with a minimal SSH PATH", async () => {
    const client = desktop(), relay = desktop(); relay.apply();
    const { port, message } = await receiver(); writeFileSync(relay.configFile, JSON.stringify({ ...relay.config, port }));
    const log = path.join(client.root, "ssh.json");
    const env = client.fake("ssh", `const fs=require('node:fs'),cp=require('node:child_process'),a=process.argv.slice(2);fs.writeFileSync(${JSON.stringify(log)},JSON.stringify(a));const r=cp.spawnSync('/bin/sh',['-c',a.at(-1)],{env:{HOME:${JSON.stringify(relay.home)},PATH:'/usr/bin:/bin'},stdio:'inherit'});process.exit(r.status??1);`);
    const result = await exec(executable, ["desktop", "start", "--no-wait", "--json"], { env: { ...client.env, ...env } });
    const [packet] = await message; expect(packet.length).toBe(102);
    expect(JSON.parse(readFileSync(log, "utf8"))).toEqual(["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "relay.test", '"$HOME/.local/bin/ec" desktop start --local --no-wait']);
    expect(JSON.parse(result.stdout).ok).toBe(true);
  });
  it("prioritizes --via over the environment and reports relay failures as JSON", () => {
    const f = desktop(); const env = f.fake("ssh", "console.error(process.argv.slice(2).join(' '));process.exit(255)");
    const r = f.run(["desktop", "start", "--via", "other@relay.test", "--no-wait", "--json"], { ...env, DESKTOP_RELAY: "env.test" });
    expect(r.status).toBe(1); expect(JSON.parse(r.stdout).ok).toBe(false); expect(r.stderr).toContain("other@relay.test"); expect(r.stderr).not.toContain("env.test");
  });
  it.each(["-oProxyCommand=bad", "host;echo bad", "$(echo bad)"])("rejects unsafe relay %s", relay => {
    const f = desktop(); const r = f.run(["desktop", "start", "--no-wait", "--json"], { DESKTOP_RELAY: relay }); expect(r.status).toBe(1); expect(JSON.parse(r.stdout).message).toContain("Invalid wake relay");
  });
  it.each([{ mac: "02:00:00:00:00" }, { broadcast: "host.test" }, { port: 0 }, { port: 65536 }, { port: 1.5 }])("rejects bad wake settings %j", change => {
    const f = desktop(); writeFileSync(f.configFile, JSON.stringify({ ...f.config, ...change })); const r = f.run(["desktop", "start", "--local", "--no-wait", "--json"]);
    expect(r.status).toBe(1); expect(JSON.parse(r.stdout).message).toContain("Invalid");
  });
  it.each([0, 1])("reports reachability without asserting power state: %d", code => {
    const f = desktop(); const r = f.run(["desktop", "status", "--json"], f.fake("ping", `process.exit(${code})`));
    expect(r.status).toBe(code); expect(JSON.parse(r.stdout).ok).toBe(code === 0); if (code) { expect(r.stdout).toContain("disconnected from Tailscale"); expect(JSON.parse(r.stdout).error.code).toBe("unreachable"); } else expect(JSON.parse(r.stdout).error).toBeNull();
  });
  it("times out even if ping closes both output streams before hanging", () => {
    const f = desktop(); const env = f.fake("ping", "const fs=require('node:fs');fs.closeSync(1);fs.closeSync(2);setTimeout(()=>{},20000)");
    const start = Date.now(); const r = f.run(["desktop", "status", "--json"], env);
    expect(r.status).toBe(1); expect(JSON.parse(r.stdout).message).toContain("not reachable"); expect(Date.now() - start).toBeLessThan(10000);
  }, 12000);
  it("fails explicitly for missing config and refuses interactive auth in JSON mode", () => {
    const f = desktop(); const missing = JSON.parse(f.run(["desktop", "status", "--json"], { DESKTOP_CONFIG: "/missing" }).stdout); expect(missing.message).toContain("Cannot read"); expect(missing.error.code).toBe("operation_failed");
    const r = f.run(["desktop", "auth", "--setup", "--json"]); expect(r.status).toBe(1); expect(JSON.parse(r.stdout).message).toContain("cannot use --json"); expect(JSON.parse(r.stdout).error.code).toBe("interaction_required");
  });
  // Fake ping answers from a script of exit codes, one per call, repeating the last.
  function pings(f: ReturnType<typeof desktop>, codes: number[]) {
    const count = path.join(f.root, "pings");
    return f.fake("ping", `const fs=require('node:fs'),f=${JSON.stringify(count)},c=${JSON.stringify(codes)};const n=fs.existsSync(f)?+fs.readFileSync(f,'utf8'):0;fs.writeFileSync(f,String(n+1));process.exit(c[Math.min(n,c.length-1)]);`);
  }
  it("wakes, waits until the desktop answers, and reports it awake", async () => {
    const f = desktop(); const { port, message } = await receiver(); writeFileSync(f.configFile, JSON.stringify({ ...f.config, port }));
    const r = await exec(executable, ["desktop", "start", "--local", "--no-auth", "--json"], { env: { ...f.env, ...pings(f, [1, 1, 0]) } });
    const [packet] = await message; expect(packet.length).toBe(102);
    expect(JSON.parse(r.stdout)).toMatchObject({ ok: true, command: "desktop start", message: "Desktop is awake." });
    expect(r.stderr).toContain("Waiting up to 180s");
  }, 15000);
  it("skips the wake packet and unlocks when the desktop is already awake", () => {
    const f = desktop(); const log = path.join(f.root, "ssh.json");
    const env = { ...pings(f, [0]), ...f.fake("ssh", `require('node:fs').appendFileSync(${JSON.stringify(log)},JSON.stringify(process.argv.slice(2))+"\\n");console.log('unlocked')`) };
    const r = f.run(["desktop", "start", "--json"], env);
    expect(r.status, r.stderr).toBe(0); const result = JSON.parse(r.stdout);
    expect(result.message).toContain("Desktop is already awake.");
    if (process.platform === "darwin") { expect(result.message).toContain("already unlocked"); expect(readFileSync(log, "utf8")).toContain("user@desktop.test"); expect(readFileSync(log, "utf8")).not.toContain("relay.test"); }
  });
  it("reports unreachable when the desktop never answers", () => {
    const f = desktop(); writeFileSync(f.configFile, JSON.stringify({ ...f.config, port: 9, waitSeconds: 1 }));
    const r = f.run(["desktop", "start", "--local", "--json"], pings(f, [1]));
    expect(r.status).toBe(1); expect(JSON.parse(r.stdout)).toMatchObject({ ok: false, error: { code: "unreachable" } }); expect(JSON.parse(r.stdout).message).toContain("did not respond within 1s");
  });
  it("shuts down through KDE and waits until the desktop is offline", () => {
    const f = desktop(); const log = path.join(f.root, "ssh.json");
    const env = { ...pings(f, [0, 0, 1]), ...f.fake("ssh", `require('node:fs').writeFileSync(${JSON.stringify(log)},JSON.stringify(process.argv.slice(2)));console.log('ready')`) };
    const r = f.run(["desktop", "stop", "--json"], env);
    expect(r.status, r.stderr).toBe(0); expect(JSON.parse(r.stdout)).toMatchObject({ ok: true, command: "desktop stop", message: "Desktop is off." });
    const args = JSON.parse(readFileSync(log, "utf8")); expect(args).toContain("user@desktop.test"); expect(args).toContain("BatchMode=yes"); expect(args.at(-1)).toContain("org.kde.Shutdown logoutAndShutdown");
  }, 15000);
  it("does not wait for shutdown when SSH never connects, and treats an offline desktop as stopped", () => {
    const f = desktop(); const failed = f.run(["desktop", "stop", "--json"], { ...pings(f, [0]), ...f.fake("ssh", "console.error('Permission denied');process.exit(255)") });
    expect(failed.status).toBe(1); expect(JSON.parse(failed.stdout).message).toContain("Cannot SSH to user@desktop.test");
    const off = desktop(); const r = off.run(["desktop", "stop", "--json"], pings(off, [1]));
    expect(r.status).toBe(0); expect(JSON.parse(r.stdout).message).toContain("already off");
  });
});

describe("native fleet", () => {
  function fleet(fetches = true) {
    const f = fixture(); const hash = sourceHash(process.cwd());
    const manifest = write(f.root, "manifest.json", JSON.stringify({ schema_version: 1, version: "0.0.9", source_hash: hash, assets: {} }));
    const status = { Self: { HostName: "Example\u2019s Mac", DNSName: "here.tail.ts.net.", OS: "macOS", UserID: 1, Online: true }, Peer: {
      a: { HostName: "box", DNSName: "box.tail.ts.net.", OS: "linux", UserID: 1, Online: true },
      b: { HostName: "phone", DNSName: "phone.tail.ts.net.", OS: "android", UserID: 1, Online: true },
      c: { HostName: "theirs", DNSName: "theirs.tail.ts.net.", OS: "linux", UserID: 2, Online: true },
      d: { HostName: "asleep", DNSName: "asleep.tail.ts.net.", OS: "macOS", UserID: 1, Online: false },
    } };
    const state = path.join(f.root, "synced"); const log = path.join(f.root, "ssh.log");
    const env = { EC_RELEASE_MANIFEST: manifest, ...f.fake("tailscale", `console.log(${JSON.stringify(JSON.stringify(status))})`), ...f.fake("ssh", `const fs=require('node:fs'),a=process.argv.slice(2);fs.appendFileSync(${JSON.stringify(log)},a.join(' ')+"\\n");
if(a.at(-1).includes('sync --skip-packages')){if(${fetches})fs.writeFileSync(${JSON.stringify(state)},'1');console.error('synced');process.exit(0)}
const now=fs.existsSync(${JSON.stringify(state)});console.log(JSON.stringify({schema_version:1,command:'version',ok:true,message:'ec x',data:now?{version:'0.0.9',source_hash:${JSON.stringify(hash)}}:null,error:null}));`) };
    return { ...f, env: { ...f.env, ...env }, log, run: (args: string[]) => f.run(args, env) };
  }
  it("lists this account's computers with versions and offline machines", () => {
    const f = fleet(); const r = f.run(["fleet", "--json"]);
    expect(r.status, r.stderr).toBe(0); const result = JSON.parse(r.stdout);
    expect(result.data.release).toMatchObject({ version: "0.0.9" });
    expect(result.data.machines.map((m: { name: string; state: string }) => [m.name, m.state])).toEqual([["here", "current"], ["asleep", "offline"], ["box", "behind"]]);
    expect(result.message).toContain("built before source hashes");
    expect(readFileSync(f.log, "utf8")).toContain("box.tail.ts.net");
  });
  it("syncs only machines that are behind and reports their new versions", () => {
    const f = fleet(); const r = f.run(["fleet", "sync", "--json"]);
    expect(r.status, r.stderr).toBe(0); const result = JSON.parse(r.stdout);
    expect(result.data.machines.find((m: { name: string }) => m.name === "box")).toMatchObject({ state: "current", version: "0.0.9" });
    const calls = readFileSync(f.log, "utf8").trim().split("\n");
    expect(calls.filter(c => c.includes("sync --skip-packages"))).toHaveLength(1);
    expect(calls.every(c => !c.includes("asleep") && !c.includes("theirs"))).toBe(true);
    expect(r.stderr).toContain("== box ==");
  });
  it("fails when a machine is still behind after a sync that could not fetch", () => {
    const f = fleet(false); const r = f.run(["fleet", "sync", "--json"]);
    expect(r.status).toBe(1); expect(JSON.parse(r.stdout)).toMatchObject({ ok: false, error: { code: "sync_failed" } });
    expect(r.stderr).toContain("box is still behind after ec sync");
  });
});
