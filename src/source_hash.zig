const std = @import("std");

// Shared by the build and installed CLI. Sort paths and hash their names and bytes.
pub fn fingerprint(a: std.mem.Allocator, io: std.Io, root: []const u8) ![64]u8 {
    var files: std.ArrayList([]const u8) = .empty;
    try files.appendSlice(a, &.{ "build.zig", "build.zig.zon", ".zig-version" });
    var dir = try std.Io.Dir.cwd().openDir(io, try std.fs.path.join(a, &.{ root, "src" }), .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) try files.append(a, try std.fs.path.join(a, &.{ "src", entry.name }));
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (files.items) |rel| {
        const body = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ root, rel }), a, .limited(4 * 1024 * 1024));
        hash.update(rel);
        hash.update("\x00");
        hash.update(body);
        hash.update("\x00");
    }
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}
