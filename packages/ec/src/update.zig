const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const C = core.Context;
const O = @import("options.zig").Options;
const eq = core.eql;

const day_seconds: i64 = 24 * 60 * 60;
const default_repo = "KayleeWilliams/ender-chest";

pub const Plan = enum { current, download, local };

pub fn assetKey() ?[]const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => switch (builtin.os.tag) {
            .macos => "aarch64-macos",
            .linux => "aarch64-linux",
            else => null,
        },
        .x86_64 => switch (builtin.os.tag) {
            .macos => "x86_64-macos",
            .linux => "x86_64-linux",
            else => null,
        },
        else => null,
    };
}

pub fn plan(binary_hash: []const u8, checkout_hash: []const u8, release_hash: ?[]const u8, attempted: ?[]const u8) Plan {
    if (eq(u8, binary_hash, checkout_hash)) return .current;
    if (attempted) |previous| if (eq(u8, previous, checkout_hash)) return .local;
    if (release_hash) |hash| if (eq(u8, hash, checkout_hash)) return .download;
    return .local;
}

pub fn cacheFresh(checked_at: i64, now: i64, checkout: []const u8, cached_checkout: []const u8) bool {
    if (!eq(u8, checkout, cached_checkout) or now < checked_at) return false;
    return now - checked_at < day_seconds;
}

pub fn parseSlug(url: []const u8) ?[]const u8 {
    var s = core.trim(url);
    if (std.mem.endsWith(u8, s, ".git")) s = s[0 .. s.len - 4];
    const slug = if (std.mem.lastIndexOf(u8, s, "github.com:")) |i|
        s[i + "github.com:".len ..]
    else if (std.mem.lastIndexOf(u8, s, "github.com/")) |i|
        s[i + "github.com/".len ..]
    else
        return null;
    if (!validSlug(slug)) return null;
    return slug;
}

pub fn sha256Hex(data: []const u8) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(data);
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

pub fn tryRelease(c: *C, o: O, checkout_hash: []const u8) !void {
    if (updatesDisabled(c)) return;
    const binary_hash = @import("build_options").source_hash;
    const attempted = c.env.get("EC_RELEASE_ATTEMPTED");
    if (eq(u8, binary_hash, checkout_hash)) return;
    if (attempted) |previous| if (eq(u8, previous, checkout_hash)) return;
    const release = loadRelease(c, checkout_hash) orelse return;
    if (plan(binary_hash, checkout_hash, release.hash, attempted) != .download) return;
    const key = assetKey() orelse {
        try c.log("No published ec binary for this target.", .{});
        return;
    };
    const asset = release.asset(key) orelse {
        try c.log("Release {s} has no {s} binary.", .{ release.version, key });
        return;
    };
    const bytes = readAsset(c, release, asset) orelse {
        try c.log("Could not download ec {s}. Rebuilding from the checkout if needed.", .{release.version});
        return;
    };
    const sum = sha256Hex(bytes);
    if (!eq(u8, &sum, asset.sha256)) {
        try c.log("Refusing ec {s}: checksum did not match.", .{release.version});
        return;
    }
    const dest = try c.path(&.{ c.home, ".local/bin/ec" });
    try c.write(dest, bytes, 0o755);
    try c.log("Updating ec to {s}.", .{release.version});
    try reexec(c, o, dest, checkout_hash);
}

const Asset = struct { name: []const u8, sha256: []const u8, path: []const u8, url: []const u8 };
const Release = struct {
    hash: []const u8,
    version: []const u8,
    manifest: std.json.Value,
    urls: std.json.Value,
    manifest_path: []const u8 = "",
    fn asset(r: Release, key: []const u8) ?Asset {
        if (r.manifest != .object) return null;
        const assets = r.manifest.object.get("assets") orelse return null;
        if (assets != .object) return null;
        const item = assets.object.get(key) orelse return null;
        const name = core.string(item, "name") orelse return null;
        const sum = core.string(item, "sha256") orelse return null;
        if (sum.len != 64) return null;
        const path = core.string(item, "path") orelse "";
        const listed = core.string(item, "url") orelse "";
        const url = if (r.urls == .object) core.string(r.urls, name) orelse listed else listed;
        return .{ .name = name, .sha256 = sum, .path = path, .url = url };
    }
};

pub const Latest = struct { version: []const u8, hash: []const u8 };
pub fn latest(c: *C) ?Latest {
    if (c.env.get("EC_RELEASE_MANIFEST")) |path| if (path.len > 0) {
        const r = readManifestFile(c, path) orelse return null;
        return .{ .version = r.version, .hash = r.hash };
    };
    if (updatesDisabled(c)) return null;
    const fetched = fetchRelease(c) orelse return null;
    return switch (fetched) {
        .release => |r| .{ .version = r.version, .hash = r.hash },
        else => null,
    };
}

fn loadRelease(c: *C, checkout_hash: []const u8) ?Release {
    if (c.env.get("EC_RELEASE_MANIFEST")) |path| if (path.len > 0) return readManifestFile(c, path);
    if (cachedMiss(c, checkout_hash)) return null;
    const fetched = fetchRelease(c) orelse return null;
    if (fetched == .failed) return null;
    if (fetched == .none) return null;
    saveCache(c, checkout_hash, fetched.release.hash);
    return if (eq(u8, fetched.release.hash, checkout_hash)) fetched.release else null;
}

fn readManifestFile(c: *C, path: []const u8) ?Release {
    const body = c.read(path) catch return null;
    const manifest = c.parse(body) catch return null;
    const hash = core.string(manifest, "source_hash") orelse return null;
    return .{
        .hash = hash,
        .version = core.string(manifest, "version") orelse "release",
        .manifest = manifest,
        .urls = .{ .object = .empty },
        .manifest_path = path,
    };
}

const Fetch = union(enum) { release: Release, none, failed };

fn fetchRelease(c: *C) ?Fetch {
    const token = githubToken(c) orelse "";
    const slug = repoSlug(c);
    const release_url = c.fmt("https://api.github.com/repos/{s}/releases/latest", .{slug}) catch return null;
    const release_body = https(c, token, release_url, "application/vnd.github+json") orelse return .failed;
    if (release_body.len == 0) return .none;
    const release_json = c.parse(release_body) catch return .failed;
    const manifest_url = assetApiUrl(release_json, "manifest.json") orelse {
        c.log("The latest ec release has no manifest.", .{}) catch {};
        return .failed;
    };
    const manifest_body = https(c, token, manifest_url, "application/octet-stream") orelse return .failed;
    const manifest = c.parse(manifest_body) catch return .failed;
    const hash = core.string(manifest, "source_hash") orelse return .failed;
    var urls = c.object();
    if (manifest == .object) if (manifest.object.get("assets")) |assets| if (assets == .object) {
        var it = assets.object.iterator();
        while (it.next()) |entry| {
            const name = core.string(entry.value_ptr.*, "name") orelse continue;
            const url = assetApiUrl(release_json, name) orelse continue;
            urls.object.put(c.a, name, .{ .string = url }) catch return .failed;
        }
    };
    return .{ .release = .{ .hash = hash, .version = core.string(manifest, "version") orelse "release", .manifest = manifest, .urls = urls } };
}

fn readAsset(c: *C, release: Release, asset: Asset) ?[]const u8 {
    if (asset.path.len > 0) {
        const path = if (std.fs.path.isAbsolute(asset.path)) asset.path else c.path(&.{ std.fs.path.dirname(release.manifest_path) orelse ".", asset.path }) catch return null;
        return c.read(path) catch null;
    }
    if (asset.url.len == 0) return null;
    const token = githubToken(c) orelse "";
    return https(c, token, asset.url, "application/octet-stream");
}

fn https(c: *C, token: []const u8, url: []const u8, accept: []const u8) ?[]const u8 {
    if ((token.len > 0 and !validToken(token)) or !c.commandExists("curl")) return null;
    var random: [8]u8 = undefined;
    std.Io.random(c.io, &random);
    const dir = c.fmt("{s}/.cache/ec", .{c.home}) catch return null;
    c.mkdir(dir) catch return null;
    const cfg = c.fmt("{s}/curl-{x}.conf", .{ dir, random }) catch return null;
    const out = c.fmt("{s}/download-{x}", .{ dir, random }) catch return null;
    defer core.cwd().deleteFile(c.io, cfg) catch {};
    defer core.cwd().deleteFile(c.io, out) catch {};
    const authorization = if (token.len > 0) c.fmt("header = \"Authorization: Bearer {s}\"\n", .{token}) catch return null else "";
    const config = c.fmt("{s}header = \"Accept: {s}\"\nheader = \"User-Agent: ec\"\n", .{ authorization, accept }) catch return null;
    c.write(cfg, config, 0o600) catch return null;
    const result = c.capture(&.{ "curl", "-fsSL", "--retry", "3", "--max-time", "30", "--config", cfg, "-o", out, "--", url }, null, 45) catch return null;
    if (!core.success(result.term)) {
        const missing = std.mem.indexOf(u8, result.stderr, "404") != null;
        if (missing) c.log("No ec release found. Private releases require GitHub access.", .{}) catch {} else c.log("Could not reach GitHub releases.", .{}) catch {};
        return if (missing) "" else null;
    }
    return c.read(out) catch null;
}

fn reexec(c: *C, o: O, exe: []const u8, hash: []const u8) !void {
    try c.env.put("EC_RELEASE_ATTEMPTED", hash);
    try c.env.put("EC_SYNC_PULLED", c.repo);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(c.a, &.{ exe, "sync", "--repo", c.repo });
    if (o.profile.len > 0) try args.appendSlice(c.a, &.{ "--profile", o.profile });
    if (o.skip_packages) try args.append(c.a, "--skip-packages");
    if (o.update_skills) try args.append(c.a, "--update-skills");
    if (o.json) try args.append(c.a, "--json");
    return std.process.replace(c.io, .{ .argv = args.items, .environ_map = c.env });
}

fn updatesDisabled(c: *C) bool {
    const value = c.env.get("EC_NO_UPDATE") orelse return false;
    return value.len != 0 and !eq(u8, value, "0");
}

fn repoSlug(c: *C) []const u8 {
    if (c.env.get("EC_RELEASE_REPO")) |slug| if (validSlug(slug)) return slug;
    return default_repo;
}

fn githubToken(c: *C) ?[]const u8 {
    if (c.env.get("GH_TOKEN")) |token| if (validToken(token)) return token;
    if (c.env.get("GITHUB_TOKEN")) |token| if (validToken(token)) return token;
    if (!c.commandExists("gh")) return null;
    const result = c.capture(&.{ "gh", "auth", "token" }, null, 15) catch return null;
    if (!core.success(result.term)) return null;
    const token = core.trim(result.stdout);
    return if (validToken(token)) token else null;
}

fn assetApiUrl(release: std.json.Value, name: []const u8) ?[]const u8 {
    for (core.array(release, "assets")) |item| {
        const asset_name = core.string(item, "name") orelse continue;
        if (!eq(u8, asset_name, name)) continue;
        return core.string(item, "url");
    }
    return null;
}

fn cachePath(c: *C) ![]const u8 {
    return c.path(&.{ c.home, ".config/ender-chest/release-check" });
}

fn cachedMiss(c: *C, checkout_hash: []const u8) bool {
    const body = (c.optional(cachePath(c) catch return false) catch return false) orelse return false;
    var lines = std.mem.splitScalar(u8, core.trim(body), '\n');
    if (!eq(u8, lines.next() orelse return false, "v1")) return false;
    const checked_at = std.fmt.parseInt(i64, lines.next() orelse return false, 10) catch return false;
    const cached_checkout = lines.next() orelse return false;
    const cached_hash = lines.next() orelse return false;
    if (!cacheFresh(checked_at, nowSeconds(c.io), checkout_hash, cached_checkout)) return false;
    return !eq(u8, cached_hash, checkout_hash);
}

fn saveCache(c: *C, checkout_hash: []const u8, release_hash: []const u8) void {
    const text = c.fmt("v1\n{d}\n{s}\n{s}\n", .{ nowSeconds(c.io), checkout_hash, release_hash }) catch return;
    c.write(cachePath(c) catch return, text, 0o600) catch {};
}

fn nowSeconds(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
}

fn validSlug(slug: []const u8) bool {
    var parts = std.mem.splitScalar(u8, slug, '/');
    const owner = parts.next() orelse return false;
    const repo = parts.next() orelse return false;
    if (parts.next() != null) return false;
    return core.safeName(owner) and core.safeName(repo);
}

fn validToken(token: []const u8) bool {
    if (token.len == 0 or token.len > 256) return false;
    for (token) |ch| if (ch <= ' ' or ch == '"' or ch == '\\') return false;
    return true;
}

test "release plan installs only the build for this checkout" {
    const binary = "aaa";
    const checkout = "bbb";
    try std.testing.expectEqual(Plan.current, plan(binary, binary, checkout, null));
    try std.testing.expectEqual(Plan.download, plan(binary, checkout, checkout, null));
    try std.testing.expectEqual(Plan.local, plan(binary, checkout, "ccc", null));
    try std.testing.expectEqual(Plan.local, plan(binary, checkout, null, null));
    try std.testing.expectEqual(Plan.local, plan(binary, checkout, checkout, checkout));
}

test "release cache expires after a day and follows the checkout hash" {
    try std.testing.expect(cacheFresh(100, 100 + day_seconds - 1, "abc", "abc"));
    try std.testing.expect(!cacheFresh(100, 100 + day_seconds, "abc", "abc"));
    try std.testing.expect(!cacheFresh(100, 50, "abc", "abc"));
    try std.testing.expect(!cacheFresh(100, 100, "abc", "def"));
}

test "release slug and checksum" {
    try std.testing.expectEqualStrings("owner/config", parseSlug("https://github.com/owner/config.git").?);
    try std.testing.expectEqualStrings("owner/config", parseSlug("git@github.com:owner/config.git").?);
    try std.testing.expect(parseSlug("https://example.com/owner/config") == null);
    try std.testing.expect(parseSlug("https://github.com/owner/config/extra") == null);
    const sum = sha256Hex("abc");
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &sum);
}
