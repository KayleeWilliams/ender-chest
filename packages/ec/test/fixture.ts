import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const cliRoot = fileURLToPath(new URL("..", import.meta.url));
export const workspaceRoot = fileURLToPath(
  new URL("../../..", import.meta.url)
);

export const filePermissions = (file: string): number =>
  // oxlint-disable-next-line eslint/no-bitwise -- Extract POSIX permissions without file type flags.
  statSync(file).mode & 0o777;

interface Options {
  repo: string;
  home: string;
  profile: string;
  goos: string;
  push: boolean;
  dryRun: boolean;
  verifyOnly: boolean;
  skipPackages: boolean;
  updateSkills: boolean;
}

export interface Fixture {
  repo: string;
  home: string;
}

export const makeOpts = (
  repo: string,
  home: string,
  extra: Partial<Options> = {}
): Options => ({
  dryRun: extra.dryRun ?? false,
  goos: extra.goos ?? process.platform,
  home,
  profile: extra.profile ?? "mac",
  push: extra.push ?? false,
  repo,
  skipPackages: extra.skipPackages ?? true,
  updateSkills: extra.updateSkills ?? false,
  verifyOnly: extra.verifyOnly ?? false,
});

export const makeFixture = (prefix = "ender"): Fixture => {
  const root = mkdtempSync(path.join(tmpdir(), `${prefix}-`));
  return { home: path.join(root, "home"), repo: path.join(root, "repo") };
};

export const write = (root: string, rel: string, body: string): string => {
  const dest = path.join(root, rel);
  mkdirSync(path.dirname(dest), { recursive: true });
  writeFileSync(dest, body);
  return dest;
};

export const writeSourceRepo = (repo: string): void => {
  for (const [rel, asset] of [
    [".local/bin/cliproxy", "cliproxy"],
    [".local/bin/desktop", "desktop"],
    [".local/lib/desktop/unlock-wallet.py", "unlock-wallet.py"],
  ]) {
    write(
      repo,
      `home/${rel}`,
      readFileSync(new URL(`assets/${asset}`, import.meta.url), "utf-8")
    );
  }
  write(
    repo,
    "home/.config/desktop/config.json",
    JSON.stringify({
      host: "desktop.test",
      mac: "02:00:00:00:00:01",
      relay: "relay.test",
      sshUser: "user",
    })
  );
  write(
    repo,
    "home/.config/cliproxyapi/client.json",
    JSON.stringify({ baseURL: "http://proxy.test:8317" })
  );
  write(
    repo,
    "home/.gitconfig",
    "[rerere]\n\tenabled = true\n[include]\n\tpath = .gitconfig.local\n"
  );
  write(repo, "home/.zshrc", 'eval "$(fnm env --use-on-cd --shell zsh)"\n');
  write(repo, "home/.zprofile", 'export PATH="$HOME/.local/bin:$PATH"\n');
  write(repo, "home/.config/git/ignore", "**/.claude/settings.local.json\n");
  write(repo, "home/.config/shell/macos.zsh", 'export EDITOR="zed --wait"\n');
  write(
    repo,
    "home/.config/shell/macos.zprofile",
    'source "$HOME/.orbstack/shell/init.zsh" 2>/dev/null || :\n'
  );
  write(repo, "home/.config/zed/settings.json", "{}\n");
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
  write(
    repo,
    "agents/shared/mcp.toml",
    '[mcp_servers.executor]\nurl = "https://example.test/mcp"\n'
  );
  write(repo, "git/gitconfig.local.example", "# local git\n");
  write(repo, "git/identity.work.example", "# work\n");
  write(repo, "shell/zshrc.local.example", "# zshrc local\n");
  write(repo, "tools/ssh/config.local.example", "# ssh local\n");
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

export const removeFixture = (root: string): void => {
  rmSync(root, { force: true, recursive: true });
};

export const applyNative = (opts: Options): void => {
  const result = spawnSync(
    path.join(cliRoot, "zig-out/bin/ec"),
    ["sync", "--repo", opts.repo, "--skip-packages", "--profile", opts.profile],
    { encoding: "utf-8", env: { ...process.env, HOME: opts.home } }
  );
  if (result.status !== 0) {
    throw new Error(result.stdout + result.stderr);
  }
};
export const harvestNative = (opts: Options): void => {
  const result = spawnSync(
    path.join(cliRoot, "zig-out/bin/ec"),
    ["push", "--repo", opts.repo, "--dry-run"],
    { encoding: "utf-8", env: { ...process.env, HOME: opts.home } }
  );
  if (result.status !== 0) {
    throw new Error(result.stdout + result.stderr);
  }
};
