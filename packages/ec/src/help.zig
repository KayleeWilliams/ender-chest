// Help text and JSON command definitions for ec's commands and for plugin commands.
const std = @import("std");
const core = @import("core.zig");
const cli = @import("options.zig");
const build_info = @import("build_info.zig");
const spec = @import("plugin_manifest.zig");
const Option = spec.Option;

const Definition = struct {
    command: []const u8,
    action: []const u8 = "",
    // Set for plugin commands: "built-in", a config repo path, or owner/repo#ref.
    plugin: ?[]const u8 = null,
    usage: []const u8,
    description: []const u8,
    options: []const Option,
    // Plugin settings the command cannot run without.
    needs: []const []const u8 = &.{},
    effects: []const []const u8,
    examples: []const []const u8,
};
const common = blk: {
    var list: [cli.common.len]Option = undefined;
    for (cli.common, 0..) |f, i| list[i] = cli.flags.get(f).option;
    break :blk list;
};
const exit_codes = "\nExit codes: 0 success, 1 operation failed or unreachable, 2 invalid arguments.\n";

fn coreDefinition(c: *core.Context, s: cli.Spec) !Definition {
    var options: std.ArrayList(Option) = .empty;
    for (s.flags) |f| try options.append(c.a, cli.flags.get(f).option);
    try options.appendSlice(c.a, &common);
    return .{ .command = s.group(), .action = s.action(), .usage = s.usage, .description = s.description, .options = options.items, .effects = s.effects, .examples = s.examples };
}
fn pluginDefinition(c: *core.Context, p: spec.Plugin, cmd: spec.Command) !Definition {
    var options: std.ArrayList(Option) = .empty;
    try options.appendSlice(c.a, cmd.options);
    if (!cmd.passthrough) try options.appendSlice(c.a, &common);
    return .{ .command = p.name, .action = cmd.name, .plugin = p.source, .usage = if (cmd.usage.len > 0) cmd.usage else try c.fmt("ec {s} {s} [options]", .{ p.name, cmd.name }), .description = cmd.description, .options = options.items, .needs = cmd.needs, .effects = cmd.effects, .examples = cmd.examples };
}

const Text = struct {
    c: *core.Context,
    buf: std.ArrayList(u8) = .empty,
    fn add(t: *Text, comptime format: []const u8, args: anytype) !void {
        try t.buf.appendSlice(t.c.a, try t.c.fmt(format, args));
    }
    fn options(t: *Text, entries: []const Option) !void {
        for (entries) |entry| {
            try t.row(try t.c.fmt("--{s}{s}", .{ entry.name, if (entry.kind == .string) " <value>" else "" }), entry.description);
            if (entry.values.len > 0) try t.add("                          Values: {s}.\n", .{try std.mem.join(t.c.a, ", ", entry.values)});
            if (entry.default) |value| try t.add("                          Default: {s}.\n", .{value});
        }
    }
    fn row(t: *Text, name: []const u8, description: []const u8) !void {
        try t.add("  {s:<23} {s}\n", .{ name, description });
    }
    fn detail(t: *Text, d: Definition, p: ?spec.Plugin) !void {
        try t.add("{s}\n\nUsage: {s}\n\nOptions:\n", .{ d.description, d.usage });
        try t.options(d.options);
        if (d.needs.len > 0) {
            try t.add("\nNeeds, under [plugins.{s}] in ender-chest.toml:\n", .{d.command});
            for (d.needs) |n| try t.row(n, p.?.setting(n).?.description);
        }
        try t.add("\nEffects:\n", .{});
        for (d.effects) |effect| try t.add("  {s}\n", .{effect});
        try t.add("\nExamples:\n", .{});
        for (d.examples) |example| try t.add("  {s}\n", .{example});
    }
    fn done(t: *Text, entries: []const Definition) !core.Outcome {
        try t.add(exit_codes, .{});
        return t.c.resultData("help", t.buf.items, .{ .command_definitions = entries });
    }
};
fn start(c: *core.Context) !Text {
    var t: Text = .{ .c = c };
    try t.add("ec {s} - ender chest\n\n", .{build_info.version});
    return t;
}

// Help for `words`: "" for every command, a group such as "plugin", or one command.
pub fn show(c: *core.Context, words: []const u8, plugins: []const spec.Plugin) !core.Outcome {
    var t = try start(c);
    var entries: std.ArrayList(Definition) = .empty;
    if (cli.find(words)) |s| {
        const d = try coreDefinition(c, s);
        try entries.append(c.a, d);
        try t.detail(d, null);
        return t.done(entries.items);
    }
    const group = words.len > 0;
    const scope = if (group) try c.fmt("ec {s}", .{words}) else "ec";
    try t.add("Usage: {s} <command> [options]\n\nCommands:\n", .{scope});
    for (cli.specs) |s| {
        if (group and !core.eql(u8, s.group(), words)) continue;
        try entries.append(c.a, try coreDefinition(c, s));
        if (group) try t.add("  {s:<12} {s}\n", .{ s.action(), s.description }) else if (s.action().len == 0 and s.command != .version) try t.add("  {s:<12} {s}\n", .{ s.words, s.description });
    }
    if (!group) {
        for (cli.groups) |g| try t.add("  {s:<12} {s}\n", .{ g.name, g.description });
        if (plugins.len > 0) try t.add("\nPlugins:\n", .{});
        for (plugins) |p| {
            try t.add("  {s:<12} {s}\n", .{ p.name, p.description });
            for (p.commands) |cmd| try entries.append(c.a, try pluginDefinition(c, p, cmd));
        }
    }
    try t.add("\nOptions:\n", .{});
    try t.options(&common);
    if (!group) try t.row("--version", cli.spec(.version).?.description);
    try t.add("\nUse {s} <command> --help for options, effects, and examples.\nAdd --json for structured command definitions.\n", .{scope});
    return t.done(entries.items);
}
// Help for one plugin, or for one of its commands. Reads only the manifest.
pub fn showPlugin(c: *core.Context, p: spec.Plugin, cmd: ?spec.Command) !core.Outcome {
    var t = try start(c);
    var entries: std.ArrayList(Definition) = .empty;
    if (cmd) |one| {
        const d = try pluginDefinition(c, p, one);
        try entries.append(c.a, d);
        try t.detail(d, p);
        return t.done(entries.items);
    }
    try t.add("{s}\n\nUsage: ec {s} <command> [options]\n\nCommands:\n", .{ p.description, p.name });
    for (p.commands) |one| {
        try t.add("  {s:<12} {s}{s}\n", .{ one.name, one.description, if (p.default != null and core.eql(u8, p.default.?, one.name)) " (default)" else "" });
        try entries.append(c.a, try pluginDefinition(c, p, one));
    }
    if (p.settings.len > 0) {
        try t.add("\nSettings, under [plugins.{s}] in ender-chest.toml:\n", .{p.name});
        for (p.settings) |s| try t.add("  {s:<23} {s}{s}{s}\n", .{ s.name, s.description, if (s.required) " Required." else "", if (s.kind == .secret) " Use { secret = \"NAME\" }." else "" });
    }
    try t.add("\nSource: {s}{s}\n", .{ p.source, if (p.commit) |cm| try c.fmt(" @ {s}", .{cm}) else "" });
    try t.add("\nUse ec {s} <command> --help for options, effects, and examples.\n", .{p.name});
    return t.done(entries.items);
}
