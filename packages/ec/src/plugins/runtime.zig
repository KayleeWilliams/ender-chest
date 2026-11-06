// Built-in plugins run as `ec __plugin NAME COMMAND [options]` with the environment described in
// docs/plugins.md. This file reads that environment, as an external plugin would.
const std = @import("std");
const core = @import("../core.zig");
const C = core.Context;
const eq = core.eql;

pub const Call = struct {
    plugin: []const u8,
    command: []const u8,
    // Options as the user passed them, already validated against the manifest.
    args: []const []const u8,
    settings: std.json.Value,

    pub fn flag(call: Call, name: []const u8) bool {
        for (call.args) |arg| {
            if (std.mem.startsWith(u8, arg, "--") and eq(u8, arg[2..], name)) return true;
        }
        return false;
    }
    pub fn option(call: Call, name: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < call.args.len) : (i += 1) {
            const arg = call.args[i];
            if (!std.mem.startsWith(u8, arg, "--")) continue;
            const body = arg[2..];
            if (std.mem.indexOfScalar(u8, body, '=')) |pos| {
                if (eq(u8, body[0..pos], name)) return body[pos + 1 ..];
            } else if (eq(u8, body, name) and i + 1 < call.args.len) return call.args[i + 1];
        }
        return null;
    }
    pub fn setting(call: Call, name: []const u8) ?[]const u8 {
        return core.string(call.settings, name);
    }
    pub fn integer(call: Call, name: []const u8) ?i64 {
        if (call.settings != .object) return null;
        const v = call.settings.object.get(name) orelse return null;
        return if (v == .integer) v.integer else null;
    }
};

// Reads the call from argv (after `__plugin`) and EC_PLUGIN_SETTINGS.
pub fn read(c: *C, args: []const []const u8) !Call {
    if (args.len < 2) return c.fail("ec __plugin needs a plugin and a command. It is run by ec itself.", .{});
    const text = c.env.get("EC_PLUGIN_SETTINGS") orelse return c.fail("ec __plugin is run by ec itself. Use ec {s} {s}.", .{ args[0], args[1] });
    const settings = c.parse(text) catch return c.fail("EC_PLUGIN_SETTINGS is not a JSON object.", .{});
    if (settings != .object) return c.fail("EC_PLUGIN_SETTINGS is not a JSON object.", .{});
    if (c.env.get("EC_JSON")) |v| c.json = eq(u8, v, "1");
    if (c.env.get("EC_REPO")) |r| c.repo = r;
    return .{ .plugin = args[0], .command = args[1], .args = args[2..], .settings = settings };
}

test "options read the forms ec validated" {
    const settings: std.json.Value = .null;
    const x: Call = .{ .plugin = "p", .command = "c", .args = &.{ "--no-wait", "--via", "user@relay", "--mode=fast" }, .settings = settings };
    try std.testing.expect(x.flag("no-wait") and !x.flag("local"));
    try std.testing.expectEqualStrings("user@relay", x.option("via").?);
    try std.testing.expectEqualStrings("fast", x.option("mode").?);
    try std.testing.expect(x.option("missing") == null);
}
