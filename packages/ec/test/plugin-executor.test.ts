import { execFile, spawnSync } from "node:child_process";
import { once } from "node:events";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
} from "node:fs";
import { createServer } from "node:http";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import path from "node:path";
import { promisify } from "node:util";

import { parse as toml } from "smol-toml";
import { afterEach, describe, expect, it } from "vitest";

import {
  ec,
  filePermissions,
  pluginFixture,
  write,
  writeSourceRepo,
} from "./fixture.ts";

const exec = promisify(execFile);
const roots: string[] = [];
const servers: Server[] = [];
afterEach(async () => {
  await Promise.all(
    servers.splice(0).map((server) => server[Symbol.asyncDispose]())
  );
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

const key = "fake-executor-key-for-tests-xxxxxxxxxx";
const settings = (url: string) =>
  `[plugins.executor]\nurl = ${JSON.stringify(url)}\nkey = { secret = "executor" }\npackage = "executor@beta"\n`;
const executor = (url: string) => {
  const f = pluginFixture(settings(url));
  roots.push(f.root);
  f.secret("executor", key);
  return f;
};
const listen = async (
  handler: Parameters<typeof createServer>[1]
): Promise<string> => {
  const server = createServer(handler);
  servers.push(server);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  // SAFETY: The server is listening on a TCP port, so address() returns AddressInfo.
  const address = server.address() as AddressInfo;
  return `http://127.0.0.1:${address.port}`;
};

// Fake commands record their arguments. The fake executor prints its environment for
// serve and a link for pair. `dns` is this machine's Tailscale name.
const fakes = (url: string, dns = "other.example.test.") => {
  const f = executor(url);
  const bin = path.join(f.home, "bin");
  const calls = path.join(f.root, "calls.log");
  const record = (name: string, body = "exit 0") => {
    write(
      f.home,
      `bin/${name}`,
      `#!/bin/sh\necho "${name} $*" >> "${calls}"\n${body}\n`
    );
    chmodSync(path.join(bin, name), 0o755);
  };
  for (const name of ["launchctl", "npm"]) {
    record(name);
  }
  record("ssh", 'echo "https://pair.example.test/link"');
  record(
    "tailscale",
    `[ "$1" = status ] && echo '{"Self":{"DNSName":"${dns}"}}'; exit 0`
  );
  record(
    "executor",
    '[ "$1" = serve ] && env | grep -E "^(EXECUTOR_|EC_PLUGIN_SETTINGS=)" | sort; [ "$1" = pair ] && echo "https://pair.example.test/local"; [ "$1" = --version ] && echo "executor v2.0.0-beta.14"; exit 0'
  );
  write(f.home, ".local/bin/ec", "#!/bin/sh\n");
  const env = {
    ...f.env,
    EXECUTOR_KEY_STORAGE: "os",
    EXECUTOR_RESTART_TIMEOUT: "2",
    PATH: `${bin}:/usr/bin:/bin`,
  };
  const run = (args: string[]) => exec(ec, ["executor", ...args], { env });
  const takeCalls = () => {
    if (!existsSync(calls)) {
      return "";
    }
    const text = readFileSync(calls, "utf-8");
    rmSync(calls);
    return text;
  };
  return { env, home: f.home, run, takeCalls };
};

describe("executor plugin", () => {
  it("replaces stale MCP entries in every agent with the shared endpoint and key", () => {
    const f = executor("https://mcp.example.test:4312");
    writeSourceRepo(f.repo, settings("https://mcp.example.test:4312"));
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
    const sync = () => {
      const r = f.run(["sync", "--skip-packages", "--profile", "mac"]);
      expect(r.status, r.stdout + r.stderr).toBe(0);
    };
    sync();
    const url = "https://mcp.example.test:4312/mcp";
    const authorization = `Bearer ${key}`;
    const claudeFile = path.join(f.home, ".claude.json");
    expect(
      JSON.parse(readFileSync(claudeFile, "utf-8")).mcpServers.executor
    ).toEqual({
      headers: { Authorization: authorization },
      timeout: 5,
      type: "http",
      url,
    });
    const codex = toml(
      readFileSync(path.join(f.home, ".codex/config.toml"), "utf-8")
    );
    expect(codex.mcp_servers).toEqual({
      executor: {
        http_headers: { Authorization: authorization },
        startup_timeout_sec: 30,
        url,
      },
    });
    const grok = toml(
      readFileSync(path.join(f.home, ".grok/config.toml"), "utf-8")
    );
    expect(grok.mcp_servers).toEqual({
      executor: {
        enabled: true,
        headers: { Authorization: authorization },
        url,
      },
    });
    // An unchanged entry leaves the file alone, since Claude Code rewrites it while running.
    const before = statSync(claudeFile).mtimeMs;
    sync();
    expect(statSync(claudeFile).mtimeMs).toBe(before);
  });

  it("prints the MCP endpoint and checks the key", async () => {
    const requests: { url?: string; authorization?: string }[] = [];
    let status = 200;
    const url = await listen((req, res) => {
      requests.push({ authorization: req.headers.authorization, url: req.url });
      res.writeHead(status);
      res.end("{}");
    });
    const { run } = fakes(url);
    const printed = await run(["url"]);
    expect(printed.stdout.trim()).toBe(`${url}/mcp`);
    const checked = await run(["status", "--json"]);
    expect(JSON.parse(checked.stdout).data).toEqual({
      mcp: `${url}/mcp`,
      url,
    });
    expect(requests).toEqual([
      { authorization: `Bearer ${key}`, url: "/openapi.json" },
    ]);
    status = 401;
    await expect(run(["status"])).rejects.toMatchObject({
      code: 1,
      stderr: expect.stringContaining("rejected the API key"),
    });
  });

  it("reports an unreachable server", async () => {
    const { run } = fakes("http://127.0.0.1:9");
    const result = await run(["status", "--json"]).catch((error) => error);
    expect(JSON.parse(result.stdout).error.code).toBe("unreachable");
  });

  // ec reports a missing secret before it starts a plugin, so drive the plugin directly.
  it("asks for the key only for commands that need it", () => {
    const f = executor("https://mcp.example.test:4312");
    const env = {
      EC_JSON: "1",
      EC_PLUGIN_SETTINGS: JSON.stringify({
        url: "https://mcp.example.test:4312",
      }),
    };
    expect(f.run(["__plugin", "executor", "url"], env).status).toBe(0);
    const status = f.run(["__plugin", "executor", "status"], env);
    expect(status.status).toBe(1);
    const result = JSON.parse(status.stdout);
    expect(result.error.code).toBe("interaction_required");
    expect(result.message).toContain('key = { secret = "executor" }');
    expect(result.message).toContain("ec secret set executor");
  });

  it("runs restart, update, and pair on the host over SSH from other machines", async () => {
    const url = await listen((_req, res) => res.writeHead(200).end("{}"));
    const { run, takeCalls } = fakes(url);
    const paired = await run(["pair"]);
    expect(paired.stdout.trim()).toBe("https://pair.example.test/link");
    expect(takeCalls()).toContain(
      'ssh -o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 127.0.0.1 "$HOME/.local/bin/ec" executor pair\n'
    );
    const updated = await run(["update"]);
    expect(updated.stdout).toContain(`Executor answers at ${url}.`);
    expect(takeCalls()).toContain(
      '127.0.0.1 "$HOME/.local/bin/ec" executor update\n'
    );
  });

  it.runIf(process.platform === "darwin")(
    "installs the package and launch agent on the host without putting keys in the plist",
    async () => {
      const url = await listen((req, res) =>
        res
          .writeHead(req.headers.authorization === `Bearer ${key}` ? 200 : 401)
          .end("{}")
      );
      // The host matches the configured URL in Tailscale.
      const { home, run, takeCalls } = fakes(url, "127.0.0.1.");
      const result = await run(["update"]);
      expect(result.stdout).toContain(
        `executor v2.0.0-beta.14 runs at ${url}.`
      );
      const domain = `gui/${process.getuid?.()}`;
      const plistFile = path.join(
        home,
        "Library/LaunchAgents/sh.executor.server.plist"
      );
      const calls = takeCalls();
      expect(calls).toContain(
        "npm install --global executor@beta --include=optional\n"
      );
      expect(calls).toContain(`launchctl bootstrap ${domain} ${plistFile}\n`);
      const plist = readFileSync(plistFile, "utf-8");
      expect(plist).toContain(
        `<string>${home}/.local/bin/ec</string>\n    <string>executor</string>\n    <string>serve</string>`
      );
      expect(plist).not.toContain(key);
      const keyFile = path.join(home, ".config/executor/encryption-key");
      const encryption = readFileSync(keyFile, "utf-8");
      expect(encryption.trim()).toMatch(/^[0-9a-f]{64}$/u);
      expect(filePermissions(keyFile)).toBe(0o600);
      expect(result.stdout + result.stderr).not.toContain(encryption.trim());
      await run(["update"]);
      expect(readFileSync(keyFile, "utf-8")).toBe(encryption);
      await run(["restart"]);
      expect(takeCalls()).toContain(
        `launchctl kickstart -k ${domain}/sh.executor.server\n`
      );
    }
  );

  it.runIf(process.platform === "darwin")(
    "refuses to create a new encryption key for existing data",
    async () => {
      const url = await listen((_req, res) => res.writeHead(200).end("{}"));
      const { home, run } = fakes(url, "127.0.0.1.");
      mkdirSync(path.join(home, ".executor/v2/cli"), { recursive: true });
      await expect(run(["update"])).rejects.toMatchObject({
        code: 1,
        stderr: expect.stringContaining("Restore the key from a backup"),
      });
      expect(
        existsSync(path.join(home, ".config/executor/encryption-key"))
      ).toBe(false);
    }
  );

  it("serves with the shared API key and the host's encryption key, and no plugin settings", () => {
    const { env, home } = fakes("https://mcp.example.test:4312");
    write(home, ".config/executor/encryption-key", `${"ab".repeat(32)}\n`);
    const result = spawnSync(ec, ["executor", "serve"], {
      encoding: "utf-8",
      env,
    });
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout.trim().split("\n")).toEqual([
      `EXECUTOR_API_KEY=${key}`,
      "EXECUTOR_BROWSER_ORIGIN=https://mcp.example.test:4312",
      `EXECUTOR_ENCRYPTION_KEY=${"ab".repeat(32)}`,
      "EXECUTOR_NO_UPDATE_CHECK=1",
      "EXECUTOR_PORT=4312",
      "EXECUTOR_RESTART_TIMEOUT=2",
    ]);
  });
});
