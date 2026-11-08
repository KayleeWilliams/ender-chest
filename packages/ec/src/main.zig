const std = @import("std");
const core = @import("core.zig");
const cli = @import("options.zig");
const build_info = @import("build_info.zig");
const plugin_cli = @import("plugin_cli.zig");

pub fn main(init: std.process.Init) u8 {
    const a = init.arena.allocator();
    const args = init.minimal.args.toSlice(a) catch return 1;
    var c: core.Context = .{ .a = a, .io = init.io, .env = init.environ_map, .home = init.environ_map.get("HOME") orelse "" };
    var diagnostic: cli.Diagnostic = .{};
    const o = cli.parse(a, args[1..], &diagnostic) catch {
        c.json = diagnostic.json;
        c.print(.{ .command = "arguments", .message = diagnostic.message, .failure = .usage_error, .diagnostic = true }) catch {};
        return core.Code.usage_error.exitCode();
    };
    c.json = o.json;
    const outcome = execute(&c, o) catch |err| c.reported(cli.label(a, o), err);
    c.print(outcome) catch return 1;
    if (outcome.failure) |code| return code.exitCode();
    if (!o.help) if (cli.spec(o.command)) |s| if (s.notice) @import("update.zig").notice(&c);
    return 0;
}
fn execute(c: *core.Context, o: cli.Options) !core.Outcome {
    switch (o.command) {
        .builtin => return @import("plugins/builtin.zig").run(c, o.rest),
        .version => return c.resultData("version", build_info.line, .{ .version = build_info.version, .source_hash = build_info.source_hash }),
        .call => {},
        else => if (o.help or o.command == .help) return @import("help.zig").show(c, o.words, plugin_cli.enabled(c, o.repo)),
    }
    if (c.home.len == 0) return c.fail("HOME is not set.", .{});
    return switch (o.command) {
        .help, .version, .builtin => unreachable,
        .sync => if (o.all) @import("fleet.zig").syncAll(c) else @import("sync.zig").sync(c, o),
        .push => @import("sync.zig").push(c, o),
        .verify => @import("sync.zig").verify(c, o),
        .status => @import("fleet.zig").status(c),
        .update => @import("update.zig").run(c, o.check),
        .plugin_list => plugin_cli.list(c, o),
        .plugin_update => plugin_cli.update(c, o),
        .secret_set => @import("secrets.zig").setCommand(c, o.target.?),
        .secret_list => @import("secrets.zig").listCommand(c),
        .secret_remove => @import("secrets.zig").removeCommand(c, o.target.?),
        .call => plugin_cli.call(c, o),
    };
}
test {
    _ = @import("manifest.zig");
    _ = @import("plugin.zig");
    _ = @import("secrets.zig");
    _ = @import("options.zig");
    _ = @import("help.zig");
    _ = @import("agents.zig");
    _ = @import("json_merge.zig");
    _ = @import("toml_doc.zig");
    _ = @import("github.zig");
    _ = @import("skills.zig");
    _ = @import("update.zig");
    _ = @import("release.zig");
    _ = @import("fleet.zig");
    _ = @import("plugin_manifest.zig");
    _ = @import("plugins/runtime.zig");
    _ = @import("plugins/builtin.zig");
}
