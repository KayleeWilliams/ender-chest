import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { pluginFixture } from "./fixture.ts";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

// Fake ps, git, lsof, readlink, kill, docker, and df describe a machine with stale dev
// servers, an agent, T3 Code's preview browser, and one container.
const quiet = () => {
  const f = pluginFixture("[plugins.quiet]\n");
  roots.push(f.root);
  const work = path.join(f.root, "work");
  mkdirSync(path.join(work, "app"), { recursive: true });
  const other = path.join(f.root, "other");
  mkdirSync(other, { recursive: true });
  const gone = path.join(f.root, "gone");
  const log = path.join(f.root, "calls.log");
  const killed = path.join(f.root, "killed");
  // pid -> working directory
  const cwds = {
    101: gone,
    102: other,
    103: other,
    104: path.join(work, "app"),
    105: other,
    106: other,
    108: other,
  };
  const ps = [
    "101 1 03:10:00 0.0 node /w/node_modules/next/dist/bin/next dev",
    "102 1 25:00 1.0 node /w/node_modules/vite/bin/vite.js",
    "103 1 1-02:00:00 0.5 /w/node_modules/@esbuild/darwin-arm64/bin/esbuild --service=0.28.1 --ping",
    "104 1 05:00:00 2.0 node /w/node_modules/.bin/storybook dev -p 6006",
    "105 1 09:00:00 80.0 node /opt/homebrew/bin/claude --resume",
    "106 107 09:00:00 3.0 /home/user/.t3/tools/chrome-headless-shell/linux64/154/chrome-headless-shell --headless",
    "107 1 09:00:00 4.0 /home/user/.t3/runtime/versions/0.0.46/t3 serve",
    "108 1 05:00:00 0.1 node /w/node_modules/next/dist/server/lib/start-server.js",
    "200 1 02:00:00 55.0 /Applications/Browser.app/Contents/MacOS/Browser --type=renderer",
  ].join("\n");
  const record = `const fs=require('node:fs');fs.appendFileSync(${JSON.stringify(log)},require('node:path').basename(process.argv[1])+' '+process.argv.slice(2).join(' ')+"\\n");`;
  const env = {
    ...f.fake("ps", `console.log(${JSON.stringify(ps)})`),
    ...f.fake("git", `console.log(${JSON.stringify(work)})`),
    ...f.fake(
      "lsof",
      `const m=${JSON.stringify(cwds)};for(const p of process.argv.at(-1).split(','))if(m[p])console.log('p'+p+'\\nfcwd\\nn'+m[p])`
    ),
    ...f.fake(
      "readlink",
      `const m=${JSON.stringify(cwds)};const p=process.argv[2].split('/')[2];if(!m[p])process.exit(1);console.log(m[p]+(m[p]===${JSON.stringify(gone)}?' (deleted)':''))`
    ),
    ...f.fake(
      "kill",
      `${record}const a=process.argv.slice(2);if(a[0]==='-0')process.exit(fs.existsSync(${JSON.stringify(killed)})?1:0);fs.writeFileSync(${JSON.stringify(killed)},'1')`
    ),
    ...f.fake(
      "docker",
      `${record}if(process.argv[2]==='ps')console.log('abc123\\tapp-postgres-1')`
    ),
    ...f.fake(
      "df",
      "console.log('Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/disk 999 1 125829120 1% /')"
    ),
  };
  return { log, run: (args: string[]) => f.run(args, env) };
};

describe("quiet plugin", () => {
  it("lists stale dev processes and containers without stopping them on --dry-run", () => {
    const q = quiet();
    const r = q.run(["quiet", "--dry-run", "--json"]);
    expect(r.status, r.stderr).toBe(0);
    const result = JSON.parse(r.stdout);
    expect(result.command).toBe("quiet stop");
    expect(
      result.data.stopped.map((s: { pid: number; reason: string }) => [
        s.pid,
        s.reason,
      ])
    ).toEqual([
      [101, "worktree deleted"],
      [103, "running 26h00m"],
      [108, "running 5h00m"],
    ]);
    expect(result.data).toMatchObject({
      containers: [{ id: "abc123", name: "app-postgres-1" }],
      disk_free_gb: 120,
      dry_run: true,
      kept_in_worktree: 1,
      kept_recent: 1,
    });
    expect(result.data.busiest.map((b: { name: string }) => b.name)).toEqual([
      "node",
      "Browser",
    ]);
    expect(existsSync(q.log) ? readFileSync(q.log, "utf-8") : "").not.toMatch(
      /kill -TERM|docker stop/u
    );
  });

  it("stops stale processes, recent ones with --all, and running containers", () => {
    const q = quiet();
    const r = q.run(["quiet", "stop", "--all"]);
    expect(r.status, r.stderr).toBe(0);
    const calls = readFileSync(q.log, "utf-8");
    expect(calls).toContain("kill -TERM 101 102 103 108\n");
    expect(calls).not.toContain("-KILL");
    expect(calls).toContain("docker stop --time 10 abc123\n");
    expect(r.stdout).toContain("Stopped 4 dev process(es) and 1 container(s).");
    expect(r.stdout).toContain("Kept 1 in this worktree.");
  });
});
