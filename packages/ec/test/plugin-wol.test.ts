import { execFile } from "node:child_process";
import { createSocket } from "node:dgram";
import type { Socket } from "node:dgram";
import { once } from "node:events";
import { mkdirSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";

import { afterEach, describe, expect, it } from "vitest";

import { ec, pluginFixture, write } from "./fixture.ts";

const exec = promisify(execFile);
const roots: string[] = [];
const sockets: Socket[] = [];
afterEach(() => {
  for (const s of sockets.splice(0)) {
    s.close();
  }
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

// 127.0.0.1 reaches the test receiver and is never a LAN broadcast address, so wake
// uses the relay unless --local is set.
type Settings = Record<string, string | number>;
const settings = (extra: Settings = {}) =>
  `[plugins.wol]\n${Object.entries({
    broadcast: "127.0.0.1",
    host: "desktop.example.test",
    mac: "00:00:5e:00:53:01",
    relay: "relay.example.test",
    ...extra,
  })
    // JSON strings and numbers are valid TOML values.
    .map(([k, v]) => `${k} = ${JSON.stringify(v)}`)
    .join("\n")}\n`;
const wol = (extra: Settings = {}) => {
  const f = pluginFixture(settings(extra));
  roots.push(f.root);
  return f;
};
const receiver = async () => {
  const socket = createSocket("udp4");
  sockets.push(socket);
  socket.bind(0, "127.0.0.1");
  await once(socket, "listening");
  return { message: once(socket, "message"), port: socket.address().port };
};
// Fake ping answers from a script of exit codes, one per call, repeating the last.
const pings = (f: ReturnType<typeof wol>, codes: number[]) => {
  const count = path.join(f.root, "pings");
  return f.fake(
    "ping",
    `const fs=require('node:fs'),f=${JSON.stringify(count)},c=${JSON.stringify(codes)};const n=fs.existsSync(f)?+fs.readFileSync(f,'utf8'):0;fs.writeFileSync(f,String(n+1));process.exit(c[Math.min(n,c.length-1)]);`
  );
};

describe("wol plugin", () => {
  it("sends a real 102-byte UDP magic packet with no runtime on PATH", async () => {
    const { port, message } = await receiver();
    const f = wol({ port });
    const r = await exec(
      ec,
      ["wol", "wake", "--local", "--no-wait", "--json"],
      {
        env: { ...f.env, PATH: "/nonexistent" },
      }
    );
    const [packet] = await message;
    expect(packet).toEqual(
      Buffer.from("ff".repeat(6) + "00005e005301".repeat(16), "hex")
    );
    expect(JSON.parse(r.stdout)).toMatchObject({
      command: "wol wake",
      ok: true,
    });
    expect(r.stdout).not.toContain("is reachable");
  });

  it("relays through the relay's installed ec with a minimal SSH PATH", async () => {
    const { port, message } = await receiver();
    const relay = wol({ port });
    mkdirSync(path.join(relay.home, ".local/bin"), { recursive: true });
    symlinkSync(ec, path.join(relay.home, ".local/bin/ec"));
    write(relay.home, ".config/ender-chest/repo", `${relay.repo}\n`);
    const client = wol();
    const log = path.join(client.root, "ssh.json");
    const env = client.fake(
      "ssh",
      `const fs=require('node:fs'),cp=require('node:child_process'),a=process.argv.slice(2);fs.writeFileSync(${JSON.stringify(log)},JSON.stringify(a));const r=cp.spawnSync('/bin/sh',['-c',a.at(-1)],{env:{HOME:${JSON.stringify(relay.home)},PATH:'/usr/bin:/bin'},stdio:'inherit'});process.exit(r.status??1);`
    );
    const result = await exec(ec, ["wol", "wake", "--no-wait", "--json"], {
      env: { ...client.env, ...env },
    });
    const [packet] = await message;
    expect(packet.length).toBe(102);
    expect(JSON.parse(readFileSync(log, "utf-8"))).toEqual([
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=8",
      "-o",
      "ConnectionAttempts=1",
      "relay.example.test",
      '"$HOME/.local/bin/ec" wol wake --local --no-wait',
    ]);
    expect(JSON.parse(result.stdout).ok).toBe(true);
  });

  it("prefers --via over the relay setting and reports relay failures as JSON", () => {
    const f = wol();
    const r = f.run(
      [
        "wol",
        "wake",
        "--via",
        "other@relay.example.test",
        "--no-wait",
        "--json",
      ],
      f.fake(
        "ssh",
        "console.error(process.argv.slice(2).join(' '));process.exit(255)"
      )
    );
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout)).toMatchObject({ ok: false });
    expect(JSON.parse(r.stdout).message).toContain(
      "Cannot SSH to the wake relay"
    );
    expect(r.stderr).toContain("other@relay.example.test");
    expect(r.stderr).not.toContain(" relay.example.test");
  });

  it("refuses --local with --via as a usage error", () => {
    const f = wol();
    const r = f.run([
      "wol",
      "wake",
      "--local",
      "--via",
      "relay.example.test",
      "--json",
    ]);
    expect(r.status).toBe(2);
    expect(JSON.parse(r.stdout).error.code).toBe("usage_error");
  });

  it.each(["-oProxyCommand=bad", "host;echo bad", "$(echo bad)"])(
    "rejects unsafe relay %s",
    (relay) => {
      const f = wol();
      const r = f.run(["wol", "wake", "--via", relay, "--no-wait", "--json"]);
      expect(r.status).toBe(1);
      expect(JSON.parse(r.stdout).message).toContain("Invalid wake relay");
    }
  );

  it.each<Settings>([
    { mac: "00:00:5e:00:53" },
    { broadcast: "host.example.test" },
    { port: 0 },
    { port: 65_536 },
  ])("rejects bad wake settings %j", (change) => {
    const f = wol(change);
    const r = f.run(["wol", "wake", "--local", "--no-wait", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain("Invalid");
  });

  it("rejects a port that is not an integer before the plugin runs", () => {
    const f = wol({ port: 1.5 });
    const r = f.run(["wol", "wake", "--local", "--no-wait"]);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain("unsupported value for port");
  });

  it.each([0, 1])(
    "reports reachability without asserting power state: %d",
    (code) => {
      const f = wol();
      const r = f.run(
        ["wol", "status", "--json"],
        f.fake("ping", `process.exit(${code})`)
      );
      expect(r.status).toBe(code);
      const result = JSON.parse(r.stdout);
      expect(result).toMatchObject({ command: "wol status", ok: code === 0 });
      if (code) {
        expect(result.message).toContain("disconnected from Tailscale");
        expect(result.error.code).toBe("unreachable");
      } else {
        expect(result.error).toBeNull();
      }
    }
  );

  it("times out even if ping closes both output streams before hanging", () => {
    const f = wol();
    const env = f.fake(
      "ping",
      "const fs=require('node:fs');fs.closeSync(1);fs.closeSync(2);setTimeout(()=>{},20000)"
    );
    const start = Date.now();
    const r = f.run(["wol", "status", "--json"], env);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain("not reachable");
    expect(Date.now() - start).toBeLessThan(10_000);
  }, 12_000);

  it("fails before running when a required setting is missing", () => {
    const f = wol();
    f.configure(
      '[plugins.wol]\nmac = "00:00:5e:00:53:01"\nbroadcast = "127.0.0.1"\n'
    );
    const r = f.run(["wol", "status", "--json"]);
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain("needs host");
  });

  it("wakes, waits until the machine answers, and reports it awake", async () => {
    const { port, message } = await receiver();
    const f = wol({ port });
    const r = await exec(ec, ["wol", "wake", "--local", "--json"], {
      env: { ...f.env, ...pings(f, [1, 1, 0]) },
    });
    const [packet] = await message;
    expect(packet.length).toBe(102);
    expect(JSON.parse(r.stdout)).toMatchObject({
      command: "wol wake",
      message: "desktop.example.test is awake.",
      ok: true,
    });
    expect(r.stderr).toContain("Waiting up to 180s");
  }, 15_000);

  it("reports unreachable when the machine never answers", () => {
    const f = wol({ port: 9, wait_seconds: 1 });
    const r = f.run(["wol", "wake", "--local", "--json"], pings(f, [1]));
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout)).toMatchObject({
      error: { code: "unreachable" },
      ok: false,
    });
    expect(JSON.parse(r.stdout).message).toContain("did not respond within 1s");
  });

  // wol status stands in for kde unlock, so this runs on any OS.
  it("skips the packet when the machine is awake, then runs after_wake with stdout on stderr", () => {
    const f = wol({ after_wake: "wol status" });
    const log = path.join(f.root, "ssh.log");
    const env = {
      ...pings(f, [0]),
      ...f.fake(
        "ssh",
        `require('node:fs').writeFileSync(${JSON.stringify(log)},'called')`
      ),
    };
    const r = f.run(["wol", "wake", "--json"], env);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout.trim().split("\n")).toHaveLength(1);
    expect(JSON.parse(r.stdout)).toMatchObject({
      message: "desktop.example.test is already awake.",
      ok: true,
    });
    expect(r.stderr).toContain("Running ec wol status");
    expect(r.stderr).toContain("desktop.example.test is reachable.");
    expect(() => readFileSync(log)).toThrow();
  });

  it("fails when after_wake fails, and --skip-after skips it", () => {
    const f = wol({ after_wake: "wol status" });
    const failed = f.run(["wol", "wake", "--json"], pings(f, [0, 1]));
    expect(failed.status).toBe(1);
    expect(JSON.parse(failed.stdout).message).toContain("ec wol status failed");
    const skipped = wol({ after_wake: "wol status" });
    const r = skipped.run(
      ["wol", "wake", "--skip-after", "--json"],
      pings(skipped, [0, 1])
    );
    expect(r.status, r.stderr).toBe(0);
    expect(r.stderr).not.toContain("Running ec");
  });
});
