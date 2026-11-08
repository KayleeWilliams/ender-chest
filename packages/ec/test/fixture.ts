import { spawnSync } from "node:child_process";
import { once } from "node:events";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { expect, onTestFinished } from "vitest";

export const cliRoot = fileURLToPath(new URL("..", import.meta.url));
export const workspaceRoot = fileURLToPath(
  new URL("../../..", import.meta.url)
);

export const filePermissions = (file: string): number =>
  // oxlint-disable-next-line eslint/no-bitwise -- Extract POSIX permissions without file type flags.
  statSync(file).mode & 0o777;

export const write = (root: string, rel: string, body: string): string => {
  const dest = path.join(root, rel);
  mkdirSync(path.dirname(dest), { recursive: true });
  writeFileSync(dest, body);
  return dest;
};

// The fixture checkout's home files: plain, with a mode, and `once` files with and without a
// template.
const sourceManifest = `files = [
  ".gitconfig",
  ".zshrc",
  ".zprofile",
  { path = ".ssh/config", mode = "600" },
  { path = ".gitconfig.local", from = "git/gitconfig.local.example", once = true },
  { path = ".zprofile.local", once = true },
  { path = ".ssh/config.local", from = "ssh/config.local.example", mode = "600", once = true },
]
`;

// `extra` is appended to ender-chest.toml, for [plugins.*] or [[setup]] tables.
export const writeSourceRepo = (repo: string, extra = ""): void => {
  write(repo, "ender-chest.toml", `${sourceManifest}${extra}`);
  write(
    repo,
    "home/.gitconfig",
    "[rerere]\n\tenabled = true\n[include]\n\tpath = .gitconfig.local\n"
  );
  write(repo, "home/.zshrc", 'eval "$(fnm env --use-on-cd --shell zsh)"\n');
  write(repo, "home/.zprofile", 'export PATH="$HOME/.local/bin:$PATH"\n');
  write(
    repo,
    "home/.ssh/config",
    "Include ~/.ssh/config.local\n\nHost github.com\n  User git\n"
  );
  write(
    repo,
    "agents/shared/AGENTS.md",
    "# Shared\n\nGitHub publishing authorization\n\nVitest\n\nWhen publishing work as stacked PRs, use `gh stack`.\n"
  );
  write(
    repo,
    "agents/claude/settings.json",
    `{"model":"claude-fable-5[1m]","effortLevel":"high"}\n`
  );
  write(repo, "agents/codex/config.toml", 'model = "gpt-5.6-sol"\n');
  write(repo, "agents/grok/config.toml", "[cli]\nauto_update = true\n");
  write(repo, "git/gitconfig.local.example", "# local git\n");
  write(repo, "ssh/config.local.example", "# ssh local\n");
  write(repo, "skills/manifest.json", `{"version":1,"skills":[]}\n`);
  write(
    repo,
    "skills/note/SKILL.md",
    "---\nname: note\ndescription: A personal note.\n---\n\n# Note\n"
  );
};

export const gitInit = (repo: string): void => {
  mkdirSync(repo, { recursive: true });
  const run = (args: string[]) => {
    const result = spawnSync("git", args, { cwd: repo, encoding: "utf-8" });
    if (result.status !== 0) {
      throw new Error(result.stderr || `git ${args.join(" ")}`);
    }
  };
  run(["init"]);
  run(["config", "user.email", "ender@test"]);
  run(["config", "user.name", "ender"]);
  run(["config", "commit.gpgsign", "false"]);
};

export const ec = path.join(cliRoot, "zig-out/bin/ec");
// The source hash the build recorded beside the binary.
export const builtHash = (prefix = path.join(cliRoot, "zig-out")): string =>
  readFileSync(path.join(prefix, "source_hash.txt"), "utf-8").trim();

// The release targets, from the list release tooling reads.
export const targets: { key: string }[] = JSON.parse(
  readFileSync(path.join(cliRoot, "src/targets.json"), "utf-8")
);
// This machine's release target key, such as aarch64-macos.
export const hostTarget = (): string => {
  const arch = process.arch === "arm64" ? "aarch64" : "x86_64";
  const key = `${arch}-${process.platform === "darwin" ? "macos" : "linux"}`;
  expect(targets.map((t) => t.key)).toContain(key);
  return key;
};

// A config checkout whose ender-chest.toml enables plugins, with a temporary HOME, removed
// after the test.
// - `fake` puts a stand-in command, a Node script, first on PATH.
// - `record` fakes a command that appends "NAME ARGS" to a log, then runs `body`; `takeCalls`
//   returns and clears that log.
// - `pings` fakes ping: it appends its target to ping.log and exits with one code per call
//   from `codes`, repeating the last.
// - `secret` stores a value with ec secret set.
export const pluginFixture = (config: string) => {
  const root = mkdtempSync(path.join(tmpdir(), "ec-plugin-"));
  onTestFinished(() => rmSync(root, { force: true, recursive: true }));
  const repo = path.join(root, "repo");
  const home = path.join(root, "home");
  mkdirSync(home, { recursive: true });
  write(repo, "ender-chest.toml", config);
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    EC_JSON: undefined,
    EC_NO_UPDATE: "1",
    EC_PLUGIN_SETTINGS: undefined,
    EC_REPO: repo,
    HOME: home,
    XDG_CONFIG_HOME: undefined,
  };
  const run = (args: string[], overrides: NodeJS.ProcessEnv = {}) =>
    spawnSync(ec, args, {
      cwd: root,
      encoding: "utf-8",
      env: { ...env, ...overrides },
      timeout: 15_000,
    });
  const fake = (name: string, code: string) => {
    const file = write(home, `bin/${name}`, `#!${process.execPath}\n${code}\n`);
    chmodSync(file, 0o755);
    return { PATH: `${path.dirname(file)}:/usr/bin:/bin` };
  };
  const calls = path.join(root, "calls.log");
  const record = (name: string, body = "") =>
    fake(
      name,
      `const a=process.argv.slice(2);require('node:fs').appendFileSync(${JSON.stringify(calls)},${JSON.stringify(name)}+' '+a.join(' ')+"\\n");${body}`
    );
  const takeCalls = () => {
    if (!existsSync(calls)) {
      return "";
    }
    const text = readFileSync(calls, "utf-8");
    rmSync(calls);
    return text;
  };
  const pings = (codes: number[]) => {
    const count = path.join(root, "pings");
    const log = path.join(root, "ping.log");
    return fake(
      "ping",
      `const fs=require('node:fs'),f=${JSON.stringify(count)},c=${JSON.stringify(codes)};fs.appendFileSync(${JSON.stringify(log)},process.argv.at(-1)+"\\n");const n=fs.existsSync(f)?+fs.readFileSync(f,'utf8'):0;fs.writeFileSync(f,String(n+1));process.exit(c[Math.min(n,c.length-1)]);`
    );
  };
  const secret = (name: string, value: string) => {
    const r = spawnSync(ec, ["secret", "set", name], {
      encoding: "utf-8",
      env,
      input: value,
    });
    if (r.status !== 0) {
      throw new Error(r.stdout + r.stderr);
    }
  };
  const configure = (text: string) => write(repo, "ender-chest.toml", text);
  return {
    configure,
    env,
    fake,
    home,
    pings,
    record,
    repo,
    root,
    run,
    secret,
    takeCalls,
  };
};

// An HTTP server on 127.0.0.1 for the test, closed after it. Returns its origin.
export const listen = async (
  handler: Parameters<typeof createServer>[1]
): Promise<string> => {
  const server = createServer(handler);
  onTestFinished(() => server[Symbol.asyncDispose]());
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  // SAFETY: The server is listening on a TCP port, so address() returns AddressInfo.
  const address = server.address() as AddressInfo;
  return `http://127.0.0.1:${address.port}`;
};

// The proxy provider and the Executor MCP server, so syncs exercise agent settings.
export const agentPlugins = `
[plugins.cliproxyapi]
url = "https://proxy.example.test:8317"
key = { secret = "cliproxyapi" }

[plugins.executor]
url = "https://mcp.example.test:4312"
key = { secret = "executor" }
`;
export const proxyKey = "fixture-proxy-token";
export const executorKey = "fixture-executor-key-xxxxxxxxxxxxxxxx";

// The home directories of the agents writeSourceRepo configures. Sync sets up an agent only when
// its directory exists.
export const agentHomes = [".claude", ".codex", ".grok"];

// A git config checkout with the fixture's home files and `extra` in ender-chest.toml, plus the
// given agent directories in HOME. Removed after the test.
export const checkoutFixture = (extra = "", agentDirs: string[] = []) => {
  const f = pluginFixture("");
  writeSourceRepo(f.repo, extra);
  gitInit(f.repo);
  for (const dir of agentDirs) {
    mkdirSync(path.join(f.home, dir), { recursive: true });
  }
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
