// Plugins on ec's command line: `ec NAME [COMMAND]`, `ec plugin list`, `ec plugin update NAME`,
// and the plugins that top-level help lists.
const std = @import("std");
const core = @import("core.zig");
const cli = @import("options.zig");
const manifest = @import("manifest.zig");
const plugin = @import("plugin.zig");
const builtin = @import("plugins/builtin.zig");
const Plugin = @import("plugin_manifest.zig").Plugin;
const checkout = @import("checkout.zig");
const paths = @import("paths.zig");
const help = @import("help.zig");
const C = core.Context;
const eq = core.eql;

// Plugins enabled in the current config. Help works without a checkout, so any problem here only
// leaves plugins out of the listing.
pub fn enabled(c: *C, repo: ?[]const u8) []const Plugin {
    if (c.home.len == 0) return &.{};
    c.repo = checkout.resolve(c, repo) catch return &.{};
    const m = manifest.load(c) catch return &.{};
    var found: std.ArrayList(Plugin) = .empty;
    for (m.plugins) |entry| {
        const e = plugin.load(c, entry, false) catch continue;
        found.append(c.a, e.plugin) catch return found.items;
    }
    return found.items;
}

pub fn call(c: *C, o: cli.Options) !core.Outcome {
    // Until the command is known, --json anywhere asks for a JSON result, so load errors are JSON too.
    c.json = o.json or core.contains(o.rest, "--json");
    c.repo = checkout.resolve(c, o.repo) catch return c.failCode(.usage_error, "Unknown command {s}. Plugin commands need a config checkout with {s}; run ec --help.", .{ o.name, paths.manifest_file });
    const m = try manifest.load(c);
    const entry = m.plugin(o.name) orelse {
        if (builtin.manifest(o.name) != null) return c.failCode(.usage_error, "{s} is a built-in plugin that this config does not enable. Add [plugins.{s}] to ender-chest.toml.", .{ o.name, o.name });
        return c.failCode(.usage_error, "Unknown command {s}. Run ec --help for commands and enabled plugins.", .{o.name});
    };
    const e = try plugin.load(c, entry, false);
    const p = e.plugin;
    var rest = o.rest;
    const named = rest.len > 0 and rest[0].len > 0 and rest[0][0] != '-' and !cli.isHelp(rest[0]);
    if (!named) {
        // `ec quiet --dry-run` runs the default command; `ec wol` and `ec wol --help` show help.
        if (p.default == null or o.help or wantsHelp(rest)) return help.showPlugin(c, p, null);
        const with = try c.a.alloc([]const u8, rest.len + 1);
        with[0] = p.default.?;
        @memcpy(with[1..], rest);
        rest = with;
    }
    const cmd = p.command(rest[0]) orelse return c.failCode(.usage_error, "Unknown {s} command {s}. Run ec {s} --help.", .{ p.name, rest[0], p.name });
    // Everything after a passthrough command, --json and --help included, belongs to the command.
    if (cmd.passthrough) {
        c.json = o.json;
    } else if (o.help or wantsHelp(rest[1..])) return help.showPlugin(c, p, cmd);
    try plugin.invoke(c, e, cmd, rest[1..]);
}

pub fn list(c: *C, o: cli.Options) !core.Outcome {
    c.repo = try checkout.resolve(c, o.repo);
    const plugins = try plugin.loadAll(c, try manifest.load(c), false);
    var text: std.ArrayList(u8) = .empty;
    const Row = struct { name: []const u8, source: []const u8, commit: ?[]const u8, commands: []const []const u8, missing: []const []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    for (plugins) |e| {
        const p = e.plugin;
        var names: std.ArrayList([]const u8) = .empty;
        for (p.commands) |cmd| try names.append(c.a, cmd.name);
        try rows.append(c.a, .{ .name = p.name, .source = p.source, .commit = p.commit, .commands = names.items, .missing = e.missing });
        try text.appendSlice(c.a, try c.fmt("{s:<14} {s}{s}{s}\n", .{ p.name, p.source, if (p.commit) |cm| try c.fmt(" @ {s}", .{cm[0..12]}) else "", if (e.missing.len > 0) try c.fmt("  (needs {s})", .{try std.mem.join(c.a, ", ", e.missing)}) else "" }));
        if (names.items.len > 0) try text.appendSlice(c.a, try c.fmt("{s:<14} commands: {s}\n", .{ "", try std.mem.join(c.a, ", ", names.items) }));
    }
    const message = if (plugins.len == 0) "No plugins enabled. Add [plugins.NAME] to ender-chest.toml." else std.mem.trimEnd(u8, text.items, "\n");
    return c.resultData("plugin list", message, .{ .plugins = rows.items });
}

pub fn update(c: *C, o: cli.Options) !core.Outcome {
    c.repo = try checkout.resolve(c, o.repo);
    const name = o.target.?;
    const f = try plugin.update(c, try manifest.load(c), name);
    if (f.old != null and eq(u8, f.old.?, f.commit)) return c.result("plugin update", try c.fmt("{s} is already at {s}.", .{ name, f.commit[0..12] }));
    const compare = if (f.old) |old| try c.fmt("https://github.com/{s}/compare/{s}...{s}", .{ f.slug, old, f.commit }) else try c.fmt("https://github.com/{s}/commit/{s}", .{ f.slug, f.commit });
    return c.resultData("plugin update", try c.fmt("Updated {s} to {s}. Review the changes before you commit {s}: {s}", .{ name, f.commit[0..12], paths.lock_file, compare }), .{ .plugin = name, .old = f.old, .new = f.commit, .compare = compare });
}
fn wantsHelp(args: []const []const u8) bool {
    for (args) |a| if (cli.isHelp(a)) return true;
    return false;
}
