import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { parse as toml } from "smol-toml";
import { afterEach, describe, expect, it } from "vitest";

import {
  cliRoot,
  filePermissions,
  gitInit,
  workspaceRoot,
  write,
} from "./fixture.ts";

const executable = path.join(cliRoot, "zig-out/bin/ec");
const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

const starter = () => {
  const root = mkdtempSync(path.join(tmpdir(), "ec-example-"));
  roots.push(root);
  const repo = path.join(root, "repo");
  const home = path.join(root, "home");
  cpSync(path.join(workspaceRoot, "examples/config"), repo, {
    recursive: true,
  });
  mkdirSync(home);
  gitInit(repo);
  const env = {
    EC_NO_UPDATE: "1",
    EC_REPO: repo,
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_TERMINAL_PROMPT: "0",
    HOME: home,
    PATH: process.env.PATH,
  };
  const run = (args: string[], input?: string) =>
    spawnSync(executable, args, {
      cwd: root,
      encoding: "utf-8",
      env,
      input,
      timeout: 15_000,
    });
  const sync = () => {
    const result = run(["sync", "--skip-packages", "--json"]);
    expect(result.status, result.stdout + result.stderr).toBe(0);
  };
  return { home, repo, run, sync };
};

describe("config starter", () => {
  it.each([false, true])(
    "installs the shipped instructions, preferences, and skill with local proxy setup=%s",
    (withProxy) => {
      const f = starter();
      const token = "fixture-example-device-token";
      if (withProxy) {
        const setup = f.run(
          [
            "cliproxy",
            "setup",
            "--url",
            "https://proxy.example.test:8317",
            "--key-stdin",
            "--json",
          ],
          `${token}\n`
        );
        expect(setup.status, setup.stderr).toBe(0);
        expect(setup.stdout + setup.stderr).not.toContain(token);
      }
      f.sync();

      const instructions = readFileSync(
        path.join(f.repo, "agents/shared/AGENTS.md"),
        "utf-8"
      );
      for (const rel of [
        ".claude/CLAUDE.md",
        ".codex/AGENTS.md",
        ".grok/AGENTS.md",
      ]) {
        expect(readFileSync(path.join(f.home, rel), "utf-8")).toBe(
          instructions
        );
      }
      const skill = path.join(f.home, ".agents/skills/review-changes");
      expect(readFileSync(path.join(skill, "SKILL.md"), "utf-8")).toBe(
        readFileSync(
          path.join(f.repo, "skills/review-changes/SKILL.md"),
          "utf-8"
        )
      );
      for (const agent of [".claude", ".codex", ".grok"]) {
        expect(
          readlinkSync(path.join(f.home, agent, "skills/review-changes"))
        ).toBe(skill);
      }

      const claude = JSON.parse(
        readFileSync(path.join(f.home, ".claude/settings.json"), "utf-8")
      );
      const codex = toml(
        readFileSync(path.join(f.home, ".codex/config.toml"), "utf-8")
      );
      const grok = toml(
        readFileSync(path.join(f.home, ".grok/config.toml"), "utf-8")
      );
      expect(claude).toMatchObject({
        attribution: { commit: "", pr: "", sessionUrl: false },
        permissions: { defaultMode: "acceptEdits" },
      });
      expect(codex).toMatchObject({
        approval_policy: "on-request",
        sandbox_mode: "workspace-write",
        tui: { notifications: true },
        web_search: "cached",
      });
      expect(grok).toMatchObject({
        cli: { auto_update: true },
        ui: { compact_mode: false, max_thoughts_width: 120 },
      });
      expect(existsSync(path.join(f.home, ".claude.json"))).toBe(false);
      expect(codex).not.toHaveProperty("mcp_servers.executor");
      expect(grok).not.toHaveProperty("mcp_servers.executor");
      const secret = path.join(
        f.home,
        ".config/ender-chest/secrets/cliproxyapi.json"
      );
      if (withProxy) {
        expect(claude.env.ANTHROPIC_AUTH_TOKEN).toBe(token);
        expect(codex).toHaveProperty(
          "model_providers.cliproxyapi.experimental_bearer_token",
          token
        );
        expect(filePermissions(secret)).toBe(0o600);
      } else {
        expect(existsSync(secret)).toBe(false);
        expect(claude.env).not.toHaveProperty("ANTHROPIC_AUTH_TOKEN");
        expect(codex).not.toHaveProperty("model_provider");
        expect(grok).not.toHaveProperty("model");
      }

      const verified = f.run(["verify", "--json"]);
      expect(verified.status, verified.stdout + verified.stderr).toBe(0);
      const captured = f.run(["push", "--dry-run", "--json"]);
      expect(captured.status, captured.stdout + captured.stderr).toBe(0);
      expect(captured.stdout + captured.stderr).not.toContain(token);
      expect(
        JSON.parse(
          readFileSync(
            path.join(f.repo, "home/.config/cliproxyapi/client.json"),
            "utf-8"
          )
        )
      ).toEqual({ baseURL: "https://proxy.example.test:8317" });
      for (const rel of [
        "home/.config/ender-chest/secrets",
        "home/.claude",
        "home/.codex",
        "home/.grok",
      ]) {
        expect(existsSync(path.join(f.repo, rel))).toBe(false);
      }
    }
  );

  it("merges Claude defaults but preserves existing Codex, Grok, and device overrides across syncs", () => {
    const f = starter();
    write(
      f.home,
      ".claude/settings.json",
      JSON.stringify({
        cleanupPeriodDays: 7,
        env: { EDITOR: "vim" },
        permissions: { defaultMode: "default" },
      })
    );
    write(
      f.home,
      ".codex/config.toml",
      'web_search = "disabled"\n[tui]\nnotifications = false\n'
    );
    write(
      f.home,
      ".grok/config.toml",
      "[cli]\nauto_update = false\n[ui]\nmax_thoughts_width = 80\n"
    );
    const local = write(
      f.home,
      ".gitconfig.local",
      "[user]\nname = Example Developer\nemail = developer@example.test\n"
    );
    const identity = readFileSync(local, "utf-8");

    for (let attempt = 0; attempt < 2; attempt += 1) {
      f.sync();
      expect(
        JSON.parse(
          readFileSync(path.join(f.home, ".claude/settings.json"), "utf-8")
        )
      ).toMatchObject({
        cleanupPeriodDays: 7,
        env: { EDITOR: "vim" },
        permissions: { defaultMode: "acceptEdits" },
      });
      expect(
        toml(readFileSync(path.join(f.home, ".codex/config.toml"), "utf-8"))
      ).toMatchObject({
        tui: { notifications: false },
        web_search: "disabled",
      });
      expect(
        toml(readFileSync(path.join(f.home, ".grok/config.toml"), "utf-8"))
      ).toMatchObject({
        cli: { auto_update: false },
        ui: { max_thoughts_width: 80 },
      });
      expect(readFileSync(local, "utf-8")).toBe(identity);
      expect(existsSync(path.join(f.repo, "home/.gitconfig.local"))).toBe(
        false
      );
    }
  });
});
