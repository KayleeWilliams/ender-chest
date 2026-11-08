// What build.zig recorded about this binary: its release version ("dev" for local builds) and
// the hash of the sources it was built from.
const std = @import("std");
const options = @import("build_options");

pub const version: []const u8 = options.version;
pub const source_hash: []const u8 = options.source_hash;

// How ec names a build, as `ec --version` prints it: "ec VERSION (HASH7)".
pub const line = std.fmt.comptimePrint("ec {s} ({s})", .{ version, short(source_hash) });
pub fn describe(a: std.mem.Allocator, v: []const u8, hash: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "ec {s} ({s})", .{ v, short(hash) });
}
// How the line of a build with version `v` starts.
pub fn prefix(a: std.mem.Allocator, v: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "ec {s} (", .{v});
}
// The version in a line from an ec too old to report --version --json data.
pub fn parseVersion(text: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, text, "ec ")) text[3..] else null;
}
pub fn short(hash: []const u8) []const u8 {
    return hash[0..@min(7, hash.len)];
}
