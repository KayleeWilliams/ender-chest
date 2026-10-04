import { execFile, spawnSync } from "node:child_process";
import { once } from "node:events";
import { chmodSync, existsSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import path from "node:path";
import { promisify } from "node:util";

import { parse as toml } from "smol-toml";
import { afterEach, describe, expect, it } from "vitest";

import {
  cliRoot,
  filePermissions,
  applyNative as applyHome,
  harvestNative as harvestHome,
  gitInit,
  makeFixture,
  makeOpts,
  removeFixture,
  write,
  writeSourceRepo,
} from "./fixture.ts";

const roots: string[] = [];
const servers: Server[] = [];
afterEach(async () => {
  await Promise.all(
    servers.splice(0).map((server) => server[Symbol.asyncDispose]())
  );
  for (const root of roots.splice(0)) {
    removeFixture(root);
  }
});

const ec = path.join(cliRoot, "zig-out/bin/ec");

const setup = (goos = "linux") => {
  const { repo, home } = makeFixture("ender-cliproxy");
  roots.push(path.dirname(repo));
  writeSourceRepo(repo);
  write(
    home,
    ".config/ender-chest/secrets/cliproxyapi.json",
    JSON.stringify({ apiKey: "test-client-key" })
  );
  chmodSync(
    path.join(home, ".config/ender-chest/secrets/cliproxyapi.json"),
    0o600
  );
  gitInit(repo);
  const opts = makeOpts(repo, home, { goos });
  applyHome(opts);
  const script = path.join(home, ".local/bin/cliproxy");
  const keyFile = path.join(
    home,
    ".config/ender-chest/secrets/cliproxyapi.json"
  );
  const env = {
    ...process.env,
    CLIPROXY_BASE_URL: "http://proxy.test:8317",
    HOME: home,
  };
  const run = (args: string[]) =>
    spawnSync(ec, ["cliproxy", ...args], { encoding: "utf-8", env });
  return { env, home, keyFile, opts, repo, run, script };
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

describe("CLIProxyAPI client", () => {
  it.each(["linux", "darwin"])(
    "keeps the client key local on %s while preserving host credentials",
    (goos) => {
      const { repo, home, opts, script, keyFile } = setup(goos);
      const auth = write(
        home,
        ".cli-proxy-api/auth/provider.json",
        '{"token":"private-oauth"}\n'
      );
      const config = write(
        home,
        ".cli-proxy-api/config.yaml",
        "api-keys: [private-client]\n"
      );
      applyHome(opts);
      harvestHome(opts);
      expect(filePermissions(script)).toBe(0o755);
      expect(filePermissions(keyFile)).toBe(0o600);
      expect(JSON.parse(readFileSync(keyFile, "utf-8")).apiKey).toBe(
        "test-client-key"
      );
      expect(readFileSync(auth, "utf-8")).toContain("private-oauth");
      expect(readFileSync(config, "utf-8")).toContain("private-client");
      expect(
        JSON.parse(
          readFileSync(
            path.join(repo, "home/.config/cliproxyapi/client.json"),
            "utf-8"
          )
        )
      ).toEqual({ baseURL: "http://proxy.test:8317" });
      expect(
        existsSync(path.join(repo, "home/.config/ender-chest/secrets"))
      ).toBe(false);
      expect(existsSync(path.join(repo, "home/.cli-proxy-api"))).toBe(false);
    }
  );

  it.each(["linux", "darwin"])(
    "applies the shared HTTPS endpoint to every client on %s",
    (goos) => {
      const { repo, home, opts, script, env } = setup(goos);
      const baseURL = "https://proxy.example.test:8317";
      write(
        repo,
        "home/.config/cliproxyapi/client.json",
        JSON.stringify({ baseURL })
      );
      applyHome(opts);

      const expectedBaseURL = "https://proxy.example.test:8317";
      const expectedApiURL = `${expectedBaseURL}/v1`;
      const claude = JSON.parse(
        readFileSync(path.join(home, ".claude/settings.json"), "utf-8")
      );
      const codex = toml(
        readFileSync(path.join(home, ".codex/config.toml"), "utf-8")
      );
      const grok = toml(
        readFileSync(path.join(home, ".grok/config.toml"), "utf-8")
      );
      expect(claude.env.ANTHROPIC_BASE_URL).toBe(expectedBaseURL);
      expect(codex).toHaveProperty(
        "model_providers.cliproxyapi.base_url",
        expectedApiURL
      );
      for (const model of ["grok-4.7", "grok-4.6", "grok-4.5"]) {
        expect(grok.model).toHaveProperty([model, "base_url"], expectedApiURL);
      }
      // The old cliproxy command forwards to the installed ec.
      const result = spawnSync(script, ["url"], {
        encoding: "utf-8",
        env: { ...env, CLIPROXY_BASE_URL: "" },
      });
      expect(result.status, result.stderr).toBe(0);
      expect(result.stdout.trim()).toBe(expectedApiURL);
    }
  );

  it("prints the base URL without leaking credentials", () => {
    const { run } = setup();
    expect(run(["url"]).stdout.trim()).toBe("http://proxy.test:8317/v1");
    expect(run(["run"]).status).toBe(2);
  });

  it("passes endpoint, key, and literal arguments only to the requested command", () => {
    const { run, env } = setup();
    const result = run([
      "run",
      process.execPath,
      "-e",
      "console.log(JSON.stringify([process.env.OPENAI_BASE_URL, process.env.OPENAI_API_KEY, process.argv.slice(1)]))",
      "literal $(echo nope)",
      "--json",
      "--help",
    ]);
    expect(result.status, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual([
      "http://proxy.test:8317/v1",
      "test-client-key",
      ["literal $(echo nope)", "--json", "--help"],
    ]);
    expect(env).not.toHaveProperty("OPENAI_API_KEY", "test-client-key");
  });

  it("authenticates model discovery and reports HTTP failures", async () => {
    const { env } = setup();
    const requests: { url?: string; authorization?: string }[] = [];
    let status = 200;
    const url = await listen((req, res) => {
      requests.push({ authorization: req.headers.authorization, url: req.url });
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ data: [{ id: "z-model" }, { id: "a-model" }] }));
    });
    const options = { env: { ...env, CLIPROXY_BASE_URL: `${url}/` } };
    const result = await promisify(execFile)(
      ec,
      ["cliproxy", "models", "--json"],
      options
    );
    expect(JSON.parse(result.stdout).data.models).toEqual([
      "a-model",
      "z-model",
    ]);
    expect(requests).toEqual([
      { authorization: "Bearer test-client-key", url: "/v1/models" },
    ]);
    status = 401;
    await expect(
      promisify(execFile)(ec, ["cliproxy", "models"], options)
    ).rejects.toMatchObject({
      code: 1,
      stderr: expect.stringContaining("rejected the client key"),
    });
  });

  // Fake launchctl and ssh record their arguments. FAIL_KICKSTART makes kickstart fail like an unloaded agent.
  const restartSetup = async (onHost: boolean) => {
    const { home, env } = setup("darwin");
    let status = 200;
    const url = await listen((req, res) => {
      res.writeHead(
        req.headers.authorization === "Bearer test-client-key" ? status : 401
      );
      res.end("{}");
    });
    if (onHost) {
      write(home, "Library/LaunchAgents/io.cliproxyapi.plist", "<plist/>");
    }
    const bin = path.join(home, "fake-bin");
    const calls = path.join(home, "calls.log");
    for (const name of ["launchctl", "ssh"]) {
      write(
        home,
        `fake-bin/${name}`,
        `#!/bin/sh\necho "${name} $*" >> "${calls}"\n[ "$1" = kickstart ] && [ -n "$FAIL_KICKSTART" ] && exit 113\nexit 0\n`
      );
      chmodSync(path.join(bin, name), 0o755);
    }
    const base = {
      ...env,
      CLIPROXY_BASE_URL: url,
      CLIPROXY_LOCAL_URL: url,
      CLIPROXY_RESTART_TIMEOUT: "2",
      PATH: `${bin}:${process.env.PATH}`,
    };
    const restart = (extra: Record<string, string> = {}) =>
      promisify(execFile)(ec, ["cliproxy", "restart"], {
        env: { ...base, ...extra },
      });
    const takeCalls = () => {
      const text = readFileSync(calls, "utf-8");
      rmSync(calls);
      return text;
    };
    return {
      home,
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

  it("restarts the proxy on its host over SSH from other machines", async () => {
    const { restart, takeCalls } = await restartSetup(false);
    const result = await restart();
    expect(result.stdout).toContain("CLIProxyAPI restarted on 127.0.0.1");
    expect(takeCalls()).toBe(
      'ssh -o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 127.0.0.1 "$HOME/.local/bin/ec" cliproxy restart\n'
    );
  });
});
