const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const C = core.Context;
const O = @import("options.zig").Options;
const skills = @import("skills.zig");
const eq = core.eql;
const credentials = @import("credentials.zig");
const HomeFile = struct { rel: []const u8, mode: u32 = 0o644, mac: bool = false };
pub const home_files = [_]HomeFile{
    .{ .rel = ".gitconfig" },                           .{ .rel = ".zshrc" },                                         .{ .rel = ".zprofile" },
    .{ .rel = ".local/bin/cliproxy", .mode = 0o755 },   .{ .rel = ".local/bin/desktop", .mode = 0o755 },              .{ .rel = ".local/lib/desktop/unlock-wallet.py" },
    .{ .rel = ".config/desktop/config.json" },          .{ .rel = ".config/cliproxyapi/client.json", .mode = 0o600 }, .{ .rel = ".config/git/ignore" },
    .{ .rel = ".config/shell/macos.zsh", .mac = true }, .{ .rel = ".config/shell/macos.zprofile", .mac = true },      .{ .rel = ".config/zed/settings.json", .mac = true },
    .{ .rel = ".ssh/config", .mode = 0o600 },
};
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
    const p = o.repo orelse configured orelse if (c.exists(try c.path(&.{ current, "agents/shared/AGENTS.md" }))) current else if (saved) |s| core.trim(s) else current;
    c.repo = try std.fs.path.resolve(c.a, &.{p});
    if (!explicit) c.repo = try primaryCheckout(c, c.repo);
    if (!c.exists(try c.path(&.{ c.repo, "agents/shared/AGENTS.md" })) or !c.exists(try c.path(&.{ c.repo, "skills/manifest.json" }))) return c.fail("No ender-chest config checkout at {s}. Use --repo PATH or set EC_REPO.", .{c.repo});
}
pub fn run(c: *C, o: O) !void {
    try resolveRepo(c, o);
    const p = profile(c, o);
    try c.env.put("GIT_TERMINAL_PROMPT", "0");
    try c.env.put("GIT_PAGER", "cat");
    switch (o.command) {
        .sync => {
            const already_pulled = c.env.get("EC_SYNC_PULLED");
            if (already_pulled == null or !eq(u8, already_pulled.?, c.repo)) try pull(c);
            _ = c.env.swapRemove("EC_SYNC_PULLED");
            try refreshBinary(c, o);
            try credentials.checkRepo(c);
            try credentials.migrate(c);
            _ = try credentials.loadKey(c);
            try packages(c, o, p);
            try seed(c, p);
            for (home_files) |file| {
                if (file.mac and builtin.os.tag != .macos) continue;
                try c.copy(try c.path(&.{ c.repo, "home", file.rel }), try c.path(&.{ c.home, file.rel }), file.mode);
            }
            try c.chmod(try c.path(&.{ c.home, ".ssh" }), 0o700);
            for ([_][]const u8{ "cli.mjs", "auth.mjs" }) |obsolete| try c.remove(try c.path(&.{ c.home, ".local/lib/desktop", obsolete }));
            try @import("config.zig").apply(c);
            try skills.apply(c, p, o.update_skills);
            try stubs(c);
            try installBinary(c);
            try c.write(try c.path(&.{ c.home, ".config/ender-chest/repo" }), try c.fmt("{s}\n", .{c.repo}), 0o600);
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
fn seed(c: *C, p: []const u8) !void {
    const gitlocal = try c.path(&.{ c.home, ".gitconfig.local" });
    if (!c.exists(gitlocal) and c.exists(try c.path(&.{ c.home, ".gitconfig" }))) {
        var out: std.Io.Writer.Allocating = .init(c.a);
        try out.writer.writeAll("# Machine-local git settings. Do not copy to the repo.\n");
        const editor = try c.capture(&.{ "git", "config", "--global", "--get", "core.editor" }, null, 15);
        if (core.success(editor.term)) try out.writer.print("[core]\n\teditor = {s}\n", .{core.trim(editor.stdout)});
        for ([_][]const u8{ "https://github.com", "https://gist.github.com" }) |host| {
            const helper = try c.capture(&.{ "git", "config", "--global", "--get", try c.fmt("credential.{s}.helper", .{host}) }, null, 15);
            if (core.success(helper.term)) try out.writer.print("[credential \"{s}\"]\n\thelper =\n\thelper = {s}\n", .{ host, core.trim(helper.stdout) });
        }
        try c.write(gitlocal, try out.toOwnedSlice(), 0o644);
    }
    const sshlocal = try c.path(&.{ c.home, ".ssh/config.local" });
    if (!c.exists(sshlocal)) {
        const existing = try c.optional(try c.path(&.{ c.home, ".ssh/config" }));
        if (existing != null and std.ascii.indexOfIgnoreCase(existing.?, "orbstack") != null) try c.write(sshlocal, existing.?, 0o600) else if (eq(u8, p, "mac") and c.exists(try c.path(&.{ c.home, ".orbstack/ssh/config" }))) try c.write(sshlocal, "# OrbStack Linux machines.\nInclude ~/.orbstack/ssh/config\n", 0o600);
    }
}
fn stubs(c: *C) !void {
    const entries = [_]struct { dest: []const u8, source: ?[]const u8, mode: u32 = 0o644 }{
        .{ .dest = ".gitconfig.local", .source = "git/gitconfig.local.example" },
        .{ .dest = ".config/git/identity.work", .source = "git/identity.work.example" },
        .{ .dest = ".zshrc.local", .source = "shell/zshrc.local.example" },
        .{ .dest = ".zprofile.local", .source = null },
        .{ .dest = ".ssh/config.local", .source = "tools/ssh/config.local.example", .mode = 0o600 },
    };
    for (entries) |entry| {
        const dest = try c.path(&.{ c.home, entry.dest });
        if (!c.exists(dest)) try c.write(dest, if (entry.source) |src| try c.read(try c.path(&.{ c.repo, src })) else "", entry.mode);
        if (entry.mode == 0o600) try c.chmod(dest, entry.mode);
    }
}
fn installBinary(c: *C) !void {
    const exe = try std.process.executablePathAlloc(c.io, c.a);
    const dest = try c.path(&.{ c.home, ".local/bin/ec" });
    if (!eq(u8, exe, dest)) try c.copy(exe, dest, 0o755);
    try c.write(try c.path(&.{ c.home, ".local/bin/ender" }), "#!/bin/sh\ncase \"${1-}\" in push|--push|--verify|verify|sync|--help|-h|--version) exec \"$HOME/.local/bin/ec\" \"$@\" ;; *) exec \"$HOME/.local/bin/ec\" sync \"$@\" ;; esac\n", 0o755);
}
fn packages(c: *C, o: O, p: []const u8) !void {
    if (o.skip_packages) {
        try c.log("Skipping package setup.", .{});
        return;
    }
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
        try c.command(&.{ "brew", "bundle", try c.fmt("--file={s}/tools/Brewfile", .{c.repo}), "--no-upgrade" }, null);
        if (eq(u8, p, "mac")) try c.command(&.{ "brew", "bundle", try c.fmt("--file={s}/tools/Brewfile.mac", .{c.repo}), "--no-upgrade" }, null);
    } else try c.log("Homebrew is not installed; keeping system packages.", .{});
    const zsh = try c.path(&.{ c.home, ".oh-my-zsh" });
    if (!c.exists(zsh)) {
        try c.env.put("RUNZSH", "no");
        try c.env.put("CHSH", "no");
        try c.env.put("KEEP_ZSHRC", "yes");
        try c.command(&.{ "/bin/sh", "-c", "curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh" }, null);
    }
    for ([_][]const u8{ "zsh-autosuggestions", "zsh-syntax-highlighting", "zsh-completions" }) |plugin| {
        const dest = try c.path(&.{ zsh, "custom/plugins", plugin });
        if (!c.exists(try c.path(&.{ dest, ".git" }))) try c.command(&.{ "git", "clone", "--depth", "1", try c.fmt("https://github.com/zsh-users/{s}.git", .{plugin}), dest }, null);
    }
    if (c.commandExists("fnm")) {
        const version = core.trim(try c.read(try c.path(&.{ c.repo, "tools/node-version" })));
        if (version.len > 0) {
            try c.command(&.{ "fnm", "install", version }, null);
            const list = try c.capture(&.{ "fnm", "list" }, null, 30);
            if (std.mem.indexOf(u8, list.stdout, "default") == null) try c.command(&.{ "fnm", "default", version }, null);
        }
    }
}
pub fn verify(c: *C, p: []const u8) !void {
    var failed: usize = 0;
    for (home_files) |file| {
        if (file.mac and builtin.os.tag != .macos) continue;
        try checkFile(c, file.rel, &failed);
    }
    for ([_][]const u8{ ".gitconfig.local", ".config/git/identity.work", ".zshrc.local", ".zprofile.local", ".ssh/config.local", ".claude/CLAUDE.md", ".codex/AGENTS.md", ".grok/AGENTS.md", ".claude/settings.json", ".codex/config.toml", ".grok/config.toml", ".local/bin/ec" }) |rel| try checkFile(c, rel, &failed);
    const claude_file = try c.path(&.{ c.home, ".claude.json" });
    const claude = c.readJson(claude_file) catch c.object();
    const servers = claude.object.get("mcpServers") orelse c.object();
    if (try @import("config.zig").hasSharedExecutor(c) and (servers != .object or servers.object.get("executor") == null or servers.object.get("executor").? != .object)) {
        failed += 1;
        try c.log("fail: executor MCP missing from {s}", .{claude_file});
    }
    const needles = [_][2][]const u8{ .{ ".gitconfig", "path = .gitconfig.local" }, .{ ".gitconfig", "rerere" }, .{ ".config/git/ignore", ".claude/settings.local.json" }, .{ ".zshrc", "fnm env" }, .{ ".ssh/config", "Host github.com" } };
    for (needles) |check| {
        const data = try c.optional(try c.path(&.{ c.home, check[0] })) orelse "";
        if (std.mem.indexOf(u8, data, check[1]) == null) {
            failed += 1;
            try c.log("fail: {s} does not contain {s}", .{ check[0], check[1] });
        }
    }
    const root = try c.path(&.{ c.repo, "skills" });
    var dir = try core.cwd().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind != .directory or !c.exists(try c.path(&.{ root, entry.name, "SKILL.md" }))) continue;
        try checkSkill(c, entry.name, &failed);
    }
    const manifest = try skills.load(c);
    for (core.array(manifest, "skills")) |item| {
        if (skills.wanted(item, p)) try checkSkill(c, core.string(item, "name").?, &failed);
    }
    for (core.array(manifest, "remove")) |item| {
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
const upload_paths = [_][]const u8{ ".gitignore", "home", "skills", "agents", "tools", "src", "tests", "ender", "ec", "build.zig", "build.zig.zon", ".zig-version", "package.json", "pnpm-lock.yaml", "tsconfig.json", "vitest.config.ts", ".node-version", "README.md", "AGENTS.md", "DEVICES.md", "git", "shell", ".github" };
fn allowed(path: []const u8) bool {
    for (upload_paths) |p| {
        if (eq(u8, path, p) or (std.mem.startsWith(u8, path, p) and path.len > p.len and path[p.len] == '/')) return true;
    }
    return false;
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
    for (home_files) |file| {
        if (file.mac and builtin.os.tag != .macos) continue;
        const live = try c.path(&.{ c.home, file.rel });
        if (c.exists(live)) {
            const dest = try c.path(&.{ c.repo, "home", file.rel });
            if (eq(u8, file.rel, credentials.endpoint_path)) try credentials.exportEndpoint(c, live, dest) else try c.copy(live, dest, 0o644);
        }
    }
    try skills.harvest(c);
    try credentials.checkRepo(c);
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
        if (n.len > 0 and !allowed(n)) return c.fail("Unrelated staged file: {s}. Unstage it before ec push.", .{n});
    }
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(c.a, &.{ "git", "add", "-A", "--" });
    for (upload_paths) |p| {
        if (c.exists(try c.path(&.{ c.repo, p }))) {
            try args.append(c.a, p);
            continue;
        }
        const tracked = try c.capture(&.{ "git", "ls-files", "--", p }, c.repo, 15);
        if (core.trim(tracked.stdout).len > 0) try args.append(c.a, p);
    }
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
