// Home files listed in ender-chest.toml: sync copies them in, verify checks them, and push copies
// them back into the checkout.
const std = @import("std");
const core = @import("core.zig");
const paths = @import("paths.zig");
const manifest = @import("manifest.zig");
const C = core.Context;
const eq = core.eql;

pub fn apply(c: *C, m: manifest.Manifest, profile: []const u8) !void {
    for (m.files) |f| {
        if (!f.filter.applies(profile)) continue;
        const dest = try paths.inHome(c, f.rel);
        const source = try f.source(c);
        if (f.once) {
            if (!c.exists(dest)) try c.write(dest, try c.optional(source) orelse "", f.mode);
            continue;
        }
        const content = try c.optional(source) orelse return c.fail("{s} lists {s}, but the checkout has no {s}. Run ec push from a machine that has it, or remove the entry.", .{ paths.manifest_file, f.rel, source });
        try write(c, f.rel, content, f.mode);
        // ssh refuses keys and config in a directory others can write.
        if (std.mem.startsWith(u8, f.rel, ".ssh/")) try c.chmod(try paths.inHome(c, ".ssh"), 0o700);
    }
}
// Writes ~/<rel>. The first time that replaces different content, the old file is kept in the
// backup directory.
pub fn write(c: *C, rel: []const u8, content: []const u8, mode: u32) !void {
    return writeAt(c, try paths.inHome(c, rel), content, mode);
}
// The same for an absolute path. A file outside HOME, such as under XDG_CONFIG_HOME, is backed up
// under its full path.
pub fn writeAt(c: *C, dest: []const u8, content: []const u8, mode: u32) !void {
    const home = try c.fmt("{s}/", .{c.home});
    const in_home = std.mem.startsWith(u8, dest, home);
    const rel = if (in_home) dest[home.len..] else std.mem.trimStart(u8, dest, "/");
    const saved = try c.path(&.{ c.home, paths.backup_dir, rel });
    if (!c.exists(saved) and !c.isLink(dest) and c.exists(dest) and !eq(u8, try c.read(dest), content)) {
        try c.copy(dest, saved, 0o600);
        try c.log("Saved your previous {s}{s} to {s}.", .{ if (in_home) "~/" else "/", rel, saved });
    }
    try c.write(dest, content, mode);
}

pub fn verify(c: *C, m: manifest.Manifest, profile: []const u8, checks: *core.Checks) !void {
    for (m.files) |f| if (f.filter.applies(profile)) try checks.file(c, try paths.inHome(c, f.rel));
}

// Copies each managed file from HOME into the checkout. `once` files belong to the machine and stay
// out. Returns the `from` paths, which push may stage besides paths.upload.
pub fn capture(c: *C, m: manifest.Manifest, profile: []const u8) ![]const []const u8 {
    var extra: std.ArrayList([]const u8) = .empty;
    for (m.files) |f| {
        if (f.from) |from| try extra.append(c.a, from);
        if (f.once or !f.filter.applies(profile)) continue;
        const live = try paths.inHome(c, f.rel);
        if (c.exists(live)) try c.copy(live, try f.source(c), 0o644);
    }
    return extra.items;
}

const credential_dirs = [_][]const u8{ ".ssh/", ".cli-proxy-api/" };
const portable_credentials = [_][]const u8{".ssh/config"};

// Fails when the checkout's home/ holds secrets, credentials, or `agent_paths` (the agent settings
// ec writes on the machine), whether or not they are staged. Only ssh's config is portable.
pub fn refusePrivate(c: *C, agent_paths: []const []const u8) !void {
    const listed = try c.capture(&.{ "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", paths.home_dir }, c.repo, 15);
    if (!core.success(listed.term)) return error.GitStatusFailed;
    var prefixes: std.ArrayList([]const u8) = .empty;
    try prefixes.append(c.a, paths.secrets_dir ++ "/");
    try prefixes.appendSlice(c.a, &credential_dirs);
    try prefixes.appendSlice(c.a, agent_paths);
    var names = std.mem.splitScalar(u8, listed.stdout, 0);
    while (names.next()) |name| {
        if (name.len <= paths.home_dir.len) continue;
        const rel = name[paths.home_dir.len + 1 ..];
        if (core.contains(&portable_credentials, rel)) continue;
        for (prefixes.items) |p| {
            const dir = std.mem.endsWith(u8, p, "/");
            if (dir and std.mem.startsWith(u8, rel, p)) return c.fail("Refusing credential or runtime path in the checkout: {s}. Remove it from Git before ec push.", .{name});
            if (!dir and eq(u8, rel, p)) return c.fail("Refusing local agent settings in the checkout: {s}.", .{name});
        }
    }
}
