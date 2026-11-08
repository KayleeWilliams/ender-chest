// The plugins that ship with ec. ec runs them as `ec __plugin NAME COMMAND`. Each module
// declares `manifest`, its embedded plugin.toml, and `commands`, a namespace with one public
// function per command the manifest declares, returning the command's outcome.
const std = @import("std");
const core = @import("../core.zig");
const spec = @import("../plugin_manifest.zig");
const runtime = @import("runtime.zig");

const modules = .{
    .cliproxyapi = @import("cliproxyapi.zig"),
    .executor = @import("executor.zig"),
    .kde = @import("kde.zig"),
    .quiet = @import("quiet.zig"),
    .wol = @import("wol.zig"),
};
const names = std.meta.fieldNames(@TypeOf(modules));

pub fn manifest(name: []const u8) ?[]const u8 {
    inline for (names) |n| if (core.eql(u8, n, name)) return @field(modules, n).manifest;
    return null;
}

pub fn run(c: *core.Context, args: []const []const u8) !core.Outcome {
    if (args.len == 0) return c.fail("ec __plugin is run by ec itself.", .{});
    inline for (names) |n| if (core.eql(u8, n, args[0])) {
        const module = @field(modules, n);
        const call = try runtime.read(c, module.manifest, args[1..]);
        inline for (@typeInfo(module.commands).@"struct".decls) |d| if (core.eql(u8, d.name, call.command.name)) {
            return @field(module.commands, d.name)(c, call);
        };
        unreachable;
    };
    return c.fail("No built-in plugin named {s}.", .{args[0]});
}

test "each built-in has exactly the commands its manifest declares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (names) |n| {
        const module = @field(modules, n);
        const p = try spec.parse(arena.allocator(), module.manifest);
        try std.testing.expectEqualStrings(n, p.name);
        try std.testing.expectEqualStrings("", p.run);
        const decls = @typeInfo(module.commands).@"struct".decls;
        try std.testing.expectEqual(p.commands.len, decls.len);
        inline for (decls) |d| try std.testing.expect(p.command(d.name) != null);
    }
}
test {
    inline for (names) |n| _ = @field(modules, n);
}
