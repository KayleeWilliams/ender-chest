const std = @import("std");
const core = @import("core.zig");
const options = @import("options.zig");
pub const version = @import("build_options").version;
pub fn main(init: std.process.Init) void {
    const a = init.arena.allocator();
    const args = init.minimal.args.toSlice(a) catch std.process.exit(1);
    var c: core.Context = .{ .a = a, .io = init.io, .env = init.environ_map, .home = init.environ_map.get("HOME") orelse "" };
    for (args[1..]) |arg| if (core.eql(u8, arg, "--json")) {
        c.json = true;
    };
    var diagnostic: []const u8 = "Invalid arguments.";
    const o = options.parseDetailed(args[1..], &diagnostic) catch {
        c.error_code = "usage_error";
        if (c.json) c.result("arguments", false, diagnostic) catch {} else c.log("{s}", .{diagnostic}) catch {};
        std.process.exit(2);
    };
    // A --json after ec cliproxy run belongs to that command, not to ec.
    c.json = o.json;
    execute(&c, o) catch |err| {
        const message = c.message orelse (c.fmt("{s} failed: {s}", .{ @tagName(o.command), @errorName(err) }) catch "Operation failed.");
        const command = if (o.command == .desktop or o.command == .fleet or o.command == .cliproxy) c.fmt("{s} {s}", .{ @tagName(o.command), @tagName(o.action) }) catch @tagName(o.command) else @tagName(o.command);
        if (c.json) c.result(command, false, message) catch {} else c.log("{s}", .{message}) catch {};
        std.process.exit(1);
    };
}
fn execute(c: *core.Context, o: options.Options) !void {
    if (o.show_help or o.command == .help or ((o.command == .desktop or o.command == .cliproxy) and o.action == .help)) return @import("help.zig").show(c, o);
    switch (o.command) {
        .help => unreachable,
        .version => {
            const source_hash = @import("build_options").source_hash;
            try c.resultData("version", true, "ec " ++ version ++ " (" ++ source_hash[0..7] ++ ")", .{ .version = version, .source_hash = source_hash });
        },
        .desktop => {
            if (c.home.len == 0) return c.fail("HOME is not set.", .{});
            if (!try @import("desktop.zig").run(c, o)) std.process.exit(1);
        },
        .fleet => {
            if (c.home.len == 0) return c.fail("HOME is not set.", .{});
            if (!try @import("fleet.zig").run(c, o)) std.process.exit(1);
        },
        .cliproxy => {
            if (c.home.len == 0) return c.fail("HOME is not set.", .{});
            if (!try @import("cliproxy.zig").run(c, o)) std.process.exit(1);
        },
        else => {
            if (c.home.len == 0) return c.fail("HOME is not set.", .{});
            try @import("sync.zig").run(c, o);
        },
    }
}
test {
    _ = @import("options.zig");
    _ = @import("desktop.zig");
    _ = @import("config.zig");
    _ = @import("skills.zig");
    _ = @import("update.zig");
    _ = @import("fleet.zig");
    _ = @import("cliproxy.zig");
    _ = @import("credentials.zig");
}
