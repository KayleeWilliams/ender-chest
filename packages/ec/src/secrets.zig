// Secrets that plugin settings reference with { secret = "NAME" }. Each is a file under
// ~/.config/ender-chest/secrets, mode 0600, in a 0700 directory. They never enter the config repo.
const std = @import("std");
const core = @import("core.zig");
const paths = @import("paths.zig");
const C = core.Context;

const max_len = 16384;

fn valid(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}
fn dir(c: *C) ![]const u8 {
    const d = try paths.inHome(c, paths.secrets_dir);
    if (c.isLink(d)) return c.fail("Refusing a symlinked secrets directory at {s}.", .{d});
    return d;
}
fn file(c: *C, name: []const u8) ![]const u8 {
    if (!valid(name)) return c.fail("Invalid secret name {s}. Use letters, digits, - and _.", .{name});
    return c.path(&.{ try dir(c), name });
}
fn refuseLink(c: *C, f: []const u8) !void {
    if (c.isLink(f)) return c.fail("Refusing a symlinked secret at {s}.", .{f});
}
pub fn get(c: *C, name: []const u8) !?[]const u8 {
    const f = try file(c, name);
    try refuseLink(c, f);
    const d = std.fs.path.dirname(f).?;
    const text = try c.optional(f) orelse return null;
    const value = std.mem.trimEnd(u8, text, "\r\n");
    if (value.len == 0) return null;
    try c.chmod(d, 0o700);
    try c.chmod(f, 0o600);
    return value;
}
fn set(c: *C, name: []const u8, value: []const u8) !void {
    const f = try file(c, name);
    if (value.len == 0 or value.len > max_len) return c.fail("A secret must be 1 to {d} bytes.", .{max_len});
    for (value) |ch| if (ch < 32 and ch != '\t') return c.fail("A secret must be one line.", .{});
    const d = std.fs.path.dirname(f).?;
    try c.mkdir(d);
    try c.chmod(d, 0o700);
    try refuseLink(c, f);
    try c.write(f, try c.fmt("{s}\n", .{value}), 0o600);
}
fn remove(c: *C, name: []const u8) !bool {
    const f = try file(c, name);
    const existed = c.exists(f);
    try c.remove(f);
    return existed;
}
fn list(c: *C) ![]const []const u8 {
    const d = try dir(c);
    var names: std.ArrayList([]const u8) = .empty;
    var handle = core.cwd().openDir(c.io, d, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names.items,
        else => return c.fail("Cannot read {s}: {s}.", .{ d, @errorName(err) }),
    };
    defer handle.close(c.io);
    var it = handle.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind == .file and valid(entry.name)) try names.append(c.a, try c.a.dupe(u8, entry.name));
    }
    core.sortStrings(names.items);
    return names.items;
}
// Reads one byte past the limit, so set can reject a value that is too long.
fn read(c: *C, name: []const u8) ![]u8 {
    if (!(std.Io.File.stdin().isTty(c.io) catch false)) {
        var buffer: [max_len + 1]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(c.io, &buffer);
        return reader.interface.allocRemaining(c.a, .limited(max_len + 1)) catch c.fail("Cannot read the secret from stdin.", .{});
    }
    if (c.json) return c.failCode(.interaction_required, "Pipe the secret on stdin, or run ec secret set in a terminal without --json.", .{});
    const script =
        \\set -eu
        \\exec 3<>/dev/tty
        \\saved=$(stty -g <&3)
        \\trap 'stty "$saved" <&3; printf "\n" >&3' EXIT
        \\trap 'exit 1' HUP INT TERM
        \\stty -echo <&3
        \\printf '%s: ' "$1" >&3
        \\IFS= read -r value <&3
        \\printf '%s' "$value"
    ;
    const r = try std.process.run(c.a, c.io, .{ .argv = &.{ "/bin/sh", "-c", script, "sh", name }, .environ_map = c.env, .stdout_limit = .limited(max_len + 1), .stderr_limit = .limited(4096) });
    if (!core.success(r.term)) return c.failCode(.interaction_required, "Could not read a secret. Run ec secret set in a terminal, or pipe the value on stdin.", .{});
    return r.stdout;
}

pub fn listCommand(c: *C) !core.Outcome {
    const names = try list(c);
    const text = if (names.len == 0) "No secrets saved on this machine." else try std.mem.join(c.a, "\n", names);
    return c.resultData("secret list", text, .{ .names = names });
}
pub fn setCommand(c: *C, name: []const u8) !core.Outcome {
    const input = try read(c, name);
    defer @memset(input, 0);
    try set(c, name, std.mem.trimEnd(u8, input, "\r\n"));
    return c.result("secret set", try c.fmt("Saved {s} on this machine. Run ec sync to update agent settings that use it.", .{name}));
}
pub fn removeCommand(c: *C, name: []const u8) !core.Outcome {
    const existed = try remove(c, name);
    return c.result("secret remove", if (existed) try c.fmt("Removed {s}.", .{name}) else try c.fmt("No secret named {s}.", .{name}));
}

test "secret names stay inside the secrets directory" {
    try std.testing.expect(valid("executor") and valid("cliproxy-api_2"));
    try std.testing.expect(!valid("../x") and !valid(".hidden") and !valid("a/b") and !valid(""));
}
