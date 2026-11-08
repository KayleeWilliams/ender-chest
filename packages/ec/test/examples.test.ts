import { spawnSync } from "node:child_process";
import {
  appendFileSync,
  cpSync,
  existsSync,
  readdirSync,
  readFileSync,
} from "node:fs";
import path from "node:path";

import { parse as toml } from "smol-toml";
import { describe, expect, it } from "vitest";

import { cliRoot, gitInit, pluginFixture, workspaceRoot } from "./fixture.ts";

const example = path.join(workspaceRoot, "examples/config");
const pluginDocs = path.join(workspaceRoot, "docs/plugins.md");
const scheme = /^[a-z]+:/u;

// The example as a committed checkout, with a temporary HOME.
const starter = () => {
  const f = pluginFixture("");
  cpSync(example, f.repo, { recursive: true });
  gitInit(f.repo);
  const git = (...args: string[]) => {
    const r = spawnSync("git", args, { cwd: f.repo, encoding: "utf-8" });
    expect(r.status, r.stderr).toBe(0);
    return r.stdout;
  };
  git("add", ".");
  git("commit", "-q", "-m", "Example");
  const ok = (...args: string[]) => {
    const r = f.run(args);
    expect(r.status, r.stdout + r.stderr).toBe(0);
    return r.stdout;
  };
  return { ...f, git, ok };
};

interface Setting {
  type?: string;
}
interface BuiltinManifest {
  settings?: Record<string, Setting>;
}

// The built-in plugins, from the manifests ec embeds.
const builtins = readdirSync(path.join(cliRoot, "src/plugins"))
  .filter((file) => file.endsWith(".toml"))
  .map((file) => {
    const text = readFileSync(path.join(cliRoot, "src/plugins", file), "utf-8");
    // SAFETY: A built-in manifest is a TOML table whose settings are tables with an optional type.
    const manifest = toml(text) as BuiltinManifest;
    return { manifest, name: path.basename(file, ".toml") };
  });

const markdownFiles = (dir: string): string[] =>
  readdirSync(dir, { encoding: "utf-8", recursive: true })
    .filter((rel) => rel.endsWith(".md"))
    .map((rel) => path.join(dir, rel));

// Maps a link to a path in this repository, or null for a link to somewhere else.
const linkedPath = (from: string, link: string): string | null => {
  const target = link.split("#")[0] ?? "";
  for (const prefix of [
    "https://github.com/KayleeWilliams/ender-chest/blob/main/",
    "https://github.com/KayleeWilliams/ender-chest/tree/main/",
    "https://raw.githubusercontent.com/KayleeWilliams/ender-chest/main/",
  ]) {
    if (target.startsWith(prefix)) {
      return path.join(workspaceRoot, target.slice(prefix.length));
    }
  }
  if (target === "" || scheme.test(target)) {
    return null;
  }
  return path.resolve(path.dirname(from), target);
};

describe("config example", () => {
  it("applies, verifies, and captures back without changing the checkout", () => {
    const f = starter();
    f.ok("sync", "--skip-packages");
    f.ok("verify");
    f.ok("push", "--dry-run");
    expect(f.git("status", "--porcelain")).toBe("");
  });

  it("is documented for every built-in plugin with settings ec accepts", () => {
    const f = starter();
    const names = builtins.map((b) => b.name);
    const documented: string[] = [];
    const blocks = readFileSync(pluginDocs, "utf-8").matchAll(
      /```toml\n(?<block>[\s\S]*?)```/gu
    );
    for (const match of blocks) {
      const block = match.groups?.block ?? "";
      // SAFETY: [plugins.NAME] tables parse to a table of setting tables.
      const config = toml(block) as { plugins?: Record<string, Setting> };
      const tables = Object.keys(config.plugins ?? {});
      const shown = tables.filter((name) => names.includes(name));
      if (shown.length > 0) {
        documented.push(...shown);
        appendFileSync(path.join(f.repo, "ender-chest.toml"), `\n${block}`);
      }
    }
    expect(documented.toSorted()).toEqual(names.toSorted());

    // SAFETY: ec plugin list --json reports each plugin's name and missing settings.
    const listed = JSON.parse(f.ok("plugin", "list", "--json")).data
      .plugins as { name: string; missing: string[] }[];
    expect(listed.map((p) => p.name).toSorted()).toEqual(names.toSorted());
    // Only secrets, which each machine stores with ec secret set, have no value.
    const secrets = builtins.flatMap(({ manifest, name }) =>
      Object.entries(manifest.settings ?? {})
        .filter(([, setting]) => setting.type === "secret")
        .map(([setting]) => `${name}.${setting}`)
    );
    const missing = listed.flatMap((p) =>
      p.missing.map((m) => `${p.name}.${m}`)
    );
    expect(missing.toSorted()).toEqual(secrets.toSorted());
  });

  it("links only to files that exist, and stays self-contained", () => {
    const docs = [
      ...markdownFiles(path.join(workspaceRoot, "examples")),
      ...markdownFiles(path.join(workspaceRoot, "docs")),
      ...["README.md", "SECURITY.md", "AGENTS.md"].map((file) =>
        path.join(workspaceRoot, file)
      ),
    ];
    const broken: string[] = [];
    for (const file of docs) {
      const text = readFileSync(file, "utf-8");
      for (const match of text.matchAll(/\]\((?<link>[^)\s]+)\)/gu)) {
        const link = match.groups?.link ?? "";
        const target = linkedPath(file, link);
        const relative = scheme.test(link) ? null : target;
        const escapes =
          file.startsWith(example) &&
          relative !== null &&
          !relative.startsWith(example);
        if ((target !== null && !existsSync(target)) || escapes) {
          broken.push(`${path.relative(workspaceRoot, file)}: ${link}`);
        }
      }
    }
    expect(broken).toEqual([]);
  });
});
