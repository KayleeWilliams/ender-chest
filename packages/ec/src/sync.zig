const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const C = core.Context;
const O = @import("options.zig").Options;
const skills = @import("skills.zig");
const manifest = @import("manifest.zig");
const eq = core.eql;
const plugin = @import("plugin.zig");
const config = @import("config.zig");
pub fn profile(c: *C, o: O) []const u8 {
    if (o.profile.len > 0) return o.profile;
    for ([_][]const u8{ "CODESPACES", "GITHUB_CODESPACE_TOKEN", "CODEX_CLOUD", "CLOUD_AGENT", "CI" }) |key| {
        if (c.env.get(key)) |v| if (v.len > 0) return "cloud";
    }
    return if (builtin.os.tag == .macos and !c.exists("/.dockerenv")) "mac" else "cloud";
}
pub fn resolveRepo(c: *C, o: O) !void {
    const configured = c.env.get("EC_REPO");
    const saved = try c.optional(try c.path(&.{ c.home, ".config/ender-chest/repo" }));
    const current = try std.process.currentPathAlloc(c.io, c.a);
    const explicit = o.repo != null or configured != null;
    const p = o.repo orelse configured orelse if (c.exists(try c.path(&.{ current, manifest.file_name }))) current else if (saved) |s| core.trim(s) else current;
    c.repo = try std.fs.path.resolve(c.a, &.{p});
    if (!explicit) c.repo = try primaryCheckout(c, c.repo);
    if (!c.exists(try c.path(&.{ c.repo, manifest.file_name }))) return c.fail("No ender-chest config checkout at {s}: it has no {s}. Use --repo PATH or set EC_REPO.", .{ c.repo, manifest.file_name });
}
pub fn run(c: *C, o: O) !void {
    try resolveRepo(c, o);
    const p = profile(c, o);
    try c.env.put("GIT_TERMINAL_PROMPT", "0");
    try c.env.put("GIT_PAGER", "cat");
    try c.env.put("EC_REPO", c.repo);
    switch (o.command) {
        .sync => {
            const already_pulled = c.env.get("EC_SYNC_PULLED");
            if (already_pulled == null or !eq(u8, already_pulled.?, c.repo)) try pull(c);
            _ = c.env.swapRemove("EC_SYNC_PULLED");
            try refreshBinary(c, o);
            const m = try manifest.load(c);
            const plugins = try plugin.loadAll(c, m, true);
            // Files first, so setup steps see them and installers that keep an existing
            // ~/.zshrc keep ours.
            try applyFiles(c, m, p);
            try packages(c, o, m, p);
            try config.apply(c, try plugin.contributions(c, plugins));
            try skills.apply(c, p, o.update_skills);
            try installBinary(c);
            try c.write(try c.path(&.{ c.home, ".config/ender-chest/repo" }), try c.fmt("{s}\n", .{c.repo}), 0o600);
            for (plugins) |pl| if (!try plugin.hook(c, pl, pl.hook_sync)) return c.fail("The {s} plugin's sync hook failed. Check the output above.", .{pl.name});
            try verify(c, p);
            try c.result("sync", true, try c.fmt("Synced {s} profile. Verification passed.", .{p}));
        },
        .verify => {
            try verify(c, p);
            try c.result("verify", true, "Verification passed.");
        },
        .push => try push(c, o),
        else => unreachable,
    }
}
fn applyFiles(c: *C, m: manifest.Manifest, p: []const u8) !void {
    for (m.files) |f| {
        if (!f.filter.applies(p)) continue;
        const dest = try c.path(&.{ c.home, f.rel });
        const source = if (f.from) |from| try c.path(&.{ c.repo, from }) else try c.path(&.{ c.repo, "home", f.rel });
        if (f.once) {
            if (!c.exists(dest)) try c.write(dest, try c.optional(source) orelse "", f.mode);
            continue;
        }
        if (!c.exists(source)) return c.fail("{s} lists {s}, but the checkout has no {s}. Run ec push from a machine that has it, or remove the entry.", .{ manifest.file_name, f.rel, source });
        try backup(c, f.rel, dest, source);
        try c.copy(source, dest, f.mode);
        if (std.mem.startsWith(u8, f.rel, ".ssh/")) try c.chmod(try c.path(&.{ c.home, ".ssh" }), 0o700);
    }
}
// The first time sync replaces a file that differs, it keeps the old copy.
fn backup(c: *C, rel: []const u8, dest: []const u8, source: []const u8) !void {
    const saved = try c.path(&.{ c.home, ".config/ender-chest/backup", rel });
    if (c.exists(saved) or c.isLink(dest) or !c.exists(dest)) return;
    if (eq(u8, try c.read(dest), try c.read(source))) return;
    try c.copy(dest, saved, 0o600);
    try c.log("Saved your previous ~/{s} to {s}.", .{ rel, saved });
}
fn primaryCheckout(c: *C, repo: []const u8) ![]const u8 {
    if (!c.exists(try c.path(&.{ repo, ".git" }))) return repo;
    const r = try c.capture(&.{ "git", "rev-parse", "--git-common-dir" }, repo, 15);
    if (!core.success(r.term)) return repo;
    const common = core.trim(r.stdout);
    if (common.len == 0) return repo;
    const abs = if (std.fs.path.isAbsolute(common)) common else try c.path(&.{ repo, common });
    const resolved = try std.fs.path.resolve(c.a, &.{abs});
    if (std.mem.endsWith(u8, resolved, "/.git")) return resolved[0 .. resolved.len - 5];
    return repo;
}
fn pull(c: *C) !void {
    if (!c.exists(try c.path(&.{ c.repo, ".git" }))) return;
    const dirty = try c.capture(&.{ "git", "status", "--porcelain" }, c.repo, 15);
    if (!core.success(dirty.term)) return error.GitStatusFailed;
    if (core.trim(dirty.stdout).len > 0) {
        try c.log("Working tree has changes; applying it without pulling.", .{});
        return;
    }
    const remote = try c.capture(&.{ "git", "remote" }, c.repo, 15);
    if (core.trim(remote.stdout).len == 0) return;
    const fetched = c.capture(&.{ "git", "-c", "core.pager=cat", "fetch" }, c.repo, 15) catch {
        try c.log("warning: git fetch failed or timed out; applying the local tree.", .{});
        return;
    };
    if (!core.success(fetched.term)) {
        try c.log("warning: git fetch failed; applying the local tree.", .{});
        return;
    }
    const target = try pullTarget(c) orelse return;
    const merged = c.capture(&.{ "git", "-c", "core.pager=cat", "merge", "--ff-only", target }, c.repo, 15) catch {
        try c.log("warning: git pull failed or timed out; applying the local tree.", .{});
        return;
    };
    if (!core.success(merged.term)) try c.log("warning: git pull failed; applying the local tree.", .{});
}
fn pullTarget(c: *C) !?[]const u8 {
    const upstream = try c.capture(&.{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, c.repo, 15);
    if (core.success(upstream.term)) {
        const name = core.trim(upstream.stdout);
        if (name.len > 0) return name;
    }
    const branch = try c.capture(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, c.repo, 15);
    if (!core.success(branch.term)) return null;
    const current = core.trim(branch.stdout);
    if (current.len == 0 or eq(u8, current, "HEAD")) return null;
    const head = try c.capture(&.{ "git", "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" }, c.repo, 15);
    if (core.success(head.term)) {
        const ref = core.trim(head.stdout);
        const prefix = "refs/remotes/";
        if (std.mem.startsWith(u8, ref, prefix)) {
            const remote_branch = ref[prefix.len..];
            const slash = std.mem.lastIndexOfScalar(u8, remote_branch, '/') orelse return null;
            if (eq(u8, current, remote_branch[slash + 1 ..])) return remote_branch;
        }
        return null;
    }
    if (eq(u8, current, "main") or eq(u8, current, "master")) {
        const candidate = try c.fmt("origin/{s}", .{current});
        const has = try c.capture(&.{ "git", "rev-parse", "--verify", "--quiet", candidate }, c.repo, 15);
        if (core.success(has.term)) return candidate;
    }
    return null;
}
fn installBinary(c: *C) !void {
    const exe = try std.process.executablePathAlloc(c.io, c.a);
    const dest = try c.path(&.{ c.home, ".local/bin/ec" });
    if (!eq(u8, exe, dest)) try c.copy(exe, dest, 0o755);
    try c.write(try c.path(&.{ c.home, ".local/bin/ender" }), "#!/bin/sh\ncase \"${1-}\" in push|--push|--verify|verify|sync|--help|-h|--version) exec \"$HOME/.local/bin/ec\" \"$@\" ;; *) exec \"$HOME/.local/bin/ec\" sync \"$@\" ;; esac\n", 0o755);
}
fn packages(c: *C, o: O, m: manifest.Manifest, p: []const u8) !void {
    if (o.skip_packages) {
        try c.log("Skipping packages and setup steps.", .{});
        return;
    }
    var brewfiles: std.ArrayList([]const u8) = .empty;
    for (m.brewfiles) |b| if (b.filter.applies(p)) try brewfiles.append(c.a, try c.path(&.{ c.repo, b.path }));
    if (brewfiles.items.len > 0) {
        if (builtin.os.tag == .macos and !c.commandExists("brew")) {
            try c.command(&.{ "/bin/bash", "-c", "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | bash" }, null);
            for ([_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin" }) |dir| {
                if (c.exists(try c.path(&.{ dir, "brew" }))) {
                    try c.env.put("PATH", try c.fmt("{s}:{s}", .{ dir, c.env.get("PATH") orelse "" }));
                    break;
                }
            }
        }
        if (c.commandExists("brew")) {
            try c.env.put("HOMEBREW_NO_AUTO_UPDATE", "1");
            for (brewfiles.items) |file| try c.command(&.{ "brew", "bundle", try c.fmt("--file={s}", .{file}), "--no-upgrade" }, null);
        } else try c.log("Homebrew is not installed; skipping Brewfiles.", .{});
    }
    for (m.setup) |step| {
        if (!step.filter.applies(p)) continue;
        if (step.creates) |path| if (c.exists(try manifest.expand(c, path))) continue;
        try c.log("Setup: {s}", .{step.name});
        const r = try c.capture(&.{ "/bin/sh", "-c", step.run }, c.repo, 900);
        if (r.stdout.len > 0) try c.stderr.writeStreamingAll(c.io, r.stdout);
        if (r.stderr.len > 0) try c.stderr.writeStreamingAll(c.io, r.stderr);
        if (!core.success(r.term)) return c.fail("Setup step \"{s}\" failed. Check the output above, or run ec sync --skip-packages.", .{step.name});
    }
}
pub fn verify(c: *C, p: []const u8) !void {
    var failed: usize = 0;
    const m = try manifest.load(c);
    for (m.files) |f| if (f.filter.applies(p)) try checkFile(c, f.rel, &failed);
    for ([_][]const u8{ ".claude/CLAUDE.md", ".codex/AGENTS.md", ".grok/AGENTS.md", ".claude/settings.json", ".codex/config.toml", ".grok/config.toml", ".local/bin/ec" }) |rel| try checkFile(c, rel, &failed);
    const plugins = try plugin.loadAll(c, m, false);
    const quiet = c.json;
    c.json = true;
    const contrib = plugin.contributions(c, plugins) catch plugin.Contributions{};
    c.json = quiet;
    const claude_file = try c.path(&.{ c.home, ".claude.json" });
    const claude = c.readJson(claude_file) catch c.object();
    const servers = claude.object.get("mcpServers") orelse c.object();
    for (contrib.mcp_servers) |server| {
        const entry = if (servers == .object) servers.object.get(server.name) else null;
        if (entry == null or entry.? != .object or !eq(u8, core.string(entry.?, "url") orelse "", server.url)) {
            failed += 1;
            try c.log("fail: MCP server {s} is missing or stale in {s}. Run ec sync.", .{ server.name, claude_file });
        }
    }
    for (plugins) |pl| if (!try plugin.hook(c, pl, pl.hook_verify)) {
        failed += 1;
        try c.log("fail: the {s} plugin's verify hook failed.", .{pl.name});
    };
    const root = try c.path(&.{ c.repo, "skills" });
    var dir = try core.cwd().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind != .directory or !c.exists(try c.path(&.{ root, entry.name, "SKILL.md" }))) continue;
        try checkSkill(c, entry.name, &failed);
    }
    const skill_list = try skills.load(c);
    for (core.array(skill_list, "skills")) |item| {
        if (skills.wanted(item, p)) try checkSkill(c, core.string(item, "name").?, &failed);
    }
    for (core.array(skill_list, "remove")) |item| {
        const n = core.string(item, "name").?;
        for ([_][]const u8{ ".agents", ".claude", ".codex", ".grok" }) |agent| {
            const file = try c.path(&.{ c.home, agent, "skills", n });
            if (c.exists(file) or c.isLink(file)) {
                failed += 1;
                try c.log("fail: removed skill remains at {s}", .{file});
            }
        }
    }
    if (failed > 0) return c.failCode("verification_failed", "Verification failed with {d} issue(s). Run ec sync to apply missing files.", .{failed});
}
fn checkFile(c: *C, rel: []const u8, failed: *usize) !void {
    const file = try c.path(&.{ c.home, rel });
    const st = core.cwd().statFile(c.io, file, .{}) catch {
        failed.* += 1;
        try c.log("fail: missing {s}", .{file});
        return;
    };
    if (st.kind != .file) {
        failed.* += 1;
        try c.log("fail: expected a file at {s}", .{file});
    }
}
fn checkSkill(c: *C, n: []const u8, failed: *usize) !void {
    const target = try skills.canonical(c, n);
    try checkFile(c, try c.path(&.{ ".agents/skills", n, "SKILL.md" }), failed);
    for ([_][]const u8{ ".claude", ".codex", ".grok" }) |agent| {
        const file = try c.path(&.{ c.home, agent, "skills", n });
        const resolved = core.cwd().realPathFileAlloc(c.io, file, c.a) catch "";
        const expected = core.cwd().realPathFileAlloc(c.io, target, c.a) catch target;
        if (!c.isLink(file) or !eq(u8, resolved, expected)) {
            failed.* += 1;
            try c.log("fail: {s} must link to {s}", .{ file, target });
        }
    }
}
// Push stages only these paths, plus any `from` file listed in ender-chest.toml.
const upload_paths = [_][]const u8{ "home", "skills", "agents", "plugins", manifest.file_name, plugin.lock_file };
fn allowed(path: []const u8, extra: []const []const u8) bool {
    for (upload_paths ++ [_][]const u8{}) |p| if (under(path, p)) return true;
    for (extra) |p| if (under(path, p)) return true;
    return false;
}
fn under(path: []const u8, p: []const u8) bool {
    return eq(u8, path, p) or (std.mem.startsWith(u8, path, p) and path.len > p.len and path[p.len] == '/');
}
fn checkUploadPaths(c: *C) !void {
    const listed = try c.capture(&.{ "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "home" }, c.repo, 15);
    if (!core.success(listed.term)) return error.GitStatusFailed;
    var names = std.mem.splitScalar(u8, listed.stdout, 0);
    while (names.next()) |name| {
        if (name.len == 0) continue;
        for ([_][]const u8{ "home/.config/ender-chest/secrets/", "home/.cli-proxy-api/", "home/.claude/", "home/.codex/", "home/.grok/", "home/.ssh/" }) |prefix| {
            if (std.mem.startsWith(u8, name, prefix) and !eq(u8, name, "home/.ssh/config")) return c.fail("Refusing credential or runtime path in the checkout: {s}. Remove it from Git before ec push.", .{name});
        }
        if (eq(u8, name, "home/.claude.json")) return c.fail("Refusing local agent settings in the checkout: {s}.", .{name});
    }
}
fn push(c: *C, o: O) !void {
    const m = try manifest.load(c);
    const p = profile(c, o);
    var extra: std.ArrayList([]const u8) = .empty;
    for (m.files) |f| {
        if (f.from) |from| try extra.append(c.a, from);
        if (f.once or !f.filter.applies(p)) continue;
        const live = try c.path(&.{ c.home, f.rel });
        if (c.exists(live)) try c.copy(live, if (f.from) |from| try c.path(&.{ c.repo, from }) else try c.path(&.{ c.repo, "home", f.rel }), 0o644);
    }
    try skills.harvest(c);
    try checkUploadPaths(c);
    const status = try c.capture(&.{ "git", "status", "--short" }, c.repo, 15);
    if (!core.success(status.term)) return error.GitStatusFailed;
    if (core.trim(status.stdout).len == 0) {
        try c.result("push", true, "Nothing to upload.");
        return;
    }
    try std.Io.File.stderr().writeStreamingAll(c.io, status.stdout);
    if (o.dry_run) {
        try c.result("push", true, "Dry-run: captured managed files without committing or pushing.");
        return;
    }
    const staged = try c.capture(&.{ "git", "diff", "--cached", "--name-only", "-z" }, c.repo, 15);
    if (!core.success(staged.term)) return error.GitStatusFailed;
    var names = std.mem.splitScalar(u8, staged.stdout, 0);
    while (names.next()) |n| {
        if (n.len > 0 and !allowed(n, extra.items)) return c.fail("Unrelated staged file: {s}. Unstage it before ec push.", .{n});
    }
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(c.a, &.{ "git", "add", "-A", "--" });
    for (upload_paths ++ [_][]const u8{}) |path| try addPath(c, &args, path);
    for (extra.items) |path| try addPath(c, &args, path);
    if (args.items.len > 4) try c.command(args.items, c.repo);
    const diff = try c.capture(&.{ "git", "diff", "--cached", "--quiet" }, c.repo, 15);
    if (core.success(diff.term)) {
        try c.result("push", true, "No managed changes to upload.");
        return;
    }
    if (diff.term != .exited or diff.term.exited != 1) return error.GitDiffFailed;
    try c.command(&.{ "git", "commit", "-m", "Update machine config" }, c.repo);
    try c.command(&.{ "git", "pull", "--rebase", "--autostash" }, c.repo);
    try c.command(&.{ "git", "push" }, c.repo);
    try c.result("push", true, "Uploaded. Run ec sync on each other machine when ready.");
}
fn addPath(c: *C, args: *std.ArrayList([]const u8), path: []const u8) !void {
    if (c.exists(try c.path(&.{ c.repo, path }))) return args.append(c.a, path);
    const tracked = try c.capture(&.{ "git", "ls-files", "--", path }, c.repo, 15);
    if (core.trim(tracked.stdout).len > 0) try args.append(c.a, path);
}

fn refreshBinary(c: *C, o: O) !void {
    if (!c.exists(try c.path(&.{ c.repo, "build.zig" }))) {
        const release = @import("update.zig").latest(c) orelse return;
        try @import("update.zig").tryRelease(c, o, release.hash);
        return;
    }
    const hash = try @import("source_hash.zig").fingerprint(c.a, c.io, c.repo);
    try @import("update.zig").tryRelease(c, o, &hash);
    if (eq(u8, &hash, @import("build_options").source_hash)) {
        _ = c.env.swapRemove("EC_REBUILD_ATTEMPTED");
        return;
    }
    if (c.env.get("EC_REBUILD_ATTEMPTED")) |previous| {
        if (eq(u8, previous, &hash)) return c.fail("Rebuilt ec still has stale sources. Run ./ec sync from the checkout.", .{});
    }
    try c.log("CLI sources changed; rebuilding ec before applying config.", .{});
    try c.command(&.{ try c.path(&.{ c.repo, "tools/zig" }), "build", "-Doptimize=ReleaseSafe" }, c.repo);
    try c.env.put("EC_SYNC_PULLED", c.repo);
    try c.env.put("EC_REBUILD_ATTEMPTED", &hash);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(c.a, &.{ try c.path(&.{ c.repo, "zig-out/bin/ec" }), "sync", "--repo", c.repo });
    if (o.profile.len > 0) try args.appendSlice(c.a, &.{ "--profile", o.profile });
    if (o.skip_packages) try args.append(c.a, "--skip-packages");
    if (o.update_skills) try args.append(c.a, "--update-skills");
    if (o.json) try args.append(c.a, "--json");
    return std.process.replace(c.io, .{ .argv = args.items, .environ_map = c.env });
}
