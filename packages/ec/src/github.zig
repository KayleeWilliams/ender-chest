// A GitHub repository written as owner/repo or owner/repo#ref, as skill and plugin sources use.
const std = @import("std");
const core = @import("core.zig");

pub const Source = struct {
    slug: []const u8,
    ref: ?[]const u8,
    // Rejects text that could escape the URL or reach git as an option.
    pub fn parse(text: []const u8) error{InvalidSource}!Source {
        var split = std.mem.splitScalar(u8, text, '#');
        const slug = split.next().?;
        const ref = split.next();
        if (split.next() != null or !validSlug(slug)) return error.InvalidSource;
        if (ref) |r| {
            if (r.len == 0 or r[0] == '-' or std.mem.indexOfAny(u8, r, " \t\n\r") != null) return error.InvalidSource;
        }
        return .{ .slug = slug, .ref = ref };
    }
};
pub fn validSlug(slug: []const u8) bool {
    var parts = std.mem.splitScalar(u8, slug, '/');
    const owner = parts.next().?;
    const repo = parts.next() orelse return false;
    return parts.next() == null and core.safeName(owner) and core.safeName(repo);
}
// Plugin refs reach git ls-remote and are pinned in the lock file, so they also keep to ref
// characters and never contain "..".
pub fn strictRef(ref: []const u8) bool {
    if (ref.len == 0 or ref[0] == '-') return false;
    for (ref) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '_' and ch != '/') return false;
    return std.mem.indexOf(u8, ref, "..") == null;
}
pub fn cloneUrl(a: std.mem.Allocator, slug: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "https://github.com/{s}.git", .{slug});
}

test "sources reject option injection and traversal" {
    try std.testing.expectError(error.InvalidSource, Source.parse("../repo"));
    try std.testing.expectError(error.InvalidSource, Source.parse("owner/repo#--upload-pack=bad"));
    try std.testing.expectError(error.InvalidSource, Source.parse("owner/repo/extra"));
    const s = try Source.parse("owner/repo#main");
    try std.testing.expectEqualStrings("owner/repo", s.slug);
    try std.testing.expectEqualStrings("main", s.ref.?);
    try std.testing.expect((try Source.parse("owner/repo")).ref == null);
    try std.testing.expect(validSlug("someone/ec-backup"));
    try std.testing.expect(!validSlug("someone/ec/backup") and !validSlug("../x") and !validSlug("x"));
    try std.testing.expect(strictRef("v1.2.0") and strictRef("main") and !strictRef("--upload-pack=x") and !strictRef("a..b"));
}
