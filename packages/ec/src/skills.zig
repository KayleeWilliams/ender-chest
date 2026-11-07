const std = @import("std");
const core = @import("core.zig");
const C = core.Context;
const V = core.Value;
const eq = core.eql;
const agents = [_][]const u8{ ".claude", ".codex", ".grok" };
pub fn load(c: *C) !V {
    const m = try c.readJson(try c.path(&.{ c.repo, "skills/manifest.json" }));
    const skills = m.object.get("skills") orelse return error.InvalidManifest;
    if (skills != .array) return error.InvalidManifest;
    for (core.array(m, "skills")) |item| {
        try name(c, item);
        if (core.string(item, "source") == null or core.string(item, "skill") == null) return error.InvalidManifest;
    }
    for (core.array(m, "remove")) |item| try name(c, item);
    return m;
}
fn name(c: *C, item: V) !void {
    const n = core.string(item, "name") orelse return error.InvalidManifest;
    if (!core.safeName(n)) return c.fail("Invalid skill name in manifest.", .{});
}
pub fn wanted(item: V, profile: []const u8) bool {
    const profiles = core.array(item, "profiles");
    if (profiles.len == 0) return true;
    for (profiles) |p| if (p == .string and eq(u8, p.string, profile)) return true;
    return false;
}
fn listed(items: []const V, n: []const u8) bool {
    for (items) |item| {
        if (core.string(item, "name")) |s| if (eq(u8, n, s)) return true;
    }
    return false;
}
pub fn canonical(c: *C, n: []const u8) ![]const u8 {
    return c.path(&.{ c.home, ".agents/skills", n });
}
pub fn link(c: *C, n: []const u8) !void {
    const dest = try canonical(c, n);
    for (agents) |agent| try c.link(dest, try c.path(&.{ c.home, agent, "skills", n }));
}
fn present(c: *C, dir: []const u8) !bool {
    return c.exists(try c.path(&.{ dir, "SKILL.md" }));
}
fn replace(c: *C, source: []const u8, dest: []const u8) !void {
    var random: [8]u8 = undefined;
    std.Io.random(c.io, &random);
    const staged = try c.fmt("{s}.ec-{x}", .{ dest, random });
    defer c.remove(staged) catch {};
    try c.copyTree(source, staged);
    try c.remove(dest);
    try core.cwd().rename(staged, core.cwd(), dest, c.io);
}
fn canonicalize(c: *C, n: []const u8) !bool {
    const dest = try canonical(c, n);
    const local = try c.path(&.{ c.home, ".claude/skills", n });
    if (!try present(c, dest)) {
        if (!try present(c, local)) return false;
        try replace(c, local, dest);
    }
    try link(c, n);
    return true;
}
pub fn apply(c: *C, profile: []const u8, update: bool) !void {
    const manifest = try load(c);
    for (core.array(manifest, "remove")) |item| {
        const n = core.string(item, "name").?;
        for (agents) |agent| try c.remove(try c.path(&.{ c.home, agent, "skills", n }));
        try c.remove(try canonical(c, n));
        // npm is only needed to remove a previously installed npm tool.
        const libc = @cImport({
            @cInclude("unistd.h");
            @cInclude("pwd.h");
        });
        const pw = libc.getpwuid(libc.getuid());
        const login_home = if (pw != null) std.mem.span(pw.*.pw_dir) else "";
        if (eq(u8, c.home, login_home) and c.commandExists("npm")) for (core.array(item, "npm")) |pkg| {
            if (pkg != .string or pkg.string.len == 0 or pkg.string[0] == '-') return error.InvalidManifest;
            c.command(&.{ "npm", "uninstall", "-g", "--", pkg.string }, null) catch {
                try c.log("warning: could not uninstall {s}", .{pkg.string});
            };
        };
    }
    const root = try c.path(&.{ c.repo, "skills" });
    var dir = try core.cwd().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind != .directory or !core.safeName(entry.name) or listed(core.array(manifest, "remove"), entry.name)) continue;
        const source = try c.path(&.{ root, entry.name });
        if (!try present(c, source)) continue;
        try replace(c, source, try canonical(c, entry.name));
        try link(c, entry.name);
    }
    var sources = std.StringHashMap([]const u8).init(c.a);
    var random: [8]u8 = undefined;
    std.Io.random(c.io, &random);
    const temp = try c.path(&.{ c.home, ".cache/ec", try c.fmt("skills-{x}", .{random}) });
    defer c.remove(temp) catch {};
    for (core.array(manifest, "skills")) |item| {
        if (!wanted(item, profile)) continue;
        const n = core.string(item, "name").?;
        if (!update and try canonicalize(c, n)) continue;
        const source = core.string(item, "source").?;
        try c.log("Installing skill {s} from {s}", .{ n, source });
        const checkout = if (sources.get(source)) |p| p else blk: {
            const parsed = try parseSource(source);
            const dest = try c.path(&.{ temp, try c.fmt("{d}", .{sources.count()}) });
            try c.mkdir(temp);
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(c.a, &.{ "git", "clone", "--depth", "1" });
            if (parsed.ref) |ref| try args.appendSlice(c.a, &.{ "--branch", ref });
            try args.appendSlice(c.a, &.{ "--", try c.fmt("https://github.com/{s}.git", .{parsed.repo}), dest });
            try c.command(args.items, null);
            try sources.put(source, dest);
            break :blk dest;
        };
        const found = try find(c, checkout, core.string(item, "skill").?) orelse return c.fail("Skill {s} was not found in {s}.", .{ n, source });
        try replace(c, found, try canonical(c, n));
        try link(c, n);
    }
}
pub fn parseSource(source: []const u8) !struct { repo: []const u8, ref: ?[]const u8 } {
    var split = std.mem.splitScalar(u8, source, '#');
    const repo = split.next().?;
    const ref = split.next();
    if (split.next() != null) return error.InvalidSkillSource;
    var parts = std.mem.splitScalar(u8, repo, '/');
    const owner = parts.next().?;
    const project = parts.next() orelse return error.InvalidSkillSource;
    if (!core.safeName(owner) or !core.safeName(project) or parts.next() != null) return error.InvalidSkillSource;
    if (ref) |r| {
        if (r.len == 0 or r[0] == '-' or std.mem.indexOfAny(u8, r, " \t\n\r") != null) return error.InvalidSkillSource;
    }
    return .{ .repo = repo, .ref = ref };
}
// Finds the directory of skill `n` in a source checkout. A repository can hold the same skill
// more than once, such as skills/NAME and a package or harness copy. Among matches in a directory
// named NAME, the one nearest the root wins; a tie is an error.
fn find(c: *C, root: []const u8, n: []const u8) !?[]const u8 {
    var matches: std.ArrayList([]const u8) = .empty;
    try collect(c, root, n, 0, &matches);
    if (matches.items.len <= 1) return if (matches.items.len == 1) matches.items[0] else null;
    var best: ?[]const u8 = null;
    var tied = false;
    for (matches.items) |m| {
        if (!eq(u8, std.fs.path.basename(m), n)) continue;
        if (best == null or pathDepth(m) < pathDepth(best.?)) {
            best = m;
            tied = false;
        } else if (pathDepth(m) == pathDepth(best.?)) tied = true;
    }
    if (best == null or tied) return c.fail("Multiple skills named {s} in source. Resolve the duplicate before installing.", .{n});
    return best;
}
fn pathDepth(p: []const u8) usize {
    return std.mem.count(u8, p, std.fs.path.sep_str);
}
fn collect(c: *C, root: []const u8, n: []const u8, depth: usize, matches: *std.ArrayList([]const u8)) anyerror!void {
    if (depth > 12) return;
    if (try c.optional(try c.path(&.{ root, "SKILL.md" }))) |body| {
        var lines = std.mem.splitScalar(u8, body, '\n');
        var named = false;
        if (eq(u8, core.trim(lines.next() orelse ""), "---")) while (lines.next()) |line| {
            const t = core.trim(line);
            if (eq(u8, t, "---")) break;
            if (std.mem.startsWith(u8, t, "name:")) named = eq(u8, std.mem.trim(u8, core.trim(t[5..]), "\"'"), n);
        };
        if (named or eq(u8, std.fs.path.basename(root), n)) return matches.append(c.a, root);
    }
    var dir = try core.cwd().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind != .directory or eq(u8, entry.name, ".git") or eq(u8, entry.name, "node_modules")) continue;
        try collect(c, try c.path(&.{ root, entry.name }), n, depth + 1, matches);
    }
}
pub fn harvest(c: *C) !void {
    var manifest = try load(c);
    var installed = std.StringHashMap(void).init(c.a);
    for ([_][]const u8{ ".agents/skills", ".claude/skills" }) |rel| {
        const root = try c.path(&.{ c.home, rel });
        if (!c.exists(root)) continue;
        var dir = try core.cwd().openDir(c.io, root, .{ .iterate = true });
        defer dir.close(c.io);
        var it = dir.iterate();
        while (try it.next(c.io)) |entry| {
            if (!core.safeName(entry.name) or !try present(c, try c.path(&.{ root, entry.name }))) continue;
            try installed.put(try c.a.dupe(u8, entry.name), {});
        }
    }
    const lockfile = try c.path(&.{ c.home, ".agents/.skill-lock.json" });
    const lock = if (try c.optional(lockfile)) |data| try c.parse(data) else c.object();
    const locked = if (lock == .object) lock.object.get("skills") orelse c.object() else c.object();
    var list = manifest.object.get("skills").?;
    var names: std.ArrayList([]const u8) = .empty;
    var it = installed.keyIterator();
    while (it.next()) |n| try names.append(c.a, n.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (names.items) |n| {
        if (listed(core.array(manifest, "remove"), n)) continue;
        var source: ?[]const u8 = null;
        if (locked == .object) {
            if (locked.object.get(n)) |item| source = core.string(item, "source");
        }
        const cloudflare = [_][]const u8{ "agents-sdk", "cloudflare", "cloudflare-email-service", "cloudflare-one", "cloudflare-one-migrations", "durable-objects", "sandbox-migrate-to-next", "sandbox-next", "sandbox-stable", "turnstile-spin", "web-perf", "workers-best-practices", "wrangler" };
        if (source == null) for (cloudflare) |skill| {
            if (eq(u8, n, skill)) {
                source = "cloudflare/skills";
                break;
            }
        };
        if (!listed(list.array.items, n)) {
            if (source) |s| {
                var item = c.object();
                try item.object.put(c.a, "name", .{ .string = n });
                try item.object.put(c.a, "source", .{ .string = s });
                try item.object.put(c.a, "skill", .{ .string = n });
                try list.array.append(item);
            } else if (!eq(u8, n, "sentry-cli")) {
                for ([_][]const u8{ ".claude/skills", ".agents/skills" }) |rel| {
                    const src = try c.path(&.{ c.home, rel, n });
                    if (c.isLink(src) or !try present(c, src)) continue;
                    try c.copyTree(src, try c.path(&.{ c.repo, "skills", n }));
                    break;
                }
            }
        }
    }
    try manifest.object.put(c.a, "skills", list);
    try c.writeJson(try c.path(&.{ c.repo, "skills/manifest.json" }), manifest, 0o644);
}
test "skill sources reject option injection and traversal" {
    try std.testing.expectError(error.InvalidSkillSource, parseSource("../repo"));
    try std.testing.expectError(error.InvalidSkillSource, parseSource("owner/repo#--upload-pack=bad"));
    const s = try parseSource("owner/repo#main");
    try std.testing.expectEqualStrings("owner/repo", s.repo);
    try std.testing.expectEqualStrings("main", s.ref.?);
}
