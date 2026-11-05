// Secrets that plugin settings reference with { secret = "NAME" }. Each is a file under
// ~/.config/ender-chest/secrets, mode 0600, in a 0700 directory. They never enter the config repo.
const std = @import("std");
const core = @import("core.zig");
const C = core.Context;

pub const rel = ".config/ender-chest/secrets";

pub fn valid(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}
fn dir(c: *C) ![]const u8 {
    const d = try c.path(&.{ c.home, rel });
    if (c.isLink(d)) return c.fail("Refusing a symlinked secrets directory at {s}.", .{d});
    return d;
}
pub fn get(c: *C, name: []const u8) !?[]const u8 {
    if (!valid(name)) return c.fail("Invalid secret name {s}. Use letters, digits, - and _.", .{name});
    const d = try dir(c);
    const file = try c.path(&.{ d, name });
    if (c.isLink(file)) return c.fail("Refusing a symlinked secret at {s}.", .{file});
    const text = try c.optional(file) orelse return try legacy(c, d, name);
    const value = std.mem.trimEnd(u8, text, "\r\n");
    if (value.len == 0) return null;
    try c.chmod(d, 0o700);
    try c.chmod(file, 0o600);
    return value;
}
// Earlier releases stored the proxy token as {"apiKey": "..."} in NAME.json.
fn legacy(c: *C, d: []const u8, name: []const u8) !?[]const u8 {
    const file = try c.path(&.{ d, try c.fmt("{s}.json", .{name}) });
    if (c.isLink(file)) return null;
    const text = try c.optional(file) orelse return null;
    const v = c.parse(text) catch return null;
    const key = core.string(v, "apiKey") orelse return null;
    return if (key.len == 0) null else key;
}
pub fn set(c: *C, name: []const u8, value: []const u8) !void {
    if (!valid(name)) return c.fail("Invalid secret name {s}. Use letters, digits, - and _.", .{name});
    if (value.len == 0 or value.len > 16384) return c.fail("A secret must be 1 to 16384 bytes.", .{});
    for (value) |ch| if (ch < 32 and ch != '\t') return c.fail("A secret must be one line.", .{});
    const d = try dir(c);
    try c.mkdir(d);
    try c.chmod(d, 0o700);
    const file = try c.path(&.{ d, name });
    if (c.isLink(file)) return c.fail("Refusing a symlinked secret at {s}.", .{file});
    try c.write(file, try c.fmt("{s}\n", .{value}), 0o600);
}
pub fn remove(c: *C, name: []const u8) !bool {
    if (!valid(name)) return c.fail("Invalid secret name {s}. Use letters, digits, - and _.", .{name});
    const d = try dir(c);
    const file = try c.path(&.{ d, name });
    const existed = c.exists(file);
    try c.remove(file);
    return existed;
}
pub fn list(c: *C) ![]const []const u8 {
    const d = try dir(c);
    var names: std.ArrayList([]const u8) = .empty;
    var handle = core.cwd().openDir(c.io, d, .{ .iterate = true }) catch return names.items;
    defer handle.close(c.io);
    var it = handle.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind == .file and valid(entry.name)) try names.append(c.a, try c.a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return names.items;
}
// Reads a value from stdin when it is not a terminal, else from a hidden prompt.
pub fn read(c: *C, name: []const u8) ![]u8 {
    if (!(std.Io.File.stdin().isTty(c.io) catch false)) {
        var buffer: [16385]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(c.io, &buffer);
        return reader.interface.allocRemaining(c.a, .limited(16385)) catch c.fail("Cannot read the secret from stdin.", .{});
    }
    if (c.json) return c.failCode("interaction_required", "Pipe the secret on stdin, or run ec secret set in a terminal without --json.", .{});
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
    const r = try std.process.run(c.a, c.io, .{ .argv = &.{ "/bin/sh", "-c", script, "sh", name }, .environ_map = c.env, .stdout_limit = .limited(16385), .stderr_limit = .limited(4096) });
    if (!core.success(r.term)) return c.failCode("interaction_required", "Could not read a secret. Run ec secret set in a terminal, or pipe the value on stdin.", .{});
    return r.stdout;
}

pub fn run(c: *C, action: []const u8, name: ?[]const u8) !void {
    if (std.mem.eql(u8, action, "list")) {
        const names = try list(c);
        const text = if (names.len == 0) "No secrets saved on this machine." else try std.mem.join(c.a, "\n", names);
        return c.resultData("secret list", true, text, .{ .names = names });
    }
    const n = name orelse return c.fail("ec secret {s} needs a NAME.", .{action});
    if (std.mem.eql(u8, action, "set")) {
        const input = try read(c, n);
        defer @memset(input, 0);
        try set(c, n, std.mem.trimEnd(u8, input, "\r\n"));
        return c.result("secret set", true, try c.fmt("Saved {s} on this machine. Run ec sync to update agent settings that use it.", .{n}));
    }
    if (std.mem.eql(u8, action, "remove")) {
        const existed = try remove(c, n);
        return c.result("secret remove", true, if (existed) try c.fmt("Removed {s}.", .{n}) else try c.fmt("No secret named {s}.", .{n}));
    }
    return c.fail("Unknown secret command {s}. Use set, list, or remove.", .{action});
}

test "secret names stay inside the secrets directory" {
    try std.testing.expect(valid("executor") and valid("cliproxy-api_2"));
    try std.testing.expect(!valid("../x") and !valid(".hidden") and !valid("a/b") and !valid(""));
}
