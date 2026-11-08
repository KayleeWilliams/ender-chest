import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  statSync,
} from "node:fs";
import path from "node:path";

import { parse as toml } from "smol-toml";
import { describe, expect, it } from "vitest";

import {
  agentHomes,
  agentPlugins,
  checkoutFixture as checkout,
  executorKey,
  filePermissions,
  proxyKey,
  write,
  writeSourceRepo,
} from "./fixture.ts";

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

  it("backs up agent instructions the shared AGENTS.md replaces", () => {
    const f = checkout();
    write(f.home, ".claude/CLAUDE.md", "# my Claude notes\n");
    write(f.home, ".codex/AGENTS.md", "# my Codex notes\n");
    const r = f.sync("--skip-packages");
    expect(r.stderr).toContain("Saved your previous ~/.claude/CLAUDE.md");
    const backup = (rel: string) =>
      readFileSync(
        path.join(f.home, ".config/ender-chest/backup", rel),
        "utf-8"
      );
    expect(backup(".claude/CLAUDE.md")).toBe("# my Claude notes\n");
    expect(backup(".codex/AGENTS.md")).toBe("# my Codex notes\n");
    expect(f.read(".claude/CLAUDE.md")).toContain("# Shared");
    expect(
      existsSync(
        path.join(f.home, ".config/ender-chest/backup/.grok/AGENTS.md")
      )
    ).toBe(false);
  });
});

describe("optional checkout files", () => {
  it("set up only agents whose directory exists, and apply without a skills manifest", () => {
    const f = checkout("", [".codex"]);
    write(f.repo, "agents/cursor/cli-config.json", '{"version":1}');
    rmSync(path.join(f.repo, "skills/manifest.json"));
    f.sync("--skip-packages");
    for (const dir of [
      ".claude",
      ".grok",
      ".cursor",
      ".gemini",
      ".config/muse",
      ".config/opencode",
    ]) {
      expect(existsSync(path.join(f.home, dir)), dir).toBe(false);
    }
    expect(readlinkSync(path.join(f.home, ".codex/skills/note"))).toBe(
      path.join(f.home, ".agents/skills/note")
    );
    const verified = f.run(["verify", "--profile", "mac"]);
    expect(verified.status, verified.stdout + verified.stderr).toBe(0);
    const pushed = f.run(["push", "--dry-run", "--profile", "mac"]);
    expect(pushed.status, pushed.stdout + pushed.stderr).toBe(0);
    expect(existsSync(path.join(f.repo, "skills/manifest.json"))).toBe(false);
  });

  it("name the shared instructions file when it is missing", () => {
    const f = checkout();
    const file = path.join(f.repo, "agents/shared/AGENTS.md");
    rmSync(file);
    const r = f.run(["sync", "--skip-packages", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toBe(`Missing ${file}.`);
  });
});

interface HookGroup {
  hooks: { command: string; timeout?: number; type: string }[];
  matcher?: string;
}
interface ClaudeSettings {
  hooks?: Record<string, HookGroup[]>;
  permissions?: { allow?: string[]; defaultMode?: string; deny?: string[] };
}
const hook = (command: string, timeout?: number): HookGroup => ({
  hooks: [{ command, timeout, type: "command" }],
});

describe("Claude settings", () => {
  it("keep local keys and replace only the entries the config added", () => {
    const f = checkout();
    const other = { ...hook("other-tool-hook"), matcher: "*" };
    const portable = (settings: ClaudeSettings) =>
      write(f.repo, "agents/claude/settings.json", JSON.stringify(settings));
    const settings = () => {
      const { hooks, permissions } = JSON.parse(
        f.read(".claude/settings.json")
      );
      return { hooks, permissions };
    };
    // The local Stop list already holds the config's hook, as after an earlier sync.
    write(
      f.home,
      ".claude/settings.json",
      JSON.stringify({
        hooks: { PostCompact: [other], Stop: [other, hook("repo", 60)] },
        permissions: { allow: ["Bash(ls:*)"], deny: ["Bash(rm:*)"] },
      })
    );
    portable({
      hooks: { Stop: [hook("repo", 60)] },
      permissions: { allow: ["Read"], defaultMode: "acceptEdits" },
    });
    f.sync("--skip-packages");
    expect(settings()).toEqual({
      hooks: { PostCompact: [other], Stop: [other, hook("repo", 60)] },
      permissions: {
        allow: ["Bash(ls:*)", "Read"],
        defaultMode: "acceptEdits",
        deny: ["Bash(rm:*)"],
      },
    });

    portable({
      hooks: { Stop: [hook("repo", 90)], SubagentStop: [hook("repo", 90)] },
      permissions: { allow: ["Edit"] },
    });
    f.sync("--skip-packages");
    expect(settings()).toEqual({
      hooks: {
        PostCompact: [other],
        Stop: [other, hook("repo", 90)],
        SubagentStop: [hook("repo", 90)],
      },
      permissions: {
        allow: ["Bash(ls:*)", "Edit"],
        defaultMode: "acceptEdits",
        deny: ["Bash(rm:*)"],
      },
    });

    // A config that stops setting a key removes only what sync added.
    portable({});
    f.sync("--skip-packages");
    expect(settings()).toEqual({
      hooks: { PostCompact: [other], Stop: [other] },
      permissions: {
        allow: ["Bash(ls:*)"],
        defaultMode: "acceptEdits",
        deny: ["Bash(rm:*)"],
      },
    });
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

// The script records what ec passed it, then exits with HELLO_EXIT. Hooks append their name
// and EC_JSON to hello-hooks, then exit with HOOK_EXIT.
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

[settings.target]
description = "Who to wave at."

[[commands]]
name = "say"
description = "Print the greeting."
usage = "ec hello say [--loud] [--lang LANG]"
options = [{ name = "loud" }, { name = "lang", type = "string", values = ["en", "fr"] }]

[[commands]]
name = "whisper"
needs = ["token"]

[[commands]]
name = "wave"
needs = ["target"]

[hooks]
sync = ["hook-sync"]
verify = ["hook-verify"]
`
  );
  const script = write(
    f.repo,
    "plugins/hello/bin/hello",
    `#!/bin/sh
case "$1" in hook-*) printf '%s %s\\n' "$1" "\${EC_JSON-unset}" >> "$HOME/hello-hooks"; exit "\${HOOK_EXIT:-0}" ;; esac
printf '%s\\n' "$@" > "$HOME/hello-args"
printf '%s' "$EC_PLUGIN_SETTINGS" > "$HOME/hello-settings"
printf '%s' "\${EC_JSON-}" > "$HOME/hello-json"
exit "\${HELLO_EXIT:-0}"
`
  );
  chmodSync(script, 0o755);
  return f;
};
describe("plugins from the config repo", () => {
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

  it("refuse a command that needs an unset secret, naming the secret to set", () => {
    const f = hello();
    const r = f.run(["hello", "whisper", "--json"]);
    expect(r.status).toBe(1);
    const result = JSON.parse(r.stdout);
    expect(result.error.code).toBe("interaction_required");
    expect(result.message).toContain("ec secret set hello");
    expect(existsSync(path.join(f.home, "hello-args"))).toBe(false);
    f.secret("hello", "fixture-hello-token");
    expect(f.run(["hello", "whisper"]).status).toBe(0);
  });

  it("refuse a command that needs an unset setting, naming where to add it", () => {
    const f = hello();
    const r = f.run(["hello", "wave", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain(
      "Plugin hello needs target. Add it under [plugins.hello]"
    );
    expect(existsSync(path.join(f.home, "hello-args"))).toBe(false);
  });

  it("run their sync and verify hooks without --json, and a failed hook fails sync", () => {
    const f = hello();
    f.sync("--skip-packages", "--json");
    expect(f.read("hello-hooks")).toBe("hook-sync unset\nhook-verify unset\n");
    const r = f.run(["sync", "--profile", "mac", "--skip-packages"], {
      HOOK_EXIT: "1",
    });
    expect(r.status).toBe(1);
    expect(r.stderr).toContain("The hello plugin's sync hook failed");
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
    const first = f.run(["--help", "hello"]);
    expect(first.status, first.stderr).toBe(0);
    expect(first.stdout).toContain("Usage: ec hello <command>");
    expect(f.run(["hello", "whisper", "--help"]).stdout).toContain("Needs,");
    const json = JSON.parse(
      f.run(["hello", "whisper", "--help", "--json"]).stdout
    );
    expect(json.data.command_definitions[0].needs).toEqual(["token"]);
    expect(existsSync(path.join(f.home, "hello-args"))).toBe(false);
  });

  it("fail a sync hook whose executable is missing, naming its path", () => {
    const f = hello();
    rmSync(path.join(f.repo, "plugins/hello/bin/hello"));
    const r = f.run(["sync", "--skip-packages", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain(
      "plugins/hello/bin/hello does not exist"
    );
  });

  it("fail sync before applying anything when two plugins set the provider", () => {
    const f = checkout(
      `${agentPlugins}\n[plugins.other]\nsource = "plugins/other"\n`
    );
    f.secret("cliproxyapi", proxyKey);
    write(
      f.repo,
      "plugins/other/plugin.toml",
      'name = "other"\nrun = "bin/other"\n\n[provider]\nbase_url = "https://other.example.test"\napi_key = "fixture"\n'
    );
    const message = "Only one plugin may set the model provider";
    const synced = f.run(["sync", "--skip-packages", "--json"]);
    expect(synced.status).toBe(1);
    expect(JSON.parse(synced.stdout).message).toContain(message);
    expect(existsSync(path.join(f.home, ".gitconfig"))).toBe(false);
    const verified = f.run(["verify", "--json"]);
    expect(verified.status).toBe(1);
    expect(JSON.parse(verified.stdout).message).toContain(message);
  });

  it("are listed with built-ins by ec plugin list", () => {
    const f = hello();
    const r = f.run(["plugin", "list", "--json"]);
    expect(r.status, r.stderr).toBe(0);
    expect(JSON.parse(r.stdout).data.plugins).toEqual([
      {
        commands: ["say", "whisper", "wave"],
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
    const f = checkout(agentPlugins, agentHomes);
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

    writeSourceRepo(f.repo);
    f.sync("--skip-packages");
    expect(claudeServers()).toEqual({ local: { command: "tool" } });
    expect(claudeEnv()).not.toHaveProperty("ANTHROPIC_AUTH_TOKEN");
    expect(claudeEnv()).not.toHaveProperty("ANTHROPIC_BASE_URL");
    expect(codex()).toEqual({
      mcp_servers: { local: { command: "tool" } },
      model_providers: { mine: { base_url: "http://mine.example.test" } },
    });
    expect(grok().mcp_servers).toEqual({ local: { command: "tool" } });
    expect(grok().model).toEqual({ custom: { model: "mine" } });
    expect(grok()).not.toHaveProperty("models.default");
    for (const text of [
      f.read(".claude.json"),
      f.read(".claude/settings.json"),
      f.read(".codex/config.toml"),
      f.read(".grok/config.toml"),
    ]) {
      expect(text).not.toContain(proxyKey);
      expect(text).not.toContain(executorKey);
    }
  });

  it("fail verify when an agent lost the MCP server", () => {
    const f = checkout(agentPlugins);
    f.secret("cliproxyapi", proxyKey);
    f.secret("executor", executorKey);
    f.sync("--skip-packages");
    const file = path.join(f.home, ".codex/config.toml");
    write(f.home, ".codex/config.toml", 'model = "gpt-5.6-sol"\n');
    const r = f.run(["verify", "--json"]);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain(
      `MCP server executor is missing or stale in ${file}`
    );
  });

  it("reach Cursor, Muse, Gemini, and OpenCode when their directories exist", () => {
    const f = checkout(agentPlugins);
    f.secret("cliproxyapi", proxyKey);
    f.secret("executor", executorKey);
    const xdg = path.join(f.home, "xdg");
    const env = { XDG_CONFIG_HOME: xdg };
    for (const dir of [".cursor", "xdg/muse"]) {
      mkdirSync(path.join(f.home, dir), { recursive: true });
    }
    write(f.home, ".gemini/settings.json", '{"ui":{"theme":"dark"}}');
    const local = { command: ["tool"], type: "local" };
    write(
      f.home,
      "xdg/opencode/opencode.json",
      JSON.stringify({ mcp: { servers: { local } } })
    );
    write(f.repo, "agents/gemini/settings.json", '{"ui":{"hideTips":true}}');
    const sync = f.run(["sync", "--profile", "mac", "--skip-packages"], env);
    expect(sync.status, sync.stdout + sync.stderr).toBe(0);
    const json = (rel: string) => JSON.parse(f.read(rel));
    for (const rel of [
      ".gemini/GEMINI.md",
      "xdg/muse/AGENTS.md",
      "xdg/opencode/AGENTS.md",
    ]) {
      expect(f.read(rel), rel).toContain("# Shared");
    }
    const headers = { Authorization: `Bearer ${executorKey}` };
    const url = "https://mcp.example.test:4312/mcp";
    expect(json(".gemini/settings.json")).toEqual({
      mcpServers: { executor: { headers, httpUrl: url } },
      ui: { hideTips: true, theme: "dark" },
    });
    expect(json(".cursor/mcp.json").mcpServers.executor).toEqual({
      headers,
      url,
    });
    expect(json("xdg/muse/settings.json")).toEqual({
      mcpServers: { executor: { headers, type: "streamable-http", url } },
      schema_version: 1,
    });
    expect(json("xdg/opencode/opencode.json")).toEqual({
      mcp: {
        servers: {
          executor: { headers, oauth: false, type: "remote", url },
          local,
        },
      },
    });
    expect(existsSync(path.join(f.home, ".cursor/cli-config.json"))).toBe(
      false
    );
    expect(f.run(["verify", "--profile", "mac"], env).status).toBe(0);

    const opencode = write(
      f.home,
      "xdg/opencode/opencode.json",
      JSON.stringify({ mcp: { servers: { local } } })
    );
    const verify = f.run(["verify", "--profile", "mac"], env);
    expect(verify.status).toBe(1);
    expect(verify.stderr).toContain(
      `MCP server executor is missing or stale in ${opencode}`
    );
  });

  it("leave JSONC files and older MCP formats alone, with a note", () => {
    const f = checkout(agentPlugins);
    f.secret("cliproxyapi", proxyKey);
    f.secret("executor", executorKey);
    const jsonc = '{\n  // mine\n  "ui": { "theme": "dark" },\n}\n';
    const legacy =
      '{"schema_version":1,"mcp_servers":{"local":{"command":"tool"}}}';
    const gemini = write(f.home, ".gemini/settings.json", jsonc);
    const muse = write(f.home, ".config/muse/settings.json", legacy);
    const v1 = '{"mcp":{"local":{"type":"local","command":["tool"]}}}';
    const opencode = write(f.home, ".config/opencode/opencode.json", v1);
    const r = f.sync("--skip-packages");
    expect(readFileSync(gemini, "utf-8")).toBe(jsonc);
    expect(readFileSync(muse, "utf-8")).toBe(legacy);
    expect(readFileSync(opencode, "utf-8")).toBe(v1);
    for (const file of [gemini, muse, opencode]) {
      expect(r.stderr).toContain(`note: left ${file} alone`);
    }
    expect(f.read(".gemini/GEMINI.md")).toContain("# Shared");
  });

  it("replace stale MCP entries and their old credentials, keeping local options", () => {
    const f = checkout(
      '[plugins.executor]\nurl = "https://mcp.example.test:4312"\nkey = { secret = "executor" }\n',
      agentHomes
    );
    f.secret("executor", executorKey);
    write(
      f.home,
      ".claude.json",
      JSON.stringify({
        mcpServers: {
          executor: {
            timeout: 5,
            type: "http",
            url: "https://old.example.test/mcp",
          },
        },
      })
    );
    write(
      f.home,
      ".codex/config.toml",
      '[mcp_servers.executor]\nurl = "https://old.example.test/mcp"\nbearer_token_env_var = "OLD"\nstartup_timeout_sec = 30\n'
    );
    write(
      f.home,
      ".grok/config.toml",
      '[mcp_servers.executor]\nurl = "https://old.example.test/mcp"\nenabled = true\nbearer_token_file = "~/old"\n'
    );
    f.sync("--skip-packages");
    const url = "https://mcp.example.test:4312/mcp";
    const authorization = `Bearer ${executorKey}`;
    const claudeFile = path.join(f.home, ".claude.json");
    expect(JSON.parse(f.read(".claude.json")).mcpServers.executor).toEqual({
      headers: { Authorization: authorization },
      timeout: 5,
      type: "http",
      url,
    });
    expect(toml(f.read(".codex/config.toml")).mcp_servers).toEqual({
      executor: {
        http_headers: { Authorization: authorization },
        startup_timeout_sec: 30,
        url,
      },
    });
    expect(toml(f.read(".grok/config.toml")).mcp_servers).toEqual({
      executor: {
        enabled: true,
        headers: { Authorization: authorization },
        url,
      },
    });
    // An unchanged entry leaves the file alone, since Claude Code rewrites it while running.
    const before = statSync(claudeFile).mtimeMs;
    f.sync("--skip-packages");
    expect(statSync(claudeFile).mtimeMs).toBe(before);
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
    write(f.repo, "unrelated.txt", "keep local");
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
    expect(f.git("status", "--short")).toContain("?? unrelated.txt");
    expect(f.git("rev-parse", "HEAD")).toBe(f.git("rev-parse", "@{upstream}"));
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

  it.each([
    [".claude.json", "Refusing local agent settings"],
    [".claude/settings.json", "Refusing credential or runtime path"],
  ])("refuses %s already in the checkout", (rel, message) => {
    const f = checkout();
    write(f.repo, `home/${rel}`, "{}\n");
    const r = f.run(["push", "--dry-run", "--json"]);
    expect(r.status, r.stdout + r.stderr).toBe(1);
    expect(r.stdout).toContain(message);
  });
});
