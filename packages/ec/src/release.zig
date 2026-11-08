// ec's GitHub releases: the asset that fits this machine, the manifest.json each release
// publishes (tools/package-release.py writes it), the latest release, and installing a verified
// binary from one.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const paths = @import("paths.zig");
const gh = @import("github.zig");
const build_info = @import("build_info.zig");
const host = @import("host.zig");
const C = core.Context;
const eq = core.eql;

const default_repo = "KayleeWilliams/ender-chest";

// This binary's key in a release manifest. src/targets.json lists every published target.
const target: ?[]const u8 = switch (builtin.os.tag) {
    .macos, .linux => switch (builtin.cpu.arch) {
        .aarch64 => "aarch64-" ++ @tagName(builtin.os.tag),
        .x86_64 => "x86_64-" ++ @tagName(builtin.os.tag),
        else => null,
    },
    else => null,
};

// Releases are X.Y.Z without leading zeros. Local builds report "dev".
pub fn validVersion(v: []const u8) bool {
    var parts = std.mem.splitScalar(u8, v, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0 or part.len > 9 or (part.len > 1 and part[0] == '0')) return false;
        for (part) |ch| if (!std.ascii.isDigit(ch)) return false;
    }
    return count == 3;
}
pub fn newer(candidate: []const u8, current: []const u8) bool {
    if (!validVersion(candidate) or !validVersion(current)) return false;
    var a = std.mem.splitScalar(u8, candidate, '.');
    var b = std.mem.splitScalar(u8, current, '.');
    for (0..3) |_| {
        const x = std.fmt.parseInt(u32, a.next().?, 10) catch return false;
        const y = std.fmt.parseInt(u32, b.next().?, 10) catch return false;
        if (x != y) return x > y;
    }
    return false;
}

// EC_NO_UPDATE turns off the checks ec makes on its own: sync's self-update, the daily notice,
// and ec status. ec update still runs when asked.
pub fn disabled(c: *C) bool {
    return core.truthy(c.env.get("EC_NO_UPDATE"));
}
pub fn repoSlug(c: *C) []const u8 {
    if (c.env.get("EC_RELEASE_REPO")) |slug| if (gh.validSlug(slug)) return slug;
    return default_repo;
}
pub fn notesUrl(c: *C, v: []const u8) ![]const u8 {
    return c.fmt("https://github.com/{s}/releases/tag/v{s}", .{ repoSlug(c), v });
}
pub fn installerCommand(c: *C) ![]const u8 {
    return c.fmt("curl -fsSL https://github.com/{s}/releases/latest/download/install.sh | sh", .{repoSlug(c)});
}
// The npm tarball each release carries.
pub fn tarball(c: *C, v: []const u8) ![]const u8 {
    return c.fmt("ender-chest-{s}.tgz", .{v});
}

const Asset = struct { name: []const u8, sha256: []const u8, location: []const u8 };
pub const Release = struct {
    version: []const u8,
    source_hash: []const u8,
    // Keyed by target. Locations are GitHub API URLs, or files for EC_RELEASE_MANIFEST.
    assets: std.StringArrayHashMapUnmanaged(Asset) = .empty,
    local: bool = false,
};

// The latest release with its manifest, read now. Also records its version for the notice.
pub fn latest(c: *C) ?Release {
    // Tests name a manifest file whose assets are files.
    const override = c.env.get("EC_RELEASE_MANIFEST") orelse "";
    const found = (if (override.len > 0) fromFile(c, override) else fromGitHub(c)) catch null;
    const r = found orelse return null;
    var cache = Cache.load(c);
    cache.checked_at = core.unixSeconds(c.io);
    cache.latest = r.version;
    cache.save(c);
    return r;
}
pub fn latestVersion(c: *C) ?[]const u8 {
    const body = get(c, latestUrl(c) catch return null, "application/vnd.github+json", brief) orelse return null;
    const tag = core.string(c.parse(body) catch return null, "tag_name") orelse return null;
    const v = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    return if (validVersion(v)) v else null;
}

fn parseManifest(c: *C, body: []const u8) !?Release {
    const json = c.parse(body) catch return null;
    var r: Release = .{ .version = core.string(json, "version") orelse return null, .source_hash = core.string(json, "source_hash") orelse return null };
    const assets = json.object.get("assets") orelse return r;
    if (assets != .object) return null;
    var it = assets.object.iterator();
    while (it.next()) |entry| {
        const item = entry.value_ptr.*;
        const name = core.string(item, "name") orelse continue;
        const sum = core.string(item, "sha256") orelse continue;
        if (sum.len != 64) continue;
        try r.assets.put(c.a, entry.key_ptr.*, .{ .name = name, .sha256 = sum, .location = core.string(item, "path") orelse "" });
    }
    return r;
}
fn fromFile(c: *C, file: []const u8) !?Release {
    var r = try parseManifest(c, c.read(file) catch return null) orelse return null;
    r.local = true;
    for (r.assets.values()) |*a| if (!std.fs.path.isAbsolute(a.location)) {
        a.location = try c.path(&.{ std.fs.path.dirname(file) orelse ".", a.location });
    };
    return r;
}
fn latestUrl(c: *C) ![]const u8 {
    return c.fmt("https://api.github.com/repos/{s}/releases/latest", .{repoSlug(c)});
}
fn fromGitHub(c: *C) !?Release {
    const listing = c.parse(get(c, try latestUrl(c), "application/vnd.github+json", patient) orelse return null) catch return null;
    const manifest_url = assetUrl(listing, "manifest.json") orelse return null;
    var r = try parseManifest(c, get(c, manifest_url, "application/octet-stream", patient) orelse return null) orelse return null;
    for (r.assets.values()) |*a| a.location = assetUrl(listing, a.name) orelse "";
    return r;
}
fn assetUrl(listing: std.json.Value, name: []const u8) ?[]const u8 {
    for (core.array(listing, "assets")) |item| if (eq(u8, core.string(item, "name") orelse "", name)) return core.string(item, "url");
    return null;
}

// Downloads this machine's binary from `r`, checks its sha256, runs it once, and renames it
// over `dest`. Any failure leaves `dest` as it was.
pub fn install(c: *C, r: Release, dest: []const u8) !void {
    const key = target orelse return c.fail("No published ec binary for this machine; {s} is unchanged.", .{dest});
    const asset = r.assets.get(key) orelse return c.fail("Release {s} has no {s} binary; {s} is unchanged.", .{ r.version, key, dest });
    const bytes = (if (r.local) c.read(asset.location) catch null else if (asset.location.len > 0) get(c, asset.location, "application/octet-stream", patient) else null) orelse
        return c.fail("Could not download ec {s}; {s} is unchanged.", .{ r.version, dest });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!eq(u8, &std.fmt.bytesToHex(digest, .lower), asset.sha256)) return c.fail("Refusing ec {s}: checksum did not match. {s} is unchanged.", .{ r.version, dest });
    const staged = try c.tempNear(dest);
    c.write(staged, bytes, 0o755) catch return c.fail("Cannot write to {s}. Rerun the installer with EC_INSTALL_DIR set to a directory you own.", .{std.fs.path.dirname(dest) orelse "."});
    defer c.remove(staged) catch {};
    const probe = c.capture(&.{ staged, "--version" }, null, 15) catch null;
    const ran = if (probe) |p| core.success(p.term) and std.mem.startsWith(u8, p.stdout, try build_info.prefix(c.a, r.version)) else false;
    if (!ran) return c.fail("The downloaded ec {s} did not run on this machine; {s} is unchanged.", .{ r.version, dest });
    core.cwd().rename(staged, core.cwd(), dest, c.io) catch return c.fail("Cannot replace {s}.", .{dest});
}

pub const Cache = struct {
    checked_at: i64 = 0,
    latest: []const u8 = "",
    notified_at: i64 = 0,
    fn file(c: *C) ![]const u8 {
        return paths.inHome(c, paths.update_check);
    }
    // A missing or damaged file reads as never checked.
    pub fn load(c: *C) Cache {
        const text = (c.optional(file(c) catch return .{}) catch return .{}) orelse return .{};
        return std.json.parseFromSliceLeaky(Cache, c.a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
    }
    // The cache only saves a request, so failing to write it is not an error.
    pub fn save(cache: Cache, c: *C) void {
        const text = std.json.Stringify.valueAlloc(c.a, cache, .{}) catch return;
        c.write(file(c) catch return, text, 0o600) catch {};
    }
};
// A clock that moved backwards makes a saved time due again.
pub fn due(since: i64, now: i64) bool {
    return now < since or now - since >= 24 * 60 * 60;
}

const Limit = struct { seconds: u8, retries: u8 };
// The daily notice runs after an interactive command, so it gives up quickly.
const brief: Limit = .{ .seconds = 3, .retries = 0 };
const patient: Limit = .{ .seconds = 30, .retries = 3 };
// --fail keeps the body of a failed attempt out of the output when curl retries.
fn get(c: *C, url: []const u8, accept: []const u8, limit: Limit) ?[]const u8 {
    const authorization = if (githubToken(c)) |token| host.bearer(c, token) catch return null else "";
    const config = c.fmt("{s}header = \"Accept: {s}\"\nheader = \"User-Agent: ec\"\n", .{ authorization, accept }) catch return null;
    const seconds = c.fmt("{d}", .{limit.seconds}) catch return null;
    const retries = c.fmt("{d}", .{limit.retries}) catch return null;
    const r = host.curl(c, &.{ "curl", "-fsSL", "--retry", retries, "--max-time", seconds, "--config", "-", "--", url }, config, @as(i64, limit.seconds) * (@as(i64, limit.retries) + 1) + 5) catch return null;
    return if (core.success(r.term)) r.stdout else null;
}
fn githubToken(c: *C) ?[]const u8 {
    for ([_][]const u8{ "GH_TOKEN", "GITHUB_TOKEN" }) |name| if (c.env.get(name)) |token| if (validToken(token)) return token;
    if (!c.commandExists("gh")) return null;
    const r = c.capture(&.{ "gh", "auth", "token" }, null, 15) catch return null;
    if (!core.success(r.term)) return null;
    const token = core.trim(r.stdout);
    return if (validToken(token)) token else null;
}
fn validToken(token: []const u8) bool {
    return token.len <= 256 and host.safeToken(token);
}

test "versions compare by number and reject anything but X.Y.Z" {
    try std.testing.expect(validVersion("0.0.1") and validVersion("10.20.30"));
    for ([_][]const u8{ "dev", "", "1.2", "1.2.3.4", "01.2.3", "1.2.3-beta", "v1.2.3", "1..3" }) |bad| try std.testing.expect(!validVersion(bad));
    try std.testing.expect(newer("0.0.10", "0.0.9") and newer("0.1.0", "0.0.99") and newer("1.0.0", "0.9.9"));
    try std.testing.expect(!newer("0.0.9", "0.0.10") and !newer("0.0.5", "0.0.5"));
    // A development build is never older or newer than a release.
    try std.testing.expect(!newer("0.0.9", "dev") and !newer("dev", "0.0.1"));
}
test "checks and notices are due once a day, and again after the clock moves back" {
    try std.testing.expect(due(0, 24 * 60 * 60) and !due(100, 100 + 24 * 60 * 60 - 1));
    try std.testing.expect(due(100, 50));
}
test "this binary's target is one that releases publish" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const listed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), @embedFile("targets.json"), .{});
    for (listed.array.items) |t| if (eq(u8, core.string(t, "key").?, target.?)) return;
    return error.TestUnexpectedResult;
}
