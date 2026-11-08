import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  lstatSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  symlinkSync,
  unlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { parse as toml } from "smol-toml";
import { describe, expect, it } from "vitest";

import {
  agentHomes,
  agentPlugins,
  builtHash,
  checkoutFixture,
  ec,
  executorKey,
  filePermissions,
  hostTarget,
  proxyKey,
  write,
} from "./fixture.ts";

const fixture = () => {
  const f = checkoutFixture(agentPlugins, agentHomes);
  f.secret("cliproxyapi", proxyKey);
  f.secret("executor", executorKey);
  return f;
};
// ec with no HOME, config, or commands on PATH.
const offline = (args: string[]) =>
  spawnSync(ec, args, {
    cwd: tmpdir(),
    encoding: "utf-8",
    env: { PATH: "/missing" },
  });

describe("native ec", () => {
  it("prints discoverable help without a runtime, HOME, repo, or config", () => {
    const r = spawnSync(ec, [], {
      cwd: tmpdir(),
      encoding: "utf-8",
      env: { PATH: "/nonexistent" },
    });
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).toContain("ec <command>");
    expect(r.stdout).toContain("--json");
    expect(r.stdout).toContain("plugin");
  });
  it("prints structured help and version without configuration", () => {
    expect(JSON.parse(offline(["--json", "--help"]).stdout)).toMatchObject({
      command: "help",
      ok: true,
      schema_version: 1,
    });
    expect(offline(["--version"]).stdout.trim()).toBe(
      `ec dev (${builtHash().slice(0, 7)})`
    );
    expect(
      JSON.parse(offline(["--json", "--version"]).stdout).data
    ).toMatchObject({
      source_hash: builtHash(),
      version: "dev",
    });
  });
  it.each([
    ["sync"],
    ["push"],
    ["verify"],
    ["status"],
    ["plugin", "list"],
    ["secret", "set"],
  ])("scopes offline help and machine discovery to %s %s", (...args) => {
    const human = offline([...args, "--help"]);
    expect(human.status, human.stderr).toBe(0);
    expect(human.stdout).toContain(`Usage: ec ${args.join(" ")}`);
    expect(human.stdout).toContain("Examples:");
    expect(human.stdout).toContain("Effects:");
    const machine = offline(["--json", ...args, "--help"]);
    expect(machine.status, machine.stderr).toBe(0);
    expect(machine.stderr).toBe("");
    const result = JSON.parse(machine.stdout);
    expect(result.error).toBeNull();
    expect(`${result.message}\n`).toBe(human.stdout);
    const definitions = result.data.command_definitions;
    expect(definitions).toHaveLength(1);
    expect(definitions[0]).toMatchObject({
      action: args[1] ?? "",
      command: args[0],
    });
    expect(offline(["help", ...args]).stdout).toBe(human.stdout);
  });
  it("discovers command effects, defaults, and profile choices without running commands", () => {
    const f = fixture();
    const result = JSON.parse(f.run(["--help", "--json"]).stdout);
    const definitions = result.data.command_definitions;
    const sync = definitions.find(
      (d: { command: string }) => d.command === "sync"
    );
    const profile = sync.options.find(
      (o: { name: string }) => o.name === "profile"
    );
    // Profiles are names that ender-chest.toml filters on, not a fixed list.
    expect(profile).toMatchObject({ type: "string", values: [] });
    expect(profile.default).toContain("mac");
    expect(profile).not.toHaveProperty("required");
    const push = definitions.find(
      (d: { command: string }) => d.command === "push"
    );
    expect(push.effects.length).toBeGreaterThan(0);
    expect(existsSync(path.join(f.home, ".gitconfig"))).toBe(false);
  });
  it.each([
    { args: ["sync", "--profile"], message: "--profile needs a profile name" },
    { args: ["sync", "--repo", ""], message: "--repo needs a checkout path." },
    { args: ["status", "sync"], message: "Unknown command or option." },
    { args: ["sync", "push"], message: "Unknown command or option." },
    { args: ["status", "--no-wait"], message: "Unknown option --no-wait." },
    { args: ["--nope"], message: "Unknown option --nope." },
    {
      args: ["sync", "--all", "--profile", "mac"],
      message: "takes no other options",
    },
    {
      args: ["verify", "--all"],
      message: "--all is only available with ec sync.",
    },
    {
      args: ["verify", "--dry-run"],
      message:
        "--dry-run is only available with ec push. It still captures files into the checkout.",
    },
    {
      args: ["update", "--repo", "/x"],
      message: "It updates the ec binary you ran.",
    },
    {
      args: ["secret", "list", "extra"],
      message: "Unknown command or option.",
    },
    { args: ["secret", "list", "--repo", "/x"], message: "--repo applies to" },
    { args: ["--skip-packages"], message: "only available with ec sync" },
  ])(
    "explains invalid arguments in human and JSON output without writes: $args",
    ({ args, message }) => {
      const f = fixture();
      const human = f.run(args);
      expect(human.status).toBe(2);
      expect(human.stdout).toBe("");
      expect(human.stderr).toContain(message);
      const machine = f.run([...args, "--json"]);
      expect(machine.status).toBe(2);
      expect(machine.stderr).toBe("");
      expect(JSON.parse(machine.stdout)).toMatchObject({
        command: "arguments",
        error: {
          code: "usage_error",
          message: expect.stringContaining(message),
        },
        ok: false,
        schema_version: 1,
      });
      expect(existsSync(path.join(f.home, ".gitconfig"))).toBe(false);
    }
  );
  it("applies a clean machine, installs a native binary, and verifies without Node", () => {
    const f = fixture();
    const r = f.run(["sync", "--skip-packages", "--profile", "mac", "--json"], {
      PATH: "/usr/bin:/bin",
    });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(JSON.parse(r.stdout)).toMatchObject({ command: "sync", ok: true });
    expect(filePermissions(path.join(f.home, ".ssh/config"))).toBe(0o600);
    expect(filePermissions(path.join(f.home, ".ssh"))).toBe(0o700);
    expect(readFileSync(path.join(f.home, ".local/bin/ec"))).toEqual(
      readFileSync(ec)
    );
    expect(existsSync(path.join(f.home, ".local/bin/ender"))).toBe(false);
    for (const agent of [".claude", ".codex", ".grok"]) {
      expect(readlinkSync(path.join(f.home, agent, "skills/note"))).toBe(
        path.join(f.home, ".agents/skills/note")
      );
    }
    const installed = spawnSync(
      path.join(f.home, ".local/bin/ec"),
      ["verify", "--profile", "mac", "--json"],
      {
        cwd: tmpdir(),
        encoding: "utf-8",
        env: { HOME: f.home, PATH: "/usr/bin:/bin" },
      }
    );
    expect(installed.status, installed.stderr).toBe(0);
    expect(JSON.parse(installed.stdout).ok).toBe(true);
  });
  it("syncs the primary checkout from a linked worktree without a failed pull", () => {
    const f = fixture();

    f.git("add", ".");
    f.git("commit", "-m", "init");
    f.git("branch", "-M", "main");
    const remote = path.join(f.root, "remote.git");
    expect(
      spawnSync("git", ["init", "--bare", remote], { encoding: "utf-8" }).status
    ).toBe(0);
    f.git("remote", "add", "origin", remote);
    f.git("push", "-u", "origin", "main");
    f.git("branch", "feature");
    const worktree = path.join(f.root, "worktree");
    f.git("worktree", "add", worktree, "feature");
    const env: NodeJS.ProcessEnv = { ...f.env };
    delete env.EC_REPO;
    const r = spawnSync(ec, ["sync", "--skip-packages", "--json"], {
      cwd: worktree,
      encoding: "utf-8",
      env,
      timeout: 15_000,
    });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(JSON.parse(r.stdout)).toMatchObject({ command: "sync", ok: true });
    expect(r.stderr).not.toContain("git pull failed");
    expect(
      realpathSync(
        readFileSync(
          path.join(f.home, ".config/ender-chest/repo"),
          "utf-8"
        ).trim()
      )
    ).toBe(realpathSync(f.repo));
  });
  it("does not treat a missing upstream as a failed pull", () => {
    const f = fixture();
    const { git } = f;
    git("add", ".");
    git("commit", "-m", "init");
    git("branch", "-M", "feature");
    const remote = path.join(f.root, "remote.git");
    expect(
      spawnSync("git", ["init", "--bare", remote], { encoding: "utf-8" }).status
    ).toBe(0);
    git("remote", "add", "origin", remote);
    git("push", "origin", "feature");
    const r = f.run(["sync", "--skip-packages", "--json"]);
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(JSON.parse(r.stdout).ok).toBe(true);
    expect(r.stderr).not.toContain("git pull failed");
  });
  it("reads --repo=PATH like --repo PATH", () => {
    const f = fixture();
    const r = f.run(["sync", `--repo=${f.repo}`, "--skip-packages", "--json"], {
      EC_REPO: path.join(f.root, "missing"),
    });
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(existsSync(path.join(f.home, ".gitconfig"))).toBe(true);
  });
  it("sync is idempotent and preserves local settings, trust, hooks, and credentials", () => {
    const f = fixture();
    write(f.home, ".gitconfig.local", "# machine-local\n");
    write(f.home, ".ssh/id_ed25519", "PRIVATE KEY");
    write(f.home, ".claude/.credentials.json", '{"token":"PRIVATE"}');
    write(
      f.home,
      ".claude/settings.json",
      JSON.stringify({
        env: { LOCAL: "keep" },
        hooks: { Start: [] },
        model: "old",
      })
    );
    write(
      f.home,
      ".claude.json",
      JSON.stringify({
        mcpServers: { local: { command: "local" } },
        oauth: "keep",
      })
    );
    write(
      f.home,
      ".codex/config.toml",
      'model="personal"\n[projects."/work/a.b"]\ntrust_level="trusted"\n[model_providers.cliproxyapi]\nenv_key="OLD"\n'
    );
    f.sync("--skip-packages");
    const settings = JSON.parse(
      readFileSync(path.join(f.home, ".claude/settings.json"), "utf-8")
    );
    expect(settings).toMatchObject({
      env: { ANTHROPIC_AUTH_TOKEN: proxyKey, LOCAL: "keep" },
      hooks: { Start: [] },
    });
    expect(
      JSON.parse(readFileSync(path.join(f.home, ".claude.json"), "utf-8"))
    ).toMatchObject({
      mcpServers: {
        executor: { url: "https://mcp.example.test:4312/mcp" },
        local: { command: "local" },
      },
      oauth: "keep",
    });
    const before = readFileSync(
      path.join(f.home, ".codex/config.toml"),
      "utf-8"
    );
    expect(toml(before)).toMatchObject({
      model: "personal",
      projects: { "/work/a.b": { trust_level: "trusted" } },
    });
    expect(before).not.toContain("OLD");
    f.sync("--skip-packages");
    expect(readFileSync(path.join(f.home, ".codex/config.toml"), "utf-8")).toBe(
      before
    );
    expect(readFileSync(path.join(f.home, ".gitconfig.local"), "utf-8")).toBe(
      "# machine-local\n"
    );
    expect(readFileSync(path.join(f.home, ".ssh/id_ed25519"), "utf-8")).toBe(
      "PRIVATE KEY"
    );
    expect(
      readFileSync(path.join(f.home, ".claude/.credentials.json"), "utf-8")
    ).toContain("PRIVATE");
  });
  it("writes agent TOML that Codex can extend when it trusts a new project", () => {
    const f = fixture();
    write(
      f.home,
      ".codex/config.toml",
      '"projects" = { "/work/a" = { "trust_level" = "trusted" } }\n'
    );
    f.sync("--skip-packages");
    const file = path.join(f.home, ".codex/config.toml");
    const extended = `${readFileSync(file, "utf-8")}\n[projects."/work/b"]\ntrust_level = "trusted"\n`;
    expect(toml(extended)).toMatchObject({
      projects: {
        "/work/a": { trust_level: "trusted" },
        "/work/b": { trust_level: "trusted" },
      },
    });
  });
  it("writes bare table names so Orca finds projects that are already trusted", () => {
    const f = fixture();
    write(
      f.home,
      ".codex/config.toml",
      '[projects."/work/a"]\ntrust_level = "trusted"\n[hooks.state."/work/a:stop:0:0"]\nenabled = true\n'
    );
    f.sync("--skip-packages");
    const text = readFileSync(path.join(f.home, ".codex/config.toml"), "utf-8");
    // Orca matches /^\[[ \t]*projects[ \t]*\./ before deciding to append a new [projects."..."] table.
    expect(text).toContain('\n[projects."/work/a"]\ntrust_level = "trusted"\n');
    expect(text).toContain(
      '\n[hooks.state."/work/a:stop:0:0"]\nenabled = true\n'
    );
    expect(text).toContain("\n[model_providers.cliproxyapi]\n");
  });
  it("leaves malformed local TOML intact and reports its path without secret contents", () => {
    const f = fixture();
    const file = write(f.home, ".codex/config.toml", "bad = [ PRIVATE_SECRET");
    const r = f.run(["sync", "--skip-packages", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain(file);
    expect(r.stdout + r.stderr).not.toContain("PRIVATE_SECRET");
    expect(readFileSync(file, "utf-8")).toBe("bad = [ PRIVATE_SECRET");
  });
  it("keeps a development build instead of installing a release", () => {
    const f = fixture();
    const asset = write(
      f.root,
      "ec-release",
      "#!/bin/sh\nprintf '%s\\n' replaced > \"$HOME/release-marker\"\n"
    );
    chmodSync(asset, 0o755);
    const manifest = write(
      f.root,
      "manifest.json",
      JSON.stringify({
        assets: {
          [hostTarget()]: {
            name: "ec-test",
            path: asset,
            sha256: createHash("sha256")
              .update(readFileSync(asset))
              .digest("hex"),
          },
        },
        source_hash: "a".repeat(64),
        version: "0.0.2",
      })
    );
    const r = f.run(["sync", "--skip-packages"], {
      EC_NO_UPDATE: "",
      EC_RELEASE_MANIFEST: manifest,
    });
    expect(r.status, r.stderr).toBe(0);
    expect(existsSync(path.join(f.home, "release-marker"))).toBe(false);
    expect(readFileSync(path.join(f.home, ".local/bin/ec"))).toEqual(
      readFileSync(ec)
    );
  });
  it("verify detects missing files and incorrect skill links without fixing them", () => {
    const f = fixture();
    f.sync("--skip-packages");
    unlinkSync(path.join(f.home, ".gitconfig"));
    const link = path.join(f.home, ".codex/skills/note");
    unlinkSync(link);
    symlinkSync(f.repo, link);
    const r = f.run(["verify", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout)).toMatchObject({
      error: { code: "verification_failed" },
      ok: false,
    });
    expect(r.stderr).toContain(".gitconfig");
    expect(r.stderr).toContain("must link");
    expect(existsSync(path.join(f.home, ".gitconfig"))).toBe(false);
  });
  it("push dry-run captures only portable files and personal skills without committing", () => {
    const f = fixture();
    f.sync("--skip-packages");
    write(f.home, ".gitconfig", "# captured\n");
    write(f.home, ".gitconfig.local", "SECRET");
    write(f.home, ".ssh/id_ed25519", "PRIVATE KEY");
    write(f.home, ".agents/skills/personal/SKILL.md", "# personal\n");
    write(f.home, ".claude/.credentials.json", "SECRET");
    const r = f.run(["push", "--dry-run", "--json"]);
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(JSON.parse(r.stdout).message).toContain("Dry-run");
    expect(readFileSync(path.join(f.repo, "home/.gitconfig"), "utf-8")).toBe(
      "# captured\n"
    );
    expect(existsSync(path.join(f.repo, "skills/personal/SKILL.md"))).toBe(
      true
    );
    for (const rel of [
      "home/.gitconfig.local",
      "home/.ssh/id_ed25519",
      "home/.claude/.credentials.json",
      "home/.local/bin/ec",
    ]) {
      expect(existsSync(path.join(f.repo, rel))).toBe(false);
    }
    expect(spawnSync("git", ["log", "-1"], { cwd: f.repo }).status).not.toBe(0);
  });
  it("push refuses to commit unrelated staged files", () => {
    const f = fixture();
    f.sync("--skip-packages");
    write(f.repo, "unrelated.txt", "keep staged");
    expect(
      spawnSync("git", ["add", "unrelated.txt"], { cwd: f.repo }).status
    ).toBe(0);
    const r = f.run(["push", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain("Unrelated staged file");
    expect(
      spawnSync("git", ["diff", "--cached", "--name-only"], {
        cwd: f.repo,
        encoding: "utf-8",
      }).stdout.trim()
    ).toBe("unrelated.txt");
  });
  it("harvests installed skill sources and honors explicit removals", () => {
    const f = fixture();
    f.sync("--skip-packages");
    write(f.home, ".agents/skills/third/SKILL.md", "# Third");
    write(f.home, ".agents/skills/removed/SKILL.md", "# removed");
    write(
      f.home,
      ".agents/.skill-lock.json",
      JSON.stringify({
        skills: {
          removed: { source: "owner/no" },
          third: { source: "owner/repo" },
        },
      })
    );
    write(
      f.repo,
      "skills/manifest.json",
      JSON.stringify({ remove: [{ name: "removed" }], skills: [], version: 1 })
    );
    expect(f.run(["push", "--dry-run"]).status).toBe(0);
    expect(
      JSON.parse(
        readFileSync(path.join(f.repo, "skills/manifest.json"), "utf-8")
      ).skills
    ).toEqual([{ name: "third", skill: "third", source: "owner/repo" }]);
    expect(existsSync(path.join(f.repo, "skills/third"))).toBe(false);
    expect(existsSync(path.join(f.repo, "skills/removed"))).toBe(false);
  });
  it("push refuses a damaged skill lock file instead of copying installed skills", () => {
    const f = fixture();
    f.sync("--skip-packages");
    write(f.home, ".agents/skills/third/SKILL.md", "# Third");
    write(f.home, ".agents/.skill-lock.json", "{ not json");
    const r = f.run(["push", "--dry-run", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain(".skill-lock.json");
    expect(existsSync(path.join(f.repo, "skills/third"))).toBe(false);
  });
  it("migrates Claude-local skills and removes obsolete files when a personal skill changes", () => {
    const f = fixture();
    write(
      f.repo,
      "skills/manifest.json",
      JSON.stringify({
        remove: [{ name: "removed" }],
        skills: [{ name: "third", skill: "third", source: "owner/repo" }],
        version: 1,
      })
    );
    write(f.home, ".claude/skills/third/SKILL.md", "# Third");
    write(f.home, ".agents/skills/note/stale.md", "stale");
    write(f.home, ".agents/skills/removed/SKILL.md", "# removed");
    f.sync("--skip-packages");
    expect(
      lstatSync(path.join(f.home, ".claude/skills/third")).isSymbolicLink()
    ).toBe(true);
    expect(
      readFileSync(path.join(f.home, ".agents/skills/third/SKILL.md"), "utf-8")
    ).toBe("# Third");
    expect(existsSync(path.join(f.home, ".agents/skills/note/stale.md"))).toBe(
      false
    );
    expect(existsSync(path.join(f.home, ".agents/skills/removed"))).toBe(false);
  });
  it("installs third-party skills through git, groups sources, and excludes profiles", () => {
    const f = fixture();
    const log = path.join(f.root, "git.log");
    const env = f.fake(
      "git",
      `const fs=require('node:fs'),p=require('node:path'),a=process.argv.slice(2); fs.appendFileSync(${JSON.stringify(log)},JSON.stringify(a)+'\\n'); if(a[0]==='clone'){for(const name of ['one','two']) {const dest=p.join(a.at(-1),'skills',name);fs.mkdirSync(dest,{recursive:true});fs.writeFileSync(p.join(dest,'SKILL.md'),'---\\nname: '+name+'\\n---\\n# Skill');}}`
    );
    write(
      f.repo,
      "skills/manifest.json",
      JSON.stringify({
        skills: [
          { name: "one", skill: "one", source: "owner/repo#main" },
          { name: "two", skill: "two", source: "owner/repo#main" },
          {
            name: "mac-only",
            profiles: ["mac"],
            skill: "mac-only",
            source: "owner/mac",
          },
        ],
        version: 1,
      })
    );
    const r = f.run(["sync", "--skip-packages", "--profile", "cloud"], env);
    expect(r.status, r.stdout + r.stderr).toBe(0);
    const calls = readFileSync(log, "utf-8")
      .trim()
      .split("\n")
      .map((s) => JSON.parse(s));
    expect(calls.filter((a) => a[0] === "clone")).toHaveLength(1);
    expect(calls.flat()).toContain("https://github.com/owner/repo.git");
    expect(existsSync(path.join(f.home, ".agents/skills/two/SKILL.md"))).toBe(
      true
    );
    expect(existsSync(path.join(f.home, ".agents/skills/mac-only"))).toBe(
      false
    );
  });
  it("prefers the shallowest copy of a skill in a directory named after it", () => {
    const f = fixture();
    // The source ships skills/tool and a package copy at packages/cli, both named "tool".
    const clone = (dirs: string[]) =>
      f.fake(
        "git",
        `const fs=require('node:fs'),p=require('node:path'),a=process.argv.slice(2); if(a[0]==='clone'){for(const d of ${JSON.stringify(dirs)}){const dest=p.join(a.at(-1),d);fs.mkdirSync(dest,{recursive:true});fs.writeFileSync(p.join(dest,'SKILL.md'),'---\\nname: tool\\n---\\n# '+d);}}`
      );
    write(
      f.repo,
      "skills/manifest.json",
      JSON.stringify({
        skills: [{ name: "tool", skill: "tool", source: "owner/repo" }],
        version: 1,
      })
    );
    const r = f.run(
      ["sync", "--skip-packages"],
      clone(["packages/cli", "skills/tool"])
    );
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(
      readFileSync(path.join(f.home, ".agents/skills/tool/SKILL.md"), "utf-8")
    ).toContain("# skills/tool");

    // A harness copy deeper in the tree loses to the shallower one.
    const h = fixture();
    write(
      h.repo,
      "skills/manifest.json",
      JSON.stringify({
        skills: [{ name: "tool", skill: "tool", source: "owner/repo" }],
        version: 1,
      })
    );
    const nested = h.run(
      ["sync", "--skip-packages"],
      clone(["harness/claude-code/skills/tool", "pack/skills/tool"])
    );
    expect(nested.status, nested.stdout + nested.stderr).toBe(0);
    expect(
      readFileSync(path.join(h.home, ".agents/skills/tool/SKILL.md"), "utf-8")
    ).toContain("# pack/skills/tool");

    const g = fixture();
    write(
      g.repo,
      "skills/manifest.json",
      JSON.stringify({
        skills: [{ name: "tool", skill: "tool", source: "owner/repo" }],
        version: 1,
      })
    );
    const ambiguous = g.run(
      ["sync", "--skip-packages"],
      clone(["a/tool", "b/tool"])
    );
    expect(ambiguous.status).toBe(1);
    expect(ambiguous.stderr).toContain("Multiple skills named tool");
  });
  it("rejects traversal in skill removals before deleting anything", () => {
    const f = fixture();
    const keep = write(f.home, "keep", "safe");
    write(
      f.repo,
      "skills/manifest.json",
      JSON.stringify({
        remove: [{ name: "../../keep" }],
        skills: [],
        version: 1,
      })
    );
    const r = f.run(["sync", "--skip-packages", "--json"]);
    expect(r.status).toBe(1);
    expect(readFileSync(keep, "utf-8")).toBe("safe");
  });
});

describe("native status and sync --all", () => {
  const fleet = (fetches = true) => {
    const f = fixture();
    const hash = builtHash();
    const manifest = write(
      f.root,
      "manifest.json",
      JSON.stringify({
        assets: {},
        schema_version: 1,
        source_hash: hash,
        version: "0.0.9",
      })
    );
    const status = {
      Peer: {
        a: {
          DNSName: "box.tail.ts.net.",
          HostName: "box",
          OS: "linux",
          Online: true,
          UserID: 1,
        },
        b: {
          DNSName: "phone.tail.ts.net.",
          HostName: "phone",
          OS: "android",
          Online: true,
          UserID: 1,
        },
        c: {
          DNSName: "theirs.tail.ts.net.",
          HostName: "theirs",
          OS: "linux",
          Online: true,
          UserID: 2,
        },
        d: {
          DNSName: "asleep.tail.ts.net.",
          HostName: "asleep",
          OS: "macOS",
          Online: false,
          UserID: 1,
        },
      },
      Self: {
        DNSName: "here.tail.ts.net.",
        HostName: "Example\u2019s Mac",
        OS: "macOS",
        Online: true,
        UserID: 1,
      },
    };
    const state = path.join(f.root, "synced");
    const log = path.join(f.root, "ssh.log");
    const env = {
      EC_NO_UPDATE: "",
      EC_RELEASE_MANIFEST: manifest,
      ...f.fake(
        "tailscale",
        `console.log(${JSON.stringify(JSON.stringify(status))})`
      ),
      ...f.fake(
        "ssh",
        `const fs=require('node:fs'),a=process.argv.slice(2);fs.appendFileSync(${JSON.stringify(log)},a.join(' ')+"\\n");
if(a.at(-1).includes('sync --skip-packages')){if(${fetches})fs.writeFileSync(${JSON.stringify(state)},'1');console.error('synced');process.exit(0)}
const now=fs.existsSync(${JSON.stringify(state)});console.log(JSON.stringify({schema_version:1,command:'version',ok:true,message:'ec x',data:now?{version:'0.0.9',source_hash:${JSON.stringify(hash)}}:null,error:null}));`
      ),
    };
    return {
      ...f,
      env: { ...f.env, ...env },
      log,
      run: (args: string[], extra: NodeJS.ProcessEnv = {}) =>
        f.run(args, { ...env, ...extra }),
    };
  };
  it("lists this account's computers with versions and offline machines", () => {
    const f = fleet();
    const r = f.run(["status", "--json"]);
    expect(r.status, r.stderr).toBe(0);
    const result = JSON.parse(r.stdout);
    expect(result.data.release).toMatchObject({ version: "0.0.9" });
    expect(
      result.data.machines.map((m: { name: string; state: string }) => [
        m.name,
        m.state,
      ])
    ).toEqual([
      ["here", "current"],
      ["asleep", "offline"],
      ["box", "behind"],
    ]);
    expect(result.message).toContain("built before source hashes");
    expect(readFileSync(f.log, "utf-8")).toContain("box.tail.ts.net");
  });
  it("tells how to install ec on a machine that answers SSH without it", () => {
    const f = fleet();
    f.fake("ssh", "");
    const box = JSON.parse(
      f.run(["status", "--json"]).stdout
    ).data.machines.find((m: { name: string }) => m.name === "box");
    expect(box).toMatchObject({ state: "missing" });
    expect(box.detail).toContain("Run the ec installer there, then ec sync.");
  });
  it("skips the release lookup with EC_NO_UPDATE=1", () => {
    const f = fleet();
    const r = f.run(["status", "--json"], { EC_NO_UPDATE: "1" });
    expect(r.status, r.stderr).toBe(0);
    expect(JSON.parse(r.stdout).data.release.version ?? null).toBeNull();
    expect(r.stderr).toContain("Could not read the latest ec release");
  });
  it("syncs only machines that are behind and reports their new versions", () => {
    const f = fleet();
    const r = f.run(["sync", "--all", "--json"]);
    expect(r.status, r.stderr).toBe(0);
    const result = JSON.parse(r.stdout);
    expect(
      result.data.machines.find((m: { name: string }) => m.name === "box")
    ).toMatchObject({ state: "current", version: "0.0.9" });
    const calls = readFileSync(f.log, "utf-8").trim().split("\n");
    expect(
      calls.filter((c) => c.includes("sync --skip-packages"))
    ).toHaveLength(1);
    expect(
      calls.every((c) => !c.includes("asleep") && !c.includes("theirs"))
    ).toBe(true);
    expect(r.stderr).toContain("== box ==");
  });
  it("fails when a machine is still behind after a sync that could not fetch", () => {
    const f = fleet(false);
    const r = f.run(["sync", "--all", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout)).toMatchObject({
      error: { code: "sync_failed" },
      ok: false,
    });
    expect(r.stderr).toContain("box is still behind after ec sync");
  });
});
