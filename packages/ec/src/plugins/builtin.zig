// Entry point for `ec __plugin NAME COMMAND`, which ec runs for built-in plugins.
const std = @import("std");
const core = @import("../core.zig");
const runtime = @import("runtime.zig");
const eq = core.eql;

pub fn run(c: *core.Context, args: []const []const u8) !void {
    const call = try runtime.read(c, args);
    const ok = if (eq(u8, call.plugin, "wol"))
        try @import("wol.zig").run(c, call)
    else if (eq(u8, call.plugin, "kde"))
        try @import("kde.zig").run(c, call)
    else if (eq(u8, call.plugin, "cliproxyapi"))
        try @import("cliproxyapi.zig").run(c, call)
    else if (eq(u8, call.plugin, "executor"))
        try @import("executor.zig").run(c, call)
    else if (eq(u8, call.plugin, "quiet"))
        try @import("quiet.zig").run(c, call)
    else
        return c.fail("No built-in plugin named {s}.", .{call.plugin});
    // A false result has already reported its outcome, such as an unreachable host.
    if (!ok) std.process.exit(1);
}
test {
    _ = @import("wol.zig");
    _ = @import("kde.zig");
    _ = @import("cliproxyapi.zig");
    _ = @import("executor.zig");
    _ = @import("quiet.zig");
}
