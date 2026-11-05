import { execFile } from "node:child_process";
import { once } from "node:events";
import { readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import path from "node:path";
import { promisify } from "node:util";

import { parse as toml } from "smol-toml";
import { afterEach, describe, expect, it } from "vitest";

import { ec, pluginFixture, write, writeSourceRepo } from "./fixture.ts";

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

const key = "test-client-key";
const config = (url: string, extra = "") =>
  `[plugins.cliproxyapi]\nurl = ${JSON.stringify(url)}\nkey = { secret = "cliproxyapi" }\n${extra}`;
const proxy = (url = "http://proxy.example.test:8317/", extra = "") => {
  const f = pluginFixture(config(url, extra));
  roots.push(f.root);
  f.secret("cliproxyapi", key);
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

describe("cliproxyapi plugin", () => {
  it("prints the base URL and needs a command to run", () => {
    const f = proxy();
    const url = f.run(["cliproxyapi", "url", "--json"]);
    expect(JSON.parse(url.stdout)).toMatchObject({
      data: { url: "http://proxy.example.test:8317/v1" },
      ok: true,
    });
    expect(url.stdout).not.toContain(key);
    expect(f.run(["cliproxyapi", "run"]).status).toBe(2);
  });

  it("rejects a url with credentials without printing it", () => {
    const f = proxy("https://user:hunter2@proxy.example.test");
    const r = f.run(["cliproxyapi", "url", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain("Invalid url");
    expect(r.stdout + r.stderr).not.toContain("hunter2");
  });

  it("passes endpoint, key, and literal arguments only to the requested command", () => {
    const f = proxy();
    const r = f.run([
      "cliproxyapi",
      "run",
      process.execPath,
      "-e",
      "console.log(JSON.stringify([process.env.OPENAI_BASE_URL, process.env.OPENAI_API_KEY, process.env.EC_PLUGIN_SETTINGS ?? null, process.argv.slice(1)]))",
      "literal $(echo nope)",
      "--json",
      "--help",
    ]);
    expect(r.status, r.stderr).toBe(0);
    expect(JSON.parse(r.stdout)).toEqual([
      "http://proxy.example.test:8317/v1",
      key,
      null,
      ["literal $(echo nope)", "--json", "--help"],
    ]);
  });

  // ec reports a missing secret before it starts a plugin, so drive the plugin directly.
  it("asks for the key only for commands that need it", () => {
    const f = proxy();
    const env = {
      EC_JSON: "1",
      EC_PLUGIN_SETTINGS: JSON.stringify({
        url: "http://proxy.example.test:8317",
      }),
    };
    const url = f.run(["__plugin", "cliproxyapi", "url"], env);
    expect(url.status, url.stderr).toBe(0);
    const models = f.run(["__plugin", "cliproxyapi", "models"], env);
    expect(models.status).toBe(1);
    const result = JSON.parse(models.stdout);
    expect(result.error.code).toBe("interaction_required");
    expect(result.message).toContain('key = { secret = "cliproxyapi" }');
    expect(result.message).toContain("ec secret set cliproxyapi");
  });

  it("authenticates model discovery and reports HTTP failures", async () => {
    const requests: { url?: string; authorization?: string }[] = [];
    let status = 200;
    const url = await listen((req, res) => {
      requests.push({ authorization: req.headers.authorization, url: req.url });
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ data: [{ id: "z-model" }, { id: "a-model" }] }));
    });
    const f = proxy(`${url}/`);
    const result = await exec(ec, ["cliproxyapi", "models", "--json"], {
      env: f.env,
    });
    expect(JSON.parse(result.stdout).data.models).toEqual([
      "a-model",
      "z-model",
    ]);
    expect(requests).toEqual([
      { authorization: `Bearer ${key}`, url: "/v1/models" },
    ]);
    status = 401;
    await expect(
      exec(ec, ["cliproxyapi", "models"], { env: f.env })
    ).rejects.toMatchObject({
      code: 1,
      stderr: expect.stringContaining("rejected the client key"),
    });
  });

  it("applies the endpoint and key to every agent on sync", () => {
    const f = proxy("https://proxy.example.test:8317");
    writeSourceRepo(f.repo, config("https://proxy.example.test:8317"));
    const r = f.run(["sync", "--skip-packages", "--profile", "mac"]);
    expect(r.status, r.stdout + r.stderr).toBe(0);
    const base = "https://proxy.example.test:8317";
    const claude = JSON.parse(
      readFileSync(path.join(f.home, ".claude/settings.json"), "utf-8")
    );
    const codex = toml(
      readFileSync(path.join(f.home, ".codex/config.toml"), "utf-8")
    );
    const grok = toml(
      readFileSync(path.join(f.home, ".grok/config.toml"), "utf-8")
    );
    expect(claude.env.ANTHROPIC_BASE_URL).toBe(base);
    expect(codex).toHaveProperty(
      "model_providers.cliproxyapi.base_url",
      `${base}/v1`
    );
    for (const model of ["grok-4.7", "grok-4.6", "grok-4.5"]) {
      expect(grok.model).toHaveProperty([model, "base_url"], `${base}/v1`);
    }
  });

  // Fake launchctl and ssh record their arguments. FAIL_KICKSTART makes kickstart fail
  // like an unloaded agent.
  const restartSetup = async (onHost: boolean, extra = "") => {
    let status = 200;
    const url = await listen((req, res) => {
      res.writeHead(
        req.headers.authorization === `Bearer ${key}` ? status : 401
      );
      res.end("{}");
    });
    const f = proxy(url, extra);
    if (onHost) {
      write(f.home, "Library/LaunchAgents/io.cliproxyapi.plist", "<plist/>");
    }
    const calls = path.join(f.root, "calls.log");
    const record = (name: string) =>
      f.fake(
        name,
        `const a=process.argv.slice(2);require('node:fs').appendFileSync(${JSON.stringify(calls)},${JSON.stringify(name)}+' '+a.join(' ')+"\\n");process.exit(a[0]==='kickstart'&&process.env.FAIL_KICKSTART?113:0)`
      );
    record("launchctl");
    const env = {
      ...f.env,
      ...record("ssh"),
      CLIPROXY_LOCAL_URL: url,
      CLIPROXY_RESTART_TIMEOUT: "2",
    };
    const restart = (more: Record<string, string> = {}) =>
      exec(ec, ["cliproxyapi", "restart"], { env: { ...env, ...more } });
    const takeCalls = () => {
      const text = readFileSync(calls, "utf-8");
      rmSync(calls);
      return text;
    };
    return {
      home: f.home,
      restart,
      setStatus: (s: number) => {
        status = s;
      },
      takeCalls,
    };
  };

  it("restarts the launch agent on the host and waits for the proxy to answer", async () => {
    const { home, restart, takeCalls, setStatus } = await restartSetup(true);
    const domain = `gui/${process.getuid?.()}`;
    const result = await restart();
    expect(result.stdout).toContain("CLIProxyAPI restarted.");
    expect(takeCalls()).toBe(
      `launchctl kickstart -k ${domain}/io.cliproxyapi\n`
    );
    await restart({ FAIL_KICKSTART: "1" });
    expect(takeCalls()).toBe(
      `launchctl kickstart -k ${domain}/io.cliproxyapi\nlaunchctl bootstrap ${domain} ${path.join(home, "Library/LaunchAgents/io.cliproxyapi.plist")}\n`
    );
    setStatus(503);
    await expect(restart()).rejects.toMatchObject({
      code: 1,
      stderr: expect.stringContaining("did not answer"),
    });
  });

  it("restarts the proxy on the url's host over SSH from other machines", async () => {
    const { restart, takeCalls } = await restartSetup(false);
    const result = await restart();
    expect(result.stdout).toContain("CLIProxyAPI restarted on 127.0.0.1");
    expect(takeCalls()).toBe(
      'ssh -o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 127.0.0.1 "$HOME/.local/bin/ec" cliproxyapi restart\n'
    );
  });

  it("restarts over SSH on the host setting when it is set", async () => {
    const { restart, takeCalls } = await restartSetup(
      false,
      'host = "admin@proxy-host.example.test"\n'
    );
    const result = await restart();
    expect(result.stdout).toContain(
      "CLIProxyAPI restarted on admin@proxy-host.example.test"
    );
    expect(takeCalls()).toContain(
      ' admin@proxy-host.example.test "$HOME/.local/bin/ec" cliproxyapi restart\n'
    );
  });

  it("sends the key to curl on stdin, never in its arguments", () => {
    const f = proxy();
    const log = path.join(f.root, "curl.log");
    const r = f.run(
      ["cliproxyapi", "models"],
      f.fake(
        "curl",
        `require('node:fs').writeFileSync(${JSON.stringify(log)},JSON.stringify(process.argv.slice(2)));process.exit(7)`
      )
    );
    expect(r.status).toBe(1);
    expect(readFileSync(log, "utf-8")).not.toContain(key);
  });
});
