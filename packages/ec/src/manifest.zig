// Reads ender-chest.toml, the file that marks a config checkout and lists what sync applies.
const std = @import("std");
const builtin = @import("builtin");
const toml_doc = @import("toml_doc.zig");
const core = @import("core.zig");
const paths = @import("paths.zig");
const C = core.Context;
const Table = toml_doc.Table;
const str = toml_doc.str;

pub const Filter = struct {
    os: ?[]const u8 = null,
    profiles: []const []const u8 = &.{},
    pub fn applies(f: Filter, profile: []const u8) bool {
        if (f.os) |os| if (!core.eql(u8, os, @tagName(builtin.os.tag))) return false;
        if (f.profiles.len == 0) return true;
        for (f.profiles) |p| if (core.eql(u8, p, profile)) return true;
        return false;
    }
};
// A file copied from home/<rel>, or from `from`, to ~/<rel>. A `once` file is created when
// missing and then left to the machine: sync never overwrites it and push never captures it.
pub const File = struct {
    rel: []const u8,
    mode: u32 = 0o644,
    from: ?[]const u8 = null,
    once: bool = false,
    filter: Filter = .{},
    // The copy in the checkout.
    pub fn source(f: File, c: *C) ![]const u8 {
        return if (f.from) |from| paths.inRepo(c, from) else c.path(&.{ c.repo, paths.home_dir, f.rel });
    }
};
// A shell command run from the checkout on each sync, unless `creates` already exists.
pub const Step = struct { name: []const u8, run: []const u8, creates: ?[]const u8 = null, filter: Filter = .{} };
pub const Brewfile = struct { path: []const u8, filter: Filter = .{} };
pub const PluginEntry = struct { name: []const u8, source: ?[]const u8 = null, settings: *const Table };
pub const Manifest = struct {
    files: []const File = &.{},
    setup: []const Step = &.{},
    brewfiles: []const Brewfile = &.{},
    plugins: []const PluginEntry = &.{},
    pub fn plugin(m: Manifest, name: []const u8) ?PluginEntry {
        for (m.plugins) |p| if (core.eql(u8, p.name, name)) return p;
        return null;
    }
};

pub fn load(c: *C) !Manifest {
    const file = try paths.inRepo(c, paths.manifest_file);
    const text = try c.optional(file) orelse return c.fail("No {s} in {s}. Every config repo needs one; start from https://github.com/KayleeWilliams/ender-chest-template.", .{ paths.manifest_file, c.repo });
    return parse(c.a, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => c.fail("Invalid {s}: {s}.", .{ paths.manifest_file, describe(err) }),
    };
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidFile => "files is a list of paths, or tables with a path",
        error.InvalidMode => "file mode must be an octal string such as \"600\"",
        error.InvalidOnce => "once must be true or false",
        error.InvalidPath => "paths must be relative, without .. or leading dashes",
        error.InvalidStep => "each [[setup]] step needs a name and a run command",
        error.InvalidBrewfile => "packages.brewfiles entries are paths or tables with a path",
        error.InvalidPlugin => "each [plugins.NAME] needs a table, and NAME may use letters, digits, - and _",
        error.InvalidFilter => "os must be macos or linux, and profiles a list of names",
        else => "check its TOML syntax",
    };
}

pub fn parse(a: std.mem.Allocator, text: []const u8) !Manifest {
    // The parsed tables live in `a`, an arena; plugin settings point into them.
    const root = try toml_doc.parse(a, text);
    var m: Manifest = .{};

    if (root.get("files")) |v| {
        if (v != .array) return error.InvalidFile;
        var files: std.ArrayList(File) = .empty;
        for (v.array.items) |item| {
            const f: File = switch (item) {
                .string => |rel| .{ .rel = rel },
                .table => |t| blk: {
                    var f: File = .{ .rel = str(t, "path") orelse return error.InvalidFile, .filter = try filter(a, t) };
                    if (t.get("mode")) |mode| f.mode = try parseMode(mode);
                    if (str(t, "from")) |from| {
                        if (!safeRel(from)) return error.InvalidPath;
                        f.from = from;
                    }
                    if (t.get("once")) |once| f.once = if (once == .boolean) once.boolean else return error.InvalidOnce;
                    break :blk f;
                },
                else => return error.InvalidFile,
            };
            if (!safeRel(f.rel)) return error.InvalidPath;
            try files.append(a, f);
        }
        m.files = files.items;
    }
    if (root.get("setup")) |v| {
        if (v != .array) return error.InvalidStep;
        var steps: std.ArrayList(Step) = .empty;
        for (v.array.items) |item| {
            if (item != .table) return error.InvalidStep;
            const name = str(item.table, "name") orelse return error.InvalidStep;
            const run = str(item.table, "run") orelse return error.InvalidStep;
            try steps.append(a, .{ .name = name, .run = run, .creates = str(item.table, "creates"), .filter = try filter(a, item.table) });
        }
        m.setup = steps.items;
    }
    if (root.get("packages")) |v| {
        if (v != .table) return error.InvalidBrewfile;
        if (v.table.get("brewfiles")) |list| {
            if (list != .array) return error.InvalidBrewfile;
            var brewfiles: std.ArrayList(Brewfile) = .empty;
            for (list.array.items) |item| {
                const b: Brewfile = switch (item) {
                    .string => |s| .{ .path = s },
                    .table => |t| .{ .path = str(t, "path") orelse return error.InvalidBrewfile, .filter = try filter(a, t) },
                    else => return error.InvalidBrewfile,
                };
                if (!safeRel(b.path)) return error.InvalidPath;
                try brewfiles.append(a, b);
            }
            m.brewfiles = brewfiles.items;
        }
    }
    if (root.get("plugins")) |v| {
        if (v != .table) return error.InvalidPlugin;
        var plugins: std.ArrayList(PluginEntry) = .empty;
        for (try toml_doc.sortedKeys(a, v.table)) |name| {
            const entry = v.table.get(name).?;
            if (entry != .table or !@import("plugin_manifest.zig").pluginName(name)) return error.InvalidPlugin;
            // `source` says where the plugin comes from; every other key is a setting.
            const source = str(entry.table, "source");
            _ = entry.table.remove("source");
            try plugins.append(a, .{ .name = name, .source = source, .settings = entry.table });
        }
        m.plugins = plugins.items;
    }
    return m;
}

pub fn safeRel(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or p[0] == '-' or p[0] == '~') return false;
    var parts = std.mem.splitScalar(u8, p, '/');
    while (parts.next()) |part| if (part.len == 0 or core.eql(u8, part, "..") or core.eql(u8, part, ".")) return false;
    for (p) |ch| if (ch < 32 or ch == 127 or ch == '\\') return false;
    return true;
}
fn filter(a: std.mem.Allocator, t: *const Table) !Filter {
    var f: Filter = .{};
    if (t.get("os")) |os| {
        if (os != .string or !(core.eql(u8, os.string, "macos") or core.eql(u8, os.string, "linux"))) return error.InvalidFilter;
        f.os = os.string;
    }
    if (toml_doc.strings(a, t, "profiles") catch |err| return if (err == error.OutOfMemory) err else error.InvalidFilter) |p| f.profiles = p;
    return f;
}
fn parseMode(v: toml_doc.Value) !u32 {
    if (v != .string) return error.InvalidMode;
    const mode = std.fmt.parseInt(u32, v.string, 8) catch return error.InvalidMode;
    if (mode == 0 or mode > 0o777) return error.InvalidMode;
    return mode;
}
pub fn expand(c: *C, p: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, p, "~/")) return paths.inHome(c, p[2..]);
    if (std.fs.path.isAbsolute(p)) return p;
    return paths.inRepo(c, p);
}

test "manifest lists files, steps, brewfiles, and plugins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(),
        \\files = [
        \\  ".zshrc",
        \\  { path = ".ssh/config", mode = "600" },
        \\  { path = ".config/zed/settings.json", os = "macos" },
        \\  { path = ".gitconfig.local", from = "git/gitconfig.local.example", once = true },
        \\]
        \\[packages]
        \\brewfiles = ["tools/Brewfile", { path = "tools/Brewfile.mac", profiles = ["mac"] }]
        \\[[setup]]
        \\name = "Oh My Zsh"
        \\creates = "~/.oh-my-zsh"
        \\run = "sh install.sh"
        \\[plugins.wol]
        \\mac = "00:00:5e:00:53:01"
        \\[plugins.hello]
        \\source = "plugins/hello"
    );
    try std.testing.expectEqual(@as(usize, 4), m.files.len);
    try std.testing.expectEqualStrings(".zshrc", m.files[0].rel);
    try std.testing.expectEqual(@as(u32, 0o600), m.files[1].mode);
    try std.testing.expectEqualStrings("macos", m.files[2].filter.os.?);
    try std.testing.expect(m.files[3].once and core.eql(u8, m.files[3].from.?, "git/gitconfig.local.example"));
    try std.testing.expect(m.brewfiles[1].filter.applies("mac") and !m.brewfiles[1].filter.applies("cloud"));
    try std.testing.expectEqualStrings("~/.oh-my-zsh", m.setup[0].creates.?);
    try std.testing.expectEqualStrings("plugins/hello", m.plugin("hello").?.source.?);
    try std.testing.expect(m.plugin("wol").?.source == null);
}
test "manifest rejects paths that leave the checkout or home, and invalid values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidPath, parse(arena.allocator(), "files = [\"../.zshrc\"]\n"));
    try std.testing.expectError(error.InvalidPath, parse(arena.allocator(), "files = [\"/etc/passwd\"]\n"));
    try std.testing.expectError(error.InvalidMode, parse(arena.allocator(), "files = [{ path = \".x\", mode = \"999\" }]\n"));
    try std.testing.expectError(error.InvalidOnce, parse(arena.allocator(), "files = [{ path = \".x\", once = \"true\" }]\n"));
    try std.testing.expectError(error.InvalidPlugin, parse(arena.allocator(), "[plugins.\"../x\"]\n"));
}
