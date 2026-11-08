// Brewfiles and setup steps from ender-chest.toml. ec sync --skip-packages skips both.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const paths = @import("paths.zig");
const manifest = @import("manifest.zig");
const C = core.Context;

pub fn apply(c: *C, m: manifest.Manifest, p: []const u8, skip: bool) !void {
    if (skip) {
        try c.log("Skipping packages and setup steps.", .{});
        return;
    }
    var brewfiles: std.ArrayList([]const u8) = .empty;
    for (m.brewfiles) |b| if (b.filter.applies(p)) try brewfiles.append(c.a, try paths.inRepo(c, b.path));
    if (brewfiles.items.len > 0) {
        if (builtin.os.tag == .macos and !c.commandExists("brew")) {
            try c.command(&.{ "/bin/bash", "-c", "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | bash" }, null);
            for ([_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin" }) |dir| {
                if (c.exists(try c.path(&.{ dir, "brew" }))) {
                    try c.env.put("PATH", try c.fmt("{s}:{s}", .{ dir, c.env.get("PATH") orelse "" }));
                    break;
                }
            }
        }
        if (c.commandExists("brew")) {
            try c.env.put("HOMEBREW_NO_AUTO_UPDATE", "1");
            for (brewfiles.items) |file| try c.command(&.{ "brew", "bundle", try c.fmt("--file={s}", .{file}), "--no-upgrade" }, null);
        } else try c.log("Homebrew is not installed; skipping Brewfiles.", .{});
    }
    for (m.setup) |step| {
        if (!step.filter.applies(p)) continue;
        if (step.creates) |path| if (c.exists(try manifest.expand(c, path))) continue;
        try c.log("Setup: {s}", .{step.name});
        const r = try c.capture(&.{ "/bin/sh", "-c", step.run }, c.repo, 900);
        try c.forward(r);
        if (!core.success(r.term)) return c.fail("Setup step \"{s}\" failed. Check the output above, or run ec sync --skip-packages.", .{step.name});
    }
}
