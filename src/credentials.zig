const std = @import("std");
const core = @import("core.zig");
const C = core.Context;

pub const endpoint_path = ".config/cliproxyapi/client.json";
pub const secret_path = ".config/ender-chest/secrets/cliproxyapi.json";

pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 4096) return false;
    for (key) |ch| if (ch <= 32 or ch >= 127 or ch == '"' or ch == '\\') return false;
    return true;
}

pub fn validBase(base: []const u8) bool {
    const start: usize = if (std.mem.startsWith(u8, base, "https://")) 8 else if (std.mem.startsWith(u8, base, "http://")) 7 else return false;
    if (base.len <= start or base[start] == '/' or base[start] == '-') return false;
    if (std.mem.indexOfAny(u8, base, "@?#\\\" \t\r\n") != null) return false;
    for (base) |ch| if (ch < 32 or ch == 127) return false;
    return !std.mem.endsWith(u8, base, "/v1");
}

pub fn endpoint(c: *C, file: []const u8) ![]const u8 {
    const config = c.readJson(file) catch return c.fail("Cannot read proxy endpoint settings. Run ec cliproxy setup --url URL.", .{});
    const base = std.mem.trimEnd(u8, core.string(config, "baseURL") orelse "", "/");
    if (!validBase(base)) return c.fail("Invalid proxy endpoint. Use an HTTP or HTTPS URL without credentials, query parameters, or /v1.", .{});
    return base;
}

pub fn save(c: *C, key: []const u8) !void {
    if (!validKey(key)) return c.fail("Invalid proxy token. Use a nonempty token without spaces, quotes, or control characters.", .{});
    const dir = try c.path(&.{ c.home, ".config/ender-chest/secrets" });
    if (c.isLink(dir)) return c.fail("Refusing a symlinked credentials directory.", .{});
    try c.mkdir(dir);
    try c.chmod(dir, 0o700);
    var value = c.object();
    try value.object.put(c.a, "apiKey", .{ .string = key });
    const file = try c.path(&.{ c.home, secret_path });
    if (c.isLink(file)) return c.fail("Refusing a symlinked credentials file.", .{});
    try c.writeJson(file, value, 0o600);
}

pub fn loadKey(c: *C) !?[]const u8 {
    const file = try c.path(&.{ c.home, secret_path });
    if (c.isLink(file) or c.isLink(std.fs.path.dirname(file).?)) return c.fail("Refusing symlinked proxy credentials.", .{});
    const contents = try c.optional(file) orelse return null;
    const value = c.parse(contents) catch return c.fail("Cannot read local proxy credentials. Run ec cliproxy setup to replace them.", .{});
    const token = core.string(value, "apiKey") orelse "";
    if (!validKey(token)) return c.fail("Invalid local proxy credentials. Run ec cliproxy setup to replace them.", .{});
    try c.chmod(std.fs.path.dirname(file).?, 0o700);
    try c.chmod(file, 0o600);
    return token;
}

// Only migrate an already-installed credential. Never import one from a checkout.
pub fn migrate(c: *C) !void {
    const file = try c.path(&.{ c.home, endpoint_path });
    const contents = try c.optional(file) orelse return;
    const value = c.parse(contents) catch return c.fail("Cannot read local proxy settings; leaving them untouched.", .{});
    if (value != .object) return c.fail("Invalid local proxy settings; leaving them untouched.", .{});
    if (value.object.get("apiKey") == null) return;
    if (try loadKey(c) == null) {
        const legacy = core.string(value, "apiKey") orelse "";
        try save(c, legacy);
    }
    try exportEndpoint(c, file, file);
}

// Export a whitelist of portable settings, never the old credential field.
pub fn exportEndpoint(c: *C, source: []const u8, dest: []const u8) !void {
    const base = try endpoint(c, source);
    var value = c.object();
    try value.object.put(c.a, "baseURL", .{ .string = base });
    try c.writeJson(dest, value, 0o600);
}

pub fn checkRepo(c: *C) !void {
    const file = try c.path(&.{ c.repo, "home", endpoint_path });
    if (!c.exists(file)) return;
    const value = c.readJson(file) catch return c.fail("Invalid proxy endpoint config in the checkout.", .{});
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (!core.eql(u8, entry.key_ptr.*, "baseURL")) return c.fail("Proxy config in Git may contain only baseURL. Keep tokens in local credentials and run ec cliproxy setup.", .{});
    }
    _ = try endpoint(c, file);
}

test "reject credentials embedded in endpoint URLs and invalid tokens" {
    try std.testing.expect(validBase("https://proxy.example.test:8317"));
    try std.testing.expect(!validBase("https://user:secret@proxy.test"));
    try std.testing.expect(!validBase("https://proxy.test?token=secret"));
    try std.testing.expect(!validBase("http://proxy.test/v1"));
    try std.testing.expect(!validKey("secret\nheader"));
    try std.testing.expect(validKey("test-client-key"));
}
