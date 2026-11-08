import { execFile, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";

import { describe, expect, it } from "vitest";

import {
  ec,
  filePermissions,
  listen,
  pluginFixture,
  write,
} from "./fixture.ts";

const exec = promisify(execFile);

const key = "fake-executor-key-for-tests-xxxxxxxxxx";
const settings = (url: string) =>
  `[plugins.executor]\nurl = ${JSON.stringify(url)}\nkey = { secret = "executor" }\npackage = "executor@beta"\n`;
const executor = (url: string) => {
  const f = pluginFixture(settings(url));
  f.secret("executor", key);
  return f;
};

// Fake commands record their arguments. The fake executor prints its environment for
// serve and a link for pair. `dns` is this machine's Tailscale name.
const fakes = (url: string, dns = "other.example.test.") => {
  const f = executor(url);
  f.record("launchctl");
  f.record("npm");
  f.record("ssh", "console.log('https://pair.example.test/link')");
  f.record(
    "tailscale",
    `if(a[0]==='status')console.log(JSON.stringify({Self:{DNSName:${JSON.stringify(dns)}}}))`
  );
  const { PATH } = f.record(
    "executor",
    "if(a[0]==='serve')for(const k of Object.keys(process.env).sort())if(/^EXECUTOR_|^EC_PLUGIN_SETTINGS$/u.test(k))console.log(k+'='+process.env[k]);if(a[0]==='pair')console.log('https://pair.example.test/local');if(a[0]==='--version')console.log('executor v2.0.0-beta.14')"
  );
  write(f.home, ".local/bin/ec", "#!/bin/sh\n");
  const env = {
    ...f.env,
    EXECUTOR_KEY_STORAGE: "os",
    EXECUTOR_RESTART_TIMEOUT: "2",
    PATH,
  };
  const run = (args: string[]) => exec(ec, ["executor", ...args], { env });
  return { env, home: f.home, run, takeCalls: f.takeCalls };
};

describe("executor plugin", () => {
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

  it("asks for the key only for commands that need it", () => {
    const f = pluginFixture(settings("https://mcp.example.test:4312"));
    expect(f.run(["executor", "url", "--json"]).status).toBe(0);
    const status = f.run(["executor", "status", "--json"]);
    expect(status.status).toBe(1);
    const result = JSON.parse(status.stdout);
    expect(result.error.code).toBe("interaction_required");
    expect(result.message).toContain('key = { secret = "executor" }');
    expect(result.message).toContain("ec secret set executor");
    // url never needs the key, but still rejects a saved one that cannot work.
    f.secret("executor", "too-short");
    const url = f.run(["executor", "url"]);
    expect(url.status).toBe(1);
    expect(url.stderr).toContain("Invalid Executor key.");
    f.secret("executor", key);
    expect(f.run(["executor", "url"]).status).toBe(0);
  });

  it("runs restart, update, and pair on the host over SSH from other machines", async () => {
    const url = await listen((_req, res) => res.writeHead(200).end("{}"));
    const { run, takeCalls } = fakes(url);
    const paired = await run(["pair"]);
    expect(paired.stdout.trim()).toBe("https://pair.example.test/link");
    expect(takeCalls()).toMatch(
      /^ssh .*BatchMode=yes.* 127\.0\.0\.1 "\$HOME\/\.local\/bin\/ec" executor pair$/mu
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
      expect(plist.replaceAll(/\s+/gu, "")).toContain(
        `<string>${home}/.local/bin/ec</string><string>executor</string><string>serve</string>`
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
      env: { ...env, EXECUTOR_RESTART_TIMEOUT: undefined },
    });
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout.trim().split("\n")).toEqual([
      `EXECUTOR_API_KEY=${key}`,
      "EXECUTOR_BROWSER_ORIGIN=https://mcp.example.test:4312",
      `EXECUTOR_ENCRYPTION_KEY=${"ab".repeat(32)}`,
      "EXECUTOR_NO_UPDATE_CHECK=1",
      "EXECUTOR_PORT=4312",
    ]);
  });
});
