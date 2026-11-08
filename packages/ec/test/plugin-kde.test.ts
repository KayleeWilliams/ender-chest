import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { pluginFixture } from "./fixture.ts";

const helper = readFileSync(
  new URL("../src/plugins/unlock-wallet.py", import.meta.url),
  "utf-8"
);
const kde = () =>
  pluginFixture(
    '[plugins.kde]\nhost = "user@desktop.example.test"\nwait_seconds = 2\n'
  );
// Fake ssh records its arguments and stdin, then runs `body`.
const ssh = (f: ReturnType<typeof kde>, body: string) => {
  const log = path.join(f.root, "ssh.json");
  const input = path.join(f.root, "ssh.stdin");
  const env = f.fake(
    "ssh",
    `const fs=require('node:fs');fs.writeFileSync(${JSON.stringify(log)},JSON.stringify(process.argv.slice(2)));let stdin='';try{stdin=fs.readFileSync(0,'utf8')}catch{}fs.writeFileSync(${JSON.stringify(input)},stdin);${body}`
  );
  return {
    // SAFETY: The fake ssh above writes its argv, an array of strings, as JSON.
    args: () => JSON.parse(readFileSync(log, "utf-8")) as string[],
    env,
    stdin: () => readFileSync(input, "utf-8"),
  };
};
const python = spawnSync("python3", ["--version"]).status === 0;

describe("kde plugin", () => {
  it("shuts down through KDE and waits until the machine is offline", () => {
    const f = kde();
    const s = ssh(f, "console.log('ready')");
    const r = f.run(["kde", "shutdown", "--json"], {
      ...s.env,
      ...f.pings([0, 0, 1]),
    });
    expect(r.status, r.stderr).toBe(0);
    expect(JSON.parse(r.stdout)).toMatchObject({
      command: "kde shutdown",
      message: "desktop.example.test is off.",
      ok: true,
    });
    const args = s.args();
    expect(args).toContain("user@desktop.example.test");
    expect(args).toContain("BatchMode=yes");
    expect(args.at(-1)).toContain("org.kde.Shutdown logoutAndShutdown");
    // ping gets the host, not USER@HOST.
    const pinged = readFileSync(path.join(f.root, "ping.log"), "utf-8")
      .trim()
      .split("\n");
    expect(pinged.length).toBeGreaterThan(0);
    expect(new Set(pinged)).toEqual(new Set(["desktop.example.test"]));
  }, 15_000);

  it("does not wait with --no-wait", () => {
    const f = kde();
    const s = ssh(f, "console.log('ready')");
    const r = f.run(["kde", "shutdown", "--no-wait", "--json"], {
      ...s.env,
      ...f.pings([0]),
    });
    expect(r.status, r.stderr).toBe(0);
    expect(JSON.parse(r.stdout).message).toBe("Shutdown requested.");
  });

  it("does not wait for shutdown when SSH never connects, and treats an offline machine as off", () => {
    const failed = kde();
    const r = failed.run(["kde", "shutdown", "--json"], {
      ...failed.pings([0]),
      ...failed.fake(
        "ssh",
        "console.error('Permission denied');process.exit(255)"
      ),
    });
    expect(r.status).toBe(1);
    expect(JSON.parse(r.stdout).message).toContain(
      "Cannot SSH to user@desktop.example.test"
    );
    const off = kde();
    const offline = off.run(["kde", "shutdown", "--json"], off.pings([1]));
    expect(offline.status).toBe(0);
    expect(JSON.parse(offline.stdout).message).toContain("already off");
  });

  it("refuses interactive unlock in JSON mode and conflicting options", () => {
    const f = kde();
    const setup = f.run(["kde", "unlock", "--setup", "--json"]);
    expect(setup.status).toBe(1);
    expect(JSON.parse(setup.stdout).message).toContain("cannot use --json");
    expect(JSON.parse(setup.stdout).error.code).toBe("interaction_required");
    const both = f.run(["kde", "unlock", "--setup", "--forget", "--json"]);
    expect(both.status).toBe(2);
    expect(JSON.parse(both.stdout).error.code).toBe("usage_error");
  });

  it.runIf(process.platform === "darwin")(
    "sends the embedded helper over SSH stdin and skips Keychain when the wallet is open",
    () => {
      const f = kde();
      const s = ssh(f, "console.log('unlocked')");
      const r = f.run(["kde", "unlock", "--json"], s.env);
      expect(r.status, r.stderr).toBe(0);
      expect(JSON.parse(r.stdout).message).toBe(
        "The wallet on user@desktop.example.test is already unlocked."
      );
      const args = s.args();
      expect(args).toContain("user@desktop.example.test");
      expect(args).toContain("BatchMode=yes");
      expect(args.at(-1)).toMatch(/^python3 -c '.*' --status$/u);
      // Byte length, then the helper. Nothing needs to be installed on the machine.
      expect(s.stdin()).toBe(`${Buffer.byteLength(helper)}\n${helper}`);
    }
  );

  it.runIf(process.platform === "darwin" && python)(
    "runs the helper through the stdin loader with its arguments",
    () => {
      const f = kde();
      // Run the remote command locally with the stdin ec sent.
      const env = f.fake(
        "ssh",
        "const r=require('node:child_process').spawnSync('/bin/sh',['-c',process.argv.at(-1)],{stdio:'inherit',env:{...process.env,XDG_RUNTIME_DIR:'/nonexistent'}});process.exit(r.status??1)"
      );
      const r = f.run(["kde", "unlock"], env);
      expect(r.status).toBe(1);
      // The helper parsed --status and reached its first runtime check.
      expect(r.stderr).toContain(
        "Wallet unlock failed: The desktop user session is not running yet."
      );
      expect(r.stderr).not.toContain("Usage");
    }
  );

  it.runIf(process.platform === "linux")(
    "points Linux users at --local for remote unlock",
    () => {
      const f = kde();
      const r = f.run(["kde", "unlock", "--json"]);
      expect(r.status).toBe(1);
      expect(JSON.parse(r.stdout).message).toContain("ec kde unlock --local");
    }
  );
});
