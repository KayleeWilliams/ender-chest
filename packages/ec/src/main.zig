const std = @import("std");
const core = @import("core.zig");
const options = @import("options.zig");
const manifest = @import("manifest.zig");
const plugin = @import("plugin.zig");
pub const version = @import("build_options").version;
pub fn main(init: std.process.Init) void {
    const a = init.arena.allocator();
    const args = init.minimal.args.toSlice(a) catch std.process.exit(1);
    var c: core.Context = .{ .a = a, .io = init.io, .env = init.environ_map, .home = init.environ_map.get("HOME") orelse "" };
    var diagnostic: []const u8 = "Invalid arguments.";
    const o = options.parseDetailed(args[1..], &diagnostic) catch {
        for (args[1..]) |arg| if (core.eql(u8, arg, "--json")) {
            c.json = true;
        };
        c.error_code = "usage_error";
        if (c.json) c.result("arguments", false, diagnostic) catch {} else c.log("{s}", .{diagnostic}) catch {};
        std.process.exit(2);
    };
    c.json = o.json;
    execute(&c, o) catch |err| {
        const message = c.message orelse (c.fmt("{s} failed: {s}", .{ label(&c, o), @errorName(err) }) catch "Operation failed.");
        if (c.json) c.result(label(&c, o), false, message) catch {} else c.log("{s}", .{message}) catch {};
        std.process.exit(if (core.eql(u8, c.error_code, "usage_error")) 2 else 1);
    };
    if (!o.show_help) @import("update.zig").notice(&c, o.command);
}
fn label(c: *core.Context, o: options.Options) []const u8 {
    return switch (o.command) {
        .plugin, .secret => c.fmt("{s} {s}", .{ @tagName(o.command), o.action }) catch @tagName(o.command),
        .call => if (o.rest.len > 0 and !std.mem.startsWith(u8, o.rest[0], "-")) c.fmt("{s} {s}", .{ o.name, o.rest[0] }) catch o.name else o.name,
        .builtin => if (o.rest.len > 1) c.fmt("{s} {s}", .{ o.rest[0], o.rest[1] }) catch "plugin" else "plugin",
        else => @tagName(o.command),
    };
}
fn execute(c: *core.Context, o: options.Options) !void {
    if (o.command == .builtin) return @import("plugins/builtin.zig").run(c, o.rest);
    if (o.command == .version) {
        const source_hash = @import("build_options").source_hash;
        return c.resultData("version", true, "ec " ++ version ++ " (" ++ source_hash[0..7] ++ ")", .{ .version = version, .source_hash = source_hash });
    }
    if (o.command == .help or (o.show_help and o.command != .call)) return @import("help.zig").show(c, o, enabled(c, o));
    if (c.home.len == 0) return c.fail("HOME is not set.", .{});
    switch (o.command) {
        .status => if (!try @import("fleet.zig").run(c, o)) std.process.exit(1),
        .sync => if (o.all) {
            if (!try @import("fleet.zig").run(c, o)) std.process.exit(1);
        } else try @import("sync.zig").run(c, o),
        .secret => try @import("secrets.zig").run(c, o.action, o.target),
        .update => try @import("update.zig").run(c, o.check),
        .plugin => {
            try @import("sync.zig").resolveRepo(c, o);
            const m = try manifest.load(c);
            if (core.eql(u8, o.action, "update")) return plugin.update(c, m, o.target.?);
            return list(c, try plugin.loadAll(c, m, false));
        },
        .call => try call(c, o),
        else => try @import("sync.zig").run(c, o),
    }
}
// Plugins enabled in the current config, for help. Help works without a checkout, so any
// problem here only leaves plugins out of the listing.
fn enabled(c: *core.Context, o: options.Options) []const plugin.Plugin {
    if (c.home.len == 0) return &.{};
    const quiet = c.json;
    defer c.json = quiet;
    @import("sync.zig").resolveRepo(c, o) catch return &.{};
    const m = manifest.load(c) catch return &.{};
    var list_: std.ArrayList(plugin.Plugin) = .empty;
    for (m.plugins) |entry| {
        const p = plugin.load(c, entry, false) catch continue;
        list_.append(c.a, p) catch return list_.items;
    }
    return list_.items;
}
fn call(c: *core.Context, o: options.Options) !void {
    // Report load and settings errors as JSON too. A passthrough command resets this below.
    for (o.rest) |arg| if (core.eql(u8, arg, "--json")) {
        c.json = true;
    };
    @import("sync.zig").resolveRepo(c, o) catch {
        c.error_code = "usage_error";
        c.message = try c.fmt("Unknown command {s}. Plugin commands need a config checkout with {s}; run ec --help.", .{ o.name, manifest.file_name });
        return error.Reported;
    };
    const m = try manifest.load(c);
    const entry = m.plugin(o.name) orelse {
        c.error_code = "usage_error";
        if (plugin.builtinManifest(o.name) != null) return c.fail("{s} is a built-in plugin that this config does not enable. Add [plugins.{s}] to ender-chest.toml.", .{ o.name, o.name });
        return c.fail("Unknown command {s}. Run ec --help for commands and enabled plugins.", .{o.name});
    };
    const p = try plugin.load(c, entry, false);
    var rest = o.rest;
    if (rest.len == 0 or std.mem.startsWith(u8, rest[0], "-") or core.eql(u8, rest[0], "help")) {
        // `ec quiet --dry-run` runs the default command; `ec wol` and `ec wol --help` show help.
        if (p.default == null or hasHelp(rest)) {
            for (rest) |arg| if (core.eql(u8, arg, "--json")) {
                c.json = true;
            };
            return @import("help.zig").showPlugin(c, p, null);
        }
        const with = try c.a.alloc([]const u8, rest.len + 1);
        with[0] = p.default.?;
        @memcpy(with[1..], rest);
        rest = with;
    }
    const cmd = p.command(rest[0]) orelse {
        c.error_code = "usage_error";
        return c.fail("Unknown {s} command {s}. Run ec {s} --help.", .{ p.name, rest[0], p.name });
    };
    if (cmd.passthrough) {
        // Everything after the command, --json included, belongs to the command.
        c.json = o.json;
    } else if (hasHelp(rest[1..])) return @import("help.zig").showPlugin(c, p, cmd);
    try plugin.invoke(c, p, rest);
}
fn hasHelp(args: []const []const u8) bool {
    for (args) |arg| if (core.eql(u8, arg, "--help") or core.eql(u8, arg, "-h") or core.eql(u8, arg, "help")) return true;
    return false;
}
fn list(c: *core.Context, plugins: []const plugin.Plugin) !void {
    var text: std.ArrayList(u8) = .empty;
    const Row = struct { name: []const u8, source: []const u8, commit: ?[]const u8, commands: []const []const u8, missing: []const []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    for (plugins) |p| {
        var names: std.ArrayList([]const u8) = .empty;
        for (p.commands) |cmd| try names.append(c.a, cmd.name);
        try rows.append(c.a, .{ .name = p.name, .source = p.source, .commit = p.commit, .commands = names.items, .missing = p.missing });
        try text.appendSlice(c.a, try c.fmt("{s:<14} {s}{s}{s}\n", .{ p.name, p.source, if (p.commit) |cm| try c.fmt(" @ {s}", .{cm[0..12]}) else "", if (p.missing.len > 0) try c.fmt("  (needs {s})", .{try std.mem.join(c.a, ", ", p.missing)}) else "" }));
        if (names.items.len > 0) try text.appendSlice(c.a, try c.fmt("{s:<14} commands: {s}\n", .{ "", try std.mem.join(c.a, ", ", names.items) }));
    }
    const message = if (plugins.len == 0) "No plugins enabled. Add [plugins.NAME] to ender-chest.toml." else std.mem.trimEnd(u8, text.items, "\n");
    try c.resultData("plugin list", true, message, .{ .plugins = rows.items });
}
test {
    _ = @import("manifest.zig");
    _ = @import("plugin.zig");
    _ = @import("secrets.zig");
    _ = @import("options.zig");
    _ = @import("config.zig");
    _ = @import("skills.zig");
    _ = @import("update.zig");
    _ = @import("fleet.zig");
    _ = @import("plugins/runtime.zig");
    _ = @import("plugins/builtin.zig");
}
