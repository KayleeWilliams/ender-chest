// Built-in plugins run as `ec __plugin NAME COMMAND [options]` with the environment described in
// docs/plugins.md. This file reads that environment, as an external plugin would, and checks
// each read against the plugin's manifest.
const std = @import("std");
const core = @import("../core.zig");
const spec = @import("../plugin_manifest.zig");
const C = core.Context;
const eq = core.eql;

// The variables ec sets for a plugin call. They describe this call only, so commands that a
// plugin starts do not inherit them.
const protocol_vars = [_][]const u8{ "EC_PROTOCOL", "EC_PLUGIN", "EC_PLUGIN_DIR", "EC_PLUGIN_SETTINGS", "EC_JSON", "EC_BIN" };

pub const Call = struct {
    plugin: spec.Plugin,
    command: spec.Command,
    // Everything after the command. A passthrough command reads these; others read `options`.
    args: []const []const u8,
    options: []const spec.Arg = &.{},
    settings: std.json.Value,
    // The ec that ran this plugin.
    ec_bin: []const u8,

    pub fn flag(call: Call, name: []const u8) bool {
        call.declaredOption(name, .boolean);
        for (call.options) |o| if (eq(u8, o.name, name)) return true;
        return false;
    }
    pub fn option(call: Call, name: []const u8) ?[]const u8 {
        call.declaredOption(name, .string);
        for (call.options) |o| if (eq(u8, o.name, name)) return o.value;
        return null;
    }
    pub fn setting(call: Call, name: []const u8) ?[]const u8 {
        _ = call.declaredSetting(name);
        return core.string(call.settings, name);
    }
    // A text setting the manifest guarantees for this command: required, needed, or defaulted.
    pub fn string(call: Call, name: []const u8) []const u8 {
        if (!call.guaranteed(call.declaredSetting(name))) std.debug.panic("{s} {s} reads {s}, which its manifest does not guarantee.", .{ call.plugin.name, call.command.name, name });
        return core.string(call.settings, name).?;
    }
    pub fn integer(call: Call, name: []const u8) i64 {
        if (!call.guaranteed(call.declaredSetting(name))) std.debug.panic("{s} {s} reads {s}, which its manifest does not guarantee.", .{ call.plugin.name, call.command.name, name });
        return call.settings.object.get(name).?.integer;
    }
    pub fn duration(call: Call, c: *C, name: []const u8) !i64 {
        const n = call.integer(name);
        if (n < 1 or n > 3600) return c.fail("Invalid {s}. Use 1 to 3600.", .{name});
        return n;
    }

    fn guaranteed(call: Call, s: spec.Setting) bool {
        return s.default != null or s.neededBy(call.command);
    }
    fn declaredSetting(call: Call, name: []const u8) spec.Setting {
        return call.plugin.setting(name) orelse std.debug.panic("{s} has no setting named {s}.", .{ call.plugin.name, name });
    }
    fn declaredOption(call: Call, name: []const u8, kind: @FieldType(spec.Option, "kind")) void {
        const o = call.command.option(name) orelse std.debug.panic("{s} {s} has no option --{s}.", .{ call.plugin.name, call.command.name, name });
        if (o.kind != kind) std.debug.panic("--{s} of {s} {s} is a {s} option.", .{ name, call.plugin.name, call.command.name, @tagName(o.kind) });
    }
};

// Reads a call to the built-in plugin whose manifest is `manifest` from argv (after `__plugin
// NAME`) and the environment, then removes ec's call variables from the environment.
pub fn read(c: *C, manifest: []const u8, args: []const []const u8) !Call {
    const p = spec.parse(c.a, manifest) catch unreachable;
    const named = if (args.len > 0) p.command(args[0]) else null;
    const usage = "ec __plugin is run by ec itself. Use ec {s} {s}.";
    const words = .{ p.name, if (named) |cmd| cmd.name else "COMMAND" };
    const cmd = named orelse return c.fail(usage, words);
    const text = c.env.get("EC_PLUGIN_SETTINGS") orelse return c.fail(usage, words);
    const settings = c.parse(text) catch return c.fail("EC_PLUGIN_SETTINGS is not a JSON object.", .{});
    if (settings != .object) return c.fail("EC_PLUGIN_SETTINGS is not a JSON object.", .{});
    var at: []const u8 = "";
    const options = if (cmd.passthrough) &.{} else spec.readArgs(c.a, cmd, args[1..], &at) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return c.fail(usage, words),
    };
    const call: Call = .{ .plugin = p, .command = cmd, .args = args[1..], .options = options, .settings = settings, .ec_bin = if (c.env.get("EC_BIN")) |bin| try c.a.dupe(u8, bin) else try std.process.executablePathAlloc(c.io, c.a) };
    for (p.settings) |s| if (call.guaranteed(s) and settings.object.get(s.name) == null) return c.fail(usage, words);
    if (c.env.get("EC_JSON")) |v| c.json = eq(u8, v, "1");
    // Removing a variable frees its value, so `call` keeps copies of what it needs.
    for (protocol_vars) |name| _ = c.env.swapRemove(name);
    return call;
}

test "options read the forms ec validated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const command: spec.Command = .{ .name = "c", .options = &.{ .{ .name = "no-wait" }, .{ .name = "local" }, .{ .name = "via", .kind = .string }, .{ .name = "mode", .kind = .string }, .{ .name = "missing", .kind = .string } } };
    var at: []const u8 = "";
    const options = try spec.readArgs(arena.allocator(), command, &.{ "--no-wait", "--via", "user@relay", "--mode=fast" }, &at);
    const x: Call = .{ .plugin = .{ .name = "p", .commands = &.{command} }, .command = command, .args = &.{}, .options = options, .settings = .null, .ec_bin = "ec" };
    try std.testing.expect(x.flag("no-wait") and !x.flag("local"));
    try std.testing.expectEqualStrings("user@relay", x.option("via").?);
    try std.testing.expectEqualStrings("fast", x.option("mode").?);
    try std.testing.expect(x.option("missing") == null);
}
