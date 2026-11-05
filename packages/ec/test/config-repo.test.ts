import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";

import { parse as toml } from "smol-toml";
import { afterEach, describe, expect, it } from "vitest";

import {
  filePermissions,
  gitInit,
  pluginFixture,
  write,
  writeSourceRepo,
} from "./fixture.ts";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

// A config checkout with the fixture's home files, plus `extra` in ender-chest.toml.
const checkout = (extra = "") => {
  const f = pluginFixture("");
  roots.push(f.root);
  writeSourceRepo(f.repo, extra);
  gitInit(f.repo);
  const sync = (...args: string[]) => {
    const r = f.run(["sync", "--profile", "mac", ...args]);
    expect(r.status, r.stdout + r.stderr).toBe(0);
    return r;
  };
  const git = (...args: string[]) => {
    const r = spawnSync("git", args, { cwd: f.repo, encoding: "utf-8" });
    expect(r.status, r.stderr).toBe(0);
    return r.stdout;
  };
  const read = (rel: string) => readFileSync(path.join(f.home, rel), "utf-8");
  return { ...f, git, read, sync };
};
const proxyKey = "fixture-proxy-token";
const executorKey = "fixture-executor-key-xxxxxxxxxxxxxxxx";
const agentPlugins = `
[plugins.cliproxyapi]
url = "https://proxy.example.test:8317"
key = { secret = "cliproxyapi" }

[plugins.executor]
url = "https://mcp.example.test:4312"
key = { secret = "executor" }
`;

describe("home files", () => {
  it("creates once files a single time, never overwrites them, and never pushes them", () => {
    const f = checkout();
    f.sync("--skip-packages");
    expect(f.read(".gitconfig.local")).toBe(
      readFileSync(path.join(f.repo, "git/gitconfig.local.example"), "utf-8")
    );
    expect(f.read(".zprofile.local")).toBe("");
    expect(filePermissions(path.join(f.home, ".ssh/config.local"))).toBe(0o600);
    write(f.home, ".gitconfig.local", "[user]\n\tname = Local\n");
    write(f.repo, "git/gitconfig.local.example", "# changed example\n");
    f.sync("--skip-packages");
    expect(f.read(".gitconfig.local")).toBe("[user]\n\tname = Local\n");
    const r = f.run(["push", "--dry-run", "--profile", "mac"]);
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(existsSync(path.join(f.repo, "home/.gitconfig.local"))).toBe(false);
    expect(
      readFileSync(path.join(f.repo, "git/gitconfig.local.example"), "utf-8")
    ).toBe("# changed example\n");
  });

  it("keeps one backup of a file that differed before sync replaced it", () => {
    const f = checkout();
    write(f.home, ".zshrc", "# mine\n");
    write(f.home, ".zprofile", 'export PATH="$HOME/.local/bin:$PATH"\n');
    const r = f.sync("--skip-packages");
    const saved = path.join(f.home, ".config/ender-chest/backup/.zshrc");
    expect(r.stderr).toContain("Saved your previous ~/.zshrc");
    expect(readFileSync(saved, "utf-8")).toBe("# mine\n");
    expect(filePermissions(saved)).toBe(0o600);
    expect(f.read(".zshrc")).toBe(
      readFileSync(path.join(f.repo, "home/.zshrc"), "utf-8")
    );
    // An identical file needs no backup, and a later change keeps the first one.
    expect(
      existsSync(path.join(f.home, ".config/ender-chest/backup/.zprofile"))
    ).toBe(false);
    write(f.home, ".zshrc", "# changed again\n");
    f.sync("--skip-packages");
    expect(readFileSync(saved, "utf-8")).toBe("# mine\n");
  });
});

describe("setup steps", () => {
  const steps = `
[[setup]]
name = "Record"
run = "cat setup-marker >> \\"$HOME/setup.log\\""
creates = "~/.setup-done"

[[setup]]
name = "Cloud only"
run = "touch \\"$HOME/cloud-ran\\""
profiles = ["cloud"]
`;

  it("run from the checkout, skip when creates exists, and skip with --skip-packages", () => {
    const f = checkout(steps);
    write(f.repo, "setup-marker", "from the checkout\n");
    f.sync("--skip-packages");
    expect(existsSync(path.join(f.home, "setup.log"))).toBe(false);
    const r = f.sync();
    expect(r.stderr).toContain("Setup: Record");
    expect(f.read("setup.log")).toBe("from the checkout\n");
    expect(existsSync(path.join(f.home, "cloud-ran"))).toBe(false);
    write(f.home, ".setup-done", "");
    f.sync();
    expect(f.read("setup.log")).toBe("from the checkout\n");
  });

  it("fail sync with the step's name", () => {
    const f = checkout('\n[[setup]]\nname = "Broken"\nrun = "exit 3"\n');
    const r = f.run(["sync", "--profile", "mac", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain(
      'Setup step "Broken" failed'
    );
  });
});

describe("plugins from the config repo", () => {
  // The script records what ec passed it, then exits with HELLO_EXIT.
  const hello = () => {
    const f = checkout(
      '\n[plugins.hello]\nsource = "plugins/hello"\ntoken = { secret = "hello" }\n\n[plugins.quiet]\n'
    );
    write(
      f.repo,
      "plugins/hello/plugin.toml",
      `name = "hello"
description = "Say hello."
run = "bin/hello"

[settings.greeting]
default = "Hello"

[settings.token]
type = "secret"

[[commands]]
name = "say"
description = "Print the greeting."
usage = "ec hello say [--loud] [--lang LANG]"
options = [{ name = "loud" }, { name = "lang", type = "string", values = ["en", "fr"] }]
`
    );
    const script = write(
      f.repo,
      "plugins/hello/bin/hello",
      `#!/bin/sh
printf '%s\\n' "$@" > "$HOME/hello-args"
printf '%s' "$EC_PLUGIN_SETTINGS" > "$HOME/hello-settings"
printf '%s' "\${EC_JSON-}" > "$HOME/hello-json"
exit "\${HELLO_EXIT:-0}"
`
    );
    chmodSync(script, 0o755);
    return f;
  };

  it("receive validated arguments, settings, and EC_JSON, and pass their exit code through", () => {
    const f = hello();
    f.secret("hello", "fixture-hello-token");
    const r = f.run(["hello", "say", "--loud", "--lang", "fr", "--json"]);
    expect(r.status, r.stdout + r.stderr).toBe(0);
    expect(f.read("hello-args")).toBe("say\n--loud\n--lang\nfr\n");
    expect(JSON.parse(f.read("hello-settings"))).toEqual({
      greeting: "Hello",
      token: "fixture-hello-token",
    });
    expect(f.read("hello-json")).toBe("1");
    expect(f.run(["hello", "say"], { HELLO_EXIT: "3" }).status).toBe(3);
    expect(f.read("hello-json")).toBe("");
  });

  it("pass an unset optional secret as an absent key", () => {
    const f = hello();
    expect(f.run(["hello", "say"]).status).toBe(0);
    expect(JSON.parse(f.read("hello-settings"))).toEqual({ greeting: "Hello" });
  });

  it.each([
    ["say", "--nope"],
    ["say", "--lang", "de"],
    ["say", "--lang"],
    ["say", "extra"],
    ["shout"],
  ])(
    "reject invalid arguments %j with exit code 2 before running",
    (...args) => {
      const f = hello();
      const r = f.run(["hello", ...args, "--json"]);
      expect(r.status).toBe(2);
      expect(JSON.parse(r.stdout).error.code).toBe("usage_error");
      expect(existsSync(path.join(f.home, "hello-args"))).toBe(false);
    }
  );

  it("show help from the manifest without running", () => {
    const f = hello();
    const r = f.run(["hello", "say", "--help"]);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).toContain("ec hello say [--loud] [--lang LANG]");
    expect(existsSync(path.join(f.home, "hello-args"))).toBe(false);
  });

  it("are listed with built-ins by ec plugin list", () => {
    const f = hello();
    const r = f.run(["plugin", "list", "--json"]);
    expect(r.status, r.stderr).toBe(0);
    expect(JSON.parse(r.stdout).data.plugins).toEqual([
      {
        commands: ["say"],
        commit: null,
        missing: ["token"],
        name: "hello",
        source: "plugins/hello",
      },
      {
        commands: ["stop"],
        commit: null,
        missing: [],
        name: "quiet",
        source: "built-in",
      },
    ]);
  });
});

describe("secrets", () => {
  it("are read from stdin, stored 0600, listed by name, and removed", () => {
    const f = checkout();
    const value = "fixture-secret-value";
    const file = path.join(f.home, ".config/ender-chest/secrets/demo");
    // spawnSync gives an empty stdin, which is not a secret.
    expect(f.run(["secret", "set", "demo", "--json"]).status).toBe(1);
    expect(existsSync(file)).toBe(false);
    f.secret("demo", value);
    expect(readFileSync(file, "utf-8")).toBe(`${value}\n`);
    expect(filePermissions(file)).toBe(0o600);
    expect(filePermissions(path.dirname(file))).toBe(0o700);
    const list = f.run(["secret", "list", "--json"]);
    expect(JSON.parse(list.stdout).data.names).toEqual(["demo"]);
    expect(list.stdout + list.stderr).not.toContain(value);
    expect(f.run(["secret", "remove", "demo"]).stdout).toContain(
      "Removed demo."
    );
    expect(existsSync(file)).toBe(false);
    expect(f.run(["secret", "remove", "demo"]).stdout).toContain(
      "No secret named demo."
    );
  });

  it("are refused by push when the checkout contains one", () => {
    const f = checkout();
    write(f.repo, "home/.config/ender-chest/secrets/demo", "fixture-leak\n");
    const r = f.run(["push", "--dry-run", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain(
      "Refusing credential or runtime path"
    );
    expect(r.stdout + r.stderr).not.toContain("fixture-leak");
  });
});

describe("agent settings from plugins", () => {
  it("adds the MCP server and provider to every agent, then removes only those", () => {
    const f = checkout(agentPlugins);
    f.secret("cliproxyapi", proxyKey);
    f.secret("executor", executorKey);
    write(
      f.home,
      ".claude.json",
      JSON.stringify({ mcpServers: { local: { command: "tool" } } })
    );
    write(
      f.home,
      ".codex/config.toml",
      '[mcp_servers.local]\ncommand = "tool"\n[model_providers.mine]\nbase_url = "http://mine.example.test"\n'
    );
    write(
      f.home,
      ".grok/config.toml",
      '[mcp_servers.local]\ncommand = "tool"\n[model.custom]\nmodel = "mine"\n'
    );
    f.sync("--skip-packages");
    const authorization = `Bearer ${executorKey}`;
    const mcp = "https://mcp.example.test:4312/mcp";
    const proxy = "https://proxy.example.test:8317";
    const claudeServers = () => JSON.parse(f.read(".claude.json")).mcpServers;
    const claudeEnv = () => JSON.parse(f.read(".claude/settings.json")).env;
    const codex = () => toml(f.read(".codex/config.toml"));
    const grok = () => toml(f.read(".grok/config.toml"));
    expect(claudeServers()).toEqual({
      executor: {
        headers: { Authorization: authorization },
        type: "http",
        url: mcp,
      },
      local: { command: "tool" },
    });
    expect(claudeEnv()).toMatchObject({
      ANTHROPIC_AUTH_TOKEN: proxyKey,
      ANTHROPIC_BASE_URL: proxy,
    });
    expect(codex()).toMatchObject({
      mcp_servers: {
        executor: { http_headers: { Authorization: authorization }, url: mcp },
        local: { command: "tool" },
      },
      model_provider: "cliproxyapi",
      model_providers: {
        cliproxyapi: {
          base_url: `${proxy}/v1`,
          experimental_bearer_token: proxyKey,
        },
        mine: { base_url: "http://mine.example.test" },
      },
    });
    expect(grok()).toMatchObject({
      mcp_servers: {
        executor: { headers: { Authorization: authorization }, url: mcp },
        local: { command: "tool" },
      },
      model: {
        custom: { model: "mine" },
        "grok-4.7": { api_key: proxyKey, base_url: `${proxy}/v1` },
      },
    });
    expect(JSON.parse(f.read(".config/ender-chest/state.json"))).toMatchObject({
      mcp_servers: ["executor"],
      provider: "cliproxyapi",
    });

    writeSourceRepo(f.repo);
    f.sync("--skip-packages");
    expect(claudeServers()).toEqual({ local: { command: "tool" } });
    expect(claudeEnv()).not.toHaveProperty("ANTHROPIC_AUTH_TOKEN");
    expect(claudeEnv()).not.toHaveProperty("ANTHROPIC_BASE_URL");
    expect(codex()).toEqual({
      mcp_servers: { local: { command: "tool" } },
      model_providers: { mine: { base_url: "http://mine.example.test" } },
    });
    expect(grok()).toEqual({
      mcp_servers: { local: { command: "tool" } },
      model: { custom: { model: "mine" } },
      models: {},
    });
    for (const text of [
      f.read(".claude.json"),
      f.read(".claude/settings.json"),
      f.read(".codex/config.toml"),
      f.read(".grok/config.toml"),
    ]) {
      expect(text).not.toContain(proxyKey);
      expect(text).not.toContain(executorKey);
    }
    expect(JSON.parse(f.read(".config/ender-chest/state.json"))).toEqual({
      mcp_servers: [],
    });
  });

  it("keeps secrets and generated agent credentials out of dry-run and real pushes", () => {
    const f = checkout(agentPlugins);
    const remote = path.join(f.root, "remote.git");
    expect(spawnSync("git", ["init", "--bare", remote]).status).toBe(0);
    f.git("add", ".");
    f.git("commit", "-m", "Initial fixture");
    f.git("remote", "add", "origin", remote);
    f.git("push", "-u", "origin", "HEAD");
    f.secret("cliproxyapi", proxyKey);
    f.secret("executor", executorKey);
    f.sync("--skip-packages");
    write(f.home, ".gitconfig", "# captured\n");
    for (const args of [["push", "--dry-run"], ["push"]]) {
      const r = f.run([...args, "--profile", "mac"]);
      expect(r.status, r.stdout + r.stderr).toBe(0);
      expect(r.stdout + r.stderr).not.toContain(proxyKey);
      for (const rel of [
        "home/.config/ender-chest",
        "home/.claude",
        "home/.claude.json",
        "home/.codex",
        "home/.grok",
      ]) {
        expect(existsSync(path.join(f.repo, rel))).toBe(false);
      }
    }
    expect(f.git("show", "HEAD:home/.gitconfig")).toBe("# captured\n");
    const history = f.git("log", "-p", "--all");
    expect(history).not.toContain(proxyKey);
    expect(history).not.toContain(executorKey);
  });

  it("refuses a manually staged secret before committing", () => {
    const f = checkout();
    write(
      f.repo,
      "home/.config/ender-chest/secrets/cliproxyapi",
      "fixture-staged-token\n"
    );
    f.git("add", ".");
    const r = f.run(["push", "--json"]);
    expect(r.status).toBe(1);
    expect(r.stdout).toContain("Refusing credential or runtime path");
    expect(r.stdout + r.stderr).not.toContain("fixture-staged-token");
    expect(f.git("log", "--oneline", "--all")).toBe("");
  });
});
