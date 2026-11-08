import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";

import { describe, expect, it } from "vitest";

import { ec, listen, pluginFixture, write } from "./fixture.ts";

const exec = promisify(execFile);

const key = "test-client-key";
const config = (url: string, extra = "") =>
  `[plugins.cliproxyapi]\nurl = ${JSON.stringify(url)}\nkey = { secret = "cliproxyapi" }\n${extra}`;
const proxy = (url = "http://proxy.example.test:8317/", extra = "") => {
  const f = pluginFixture(config(url, extra));
  f.secret("cliproxyapi", key);
  return f;
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

  it("asks for the key only for commands that need it", () => {
    const f = pluginFixture(config("http://proxy.example.test:8317"));
    const url = f.run(["cliproxyapi", "url", "--json"]);
    expect(url.status, url.stderr).toBe(0);
    const models = f.run(["cliproxyapi", "models", "--json"]);
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
    f.record(
      "launchctl",
      "process.exit(a[0]==='kickstart'&&process.env.FAIL_KICKSTART?113:0)"
    );
    const env = {
      ...f.env,
      ...f.record("ssh"),
      CLIPROXY_LOCAL_URL: url,
      CLIPROXY_RESTART_TIMEOUT: "2",
    };
    const restart = (more: Record<string, string> = {}) =>
      exec(ec, ["cliproxyapi", "restart"], { env: { ...env, ...more } });
    return {
      home: f.home,
      restart,
      setStatus: (s: number) => {
        status = s;
      },
      takeCalls: f.takeCalls,
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
    expect(takeCalls()).toMatch(
      /^ssh .*BatchMode=yes.* 127\.0\.0\.1 "\$HOME\/\.local\/bin\/ec" cliproxyapi restart$/mu
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
