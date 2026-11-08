// Agent skills. Each skill lives once in ~/.agents/skills and every agent links to it. Skills come
// from the checkout's skills/ directory and from GitHub sources listed in skills/manifest.json.
const std = @import("std");
const core = @import("core.zig");
const paths = @import("paths.zig");
const manifest = @import("manifest.zig");
const agents = @import("agents.zig");
const github = @import("github.zig");
const C = core.Context;
const V = core.Value;
const eq = core.eql;

fn load(c: *C) !V {
    const file = try paths.inRepo(c, paths.skills_manifest);
    if (!c.exists(file)) return emptyList(c);
    const m = try c.readJson(file);
    const skills = m.object.get("skills") orelse return c.fail("{s} needs a skills list.", .{file});
    if (skills != .array) return c.fail("{s} needs a skills list.", .{file});
    for (core.array(m, "skills")) |item| {
        try checkName(c, file, item);
        if (core.string(item, "source") == null or core.string(item, "skill") == null) return c.fail("Each skill in {s} needs a name, source, and skill.", .{file});
    }
    for (core.array(m, "remove")) |item| try checkName(c, file, item);
    return m;
}
fn emptyList(c: *C) !V {
    var m = c.object();
    try m.object.put(c.a, "version", .{ .integer = 1 });
    try m.object.put(c.a, "skills", .{ .array = std.json.Array.init(c.a) });
    return m;
}
fn checkName(c: *C, file: []const u8, item: V) !void {
    const n = core.string(item, "name") orelse return c.fail("Each skill in {s} needs a name.", .{file});
    if (!core.safeName(n)) return c.fail("Invalid skill name in {s}.", .{file});
}
fn wanted(c: *C, item: V, profile: []const u8) !bool {
    var profiles: std.ArrayList([]const u8) = .empty;
    for (core.array(item, "profiles")) |p| if (p == .string) try profiles.append(c.a, p.string);
    const filter: manifest.Filter = .{ .profiles = profiles.items };
    return filter.applies(profile);
}
fn listed(items: []const V, n: []const u8) bool {
    for (items) |item| {
        if (core.string(item, "name")) |s| if (eq(u8, n, s)) return true;
    }
    return false;
}
fn canonical(c: *C, n: []const u8) ![]const u8 {
    return c.path(&.{ c.home, paths.skills_home, n });
}
fn link(c: *C, n: []const u8) !void {
    const dest = try canonical(c, n);
    for (try agents.skillDirs(c, true)) |dir| try c.link(dest, try c.path(&.{ dir, n }));
}
fn present(c: *C, dir: []const u8) !bool {
    return c.exists(try c.path(&.{ dir, "SKILL.md" }));
}
fn replace(c: *C, source: []const u8, dest: []const u8) !void {
    const staged = try c.tempNear(dest);
    defer c.remove(staged) catch {};
    try c.copyTree(source, staged);
    try c.remove(dest);
    try core.cwd().rename(staged, core.cwd(), dest, c.io);
}
fn canonicalize(c: *C, n: []const u8) !bool {
    const dest = try canonical(c, n);
    const local = try c.path(&.{ try agents.claude.skills.?.resolve(c), n });
    if (!try present(c, dest)) {
        if (!try present(c, local)) return false;
        try replace(c, local, dest);
    }
    try link(c, n);
    return true;
}
fn personal(c: *C, removed: []const V) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const root = try paths.inRepo(c, paths.skills_dir);
    if (!c.exists(root)) return names.items;
    var dir = try core.cwd().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind != .directory or !core.safeName(entry.name) or listed(removed, entry.name)) continue;
        if (try present(c, try c.path(&.{ root, entry.name }))) try names.append(c.a, try c.a.dupe(u8, entry.name));
    }
    return names.items;
}

pub fn apply(c: *C, profile: []const u8, update: bool) !void {
    const list = try load(c);
    const removed = core.array(list, "remove");
    for (removed) |item| {
        const n = core.string(item, "name").?;
        for (try agents.skillDirs(c, false)) |dir| try c.remove(try c.path(&.{ dir, n }));
        try c.remove(try canonical(c, n));
        // Uninstalls the npm tool that shipped the skill. Only the login HOME has it, so a sync
        // into a temporary HOME leaves the machine's packages alone.
        const libc = @cImport({
            @cInclude("unistd.h");
            @cInclude("pwd.h");
        });
        const pw = libc.getpwuid(libc.getuid());
        const login_home = if (pw != null) std.mem.span(pw.*.pw_dir) else "";
        if (eq(u8, c.home, login_home) and c.commandExists("npm")) for (core.array(item, "npm")) |pkg| {
            if (pkg != .string or pkg.string.len == 0 or pkg.string[0] == '-') return c.fail("Invalid npm package for skill {s} in {s}.", .{ n, paths.skills_manifest });
            c.command(&.{ "npm", "uninstall", "-g", "--", pkg.string }, null) catch {
                try c.log("warning: could not uninstall {s}", .{pkg.string});
            };
        };
    }
    for (try personal(c, removed)) |n| {
        try replace(c, try c.path(&.{ c.repo, paths.skills_dir, n }), try canonical(c, n));
        try link(c, n);
    }
    var sources = std.StringHashMap([]const u8).init(c.a);
    const temp = try c.tempNear(try paths.inHome(c, paths.cache_dir ++ "/skills"));
    defer c.remove(temp) catch {};
    for (core.array(list, "skills")) |item| {
        if (!try wanted(c, item, profile)) continue;
        const n = core.string(item, "name").?;
        if (!update and try canonicalize(c, n)) continue;
        const source = core.string(item, "source").?;
        try c.log("Installing skill {s} from {s}", .{ n, source });
        const checkout = if (sources.get(source)) |p| p else blk: {
            const parsed = github.Source.parse(source) catch return c.fail("Invalid source {s} for skill {s}. Use owner/repo or owner/repo#ref.", .{ source, n });
            const dest = try c.path(&.{ temp, try c.fmt("{d}", .{sources.count()}) });
            try c.mkdir(temp);
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(c.a, &.{ "git", "clone", "--depth", "1" });
            if (parsed.ref) |ref| try args.appendSlice(c.a, &.{ "--branch", ref });
            try args.appendSlice(c.a, &.{ "--", try github.cloneUrl(c.a, parsed.slug), dest });
            try c.command(args.items, null);
            try sources.put(source, dest);
            break :blk dest;
        };
        const found = try find(c, checkout, core.string(item, "skill").?) orelse return c.fail("Skill {s} was not found in {s}.", .{ n, source });
        try replace(c, found, try canonical(c, n));
        try link(c, n);
    }
}

pub fn verify(c: *C, profile: []const u8, checks: *core.Checks) !void {
    const list = try load(c);
    const removed = core.array(list, "remove");
    for (try personal(c, removed)) |n| try checkLinks(c, n, checks);
    for (core.array(list, "skills")) |item| {
        if (try wanted(c, item, profile)) try checkLinks(c, core.string(item, "name").?, checks);
    }
    for (removed) |item| {
        const n = core.string(item, "name").?;
        var left: std.ArrayList([]const u8) = .empty;
        try left.append(c.a, try canonical(c, n));
        for (try agents.skillDirs(c, false)) |dir| try left.append(c.a, try c.path(&.{ dir, n }));
        for (left.items) |file| if (c.exists(file) or c.isLink(file)) try checks.fail(c, "removed skill remains at {s}", .{file});
    }
}
fn checkLinks(c: *C, n: []const u8, checks: *core.Checks) !void {
    const target = try canonical(c, n);
    try checks.file(c, try c.path(&.{ target, "SKILL.md" }));
    const expected = core.cwd().realPathFileAlloc(c.io, target, c.a) catch target;
    for (try agents.skillDirs(c, true)) |dir| {
        const file = try c.path(&.{ dir, n });
        const resolved = core.cwd().realPathFileAlloc(c.io, file, c.a) catch "";
        if (!c.isLink(file) or !eq(u8, resolved, expected)) try checks.fail(c, "{s} must link to {s}", .{ file, target });
    }
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

// For ec push: lists installed skills the manifest lacks. A skill the skills CLI installed keeps
// the source its lock file records; any other skill is personal and is copied into skills/.
pub fn capture(c: *C) !void {
    const file = try paths.inRepo(c, paths.skills_manifest);
    var list = try load(c);
    var installed = std.StringHashMap(void).init(c.a);
    const claude_skills = agents.claude.skills.?.home;
    for ([_][]const u8{ paths.skills_home, claude_skills }) |rel| {
        const root = try paths.inHome(c, rel);
        if (!c.exists(root)) continue;
        var dir = try core.cwd().openDir(c.io, root, .{ .iterate = true });
        defer dir.close(c.io);
        var it = dir.iterate();
        while (try it.next(c.io)) |entry| {
            if (!core.safeName(entry.name) or !try present(c, try c.path(&.{ root, entry.name }))) continue;
            try installed.put(try c.a.dupe(u8, entry.name), {});
        }
    }
    const lock_file = try paths.inHome(c, paths.skill_lock);
    const lock = if (try c.optional(lock_file)) |data| try c.parseObject(lock_file, data) else c.object();
    const locked = lock.object.get("skills") orelse c.object();
    var skills = list.object.get("skills").?;
    var names: std.ArrayList([]const u8) = .empty;
    var it = installed.keyIterator();
    while (it.next()) |n| try names.append(c.a, n.*);
    core.sortStrings(names.items);
    var added = false;
    for (names.items) |n| {
        if (listed(core.array(list, "remove"), n) or listed(skills.array.items, n)) continue;
        const source = if (locked == .object) if (locked.object.get(n)) |item| core.string(item, "source") else null else null;
        if (source) |s| {
            var item = c.object();
            try item.object.put(c.a, "name", .{ .string = n });
            try item.object.put(c.a, "source", .{ .string = s });
            try item.object.put(c.a, "skill", .{ .string = n });
            try skills.array.append(item);
            added = true;
            continue;
        }
        for ([_][]const u8{ claude_skills, paths.skills_home }) |rel| {
            const src = try c.path(&.{ c.home, rel, n });
            if (c.isLink(src) or !try present(c, src)) continue;
            try c.copyTree(src, try c.path(&.{ c.repo, paths.skills_dir, n }));
            break;
        }
    }
    if (!added and !c.exists(file)) return;
    try list.object.put(c.a, "skills", skills);
    try c.writeJson(file, list, 0o644);
}
