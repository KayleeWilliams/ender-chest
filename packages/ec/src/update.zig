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
    const bytes = try download(c, release) orelse return;
    const dest = try c.path(&.{ c.home, ".local/bin/ec" });
    try c.write(dest, bytes, 0o755);
    try c.log("Updating ec to {s}.", .{release.version});
    try reexec(c, o, dest, checkout_hash);
}

// The binary for this machine from a release, or null after logging why not.
fn download(c: *C, release: Release) !?[]const u8 {
    const key = assetKey() orelse {
        try c.log("No published ec binary for this target.", .{});
        return null;
    };
    const asset = release.asset(key) orelse {
        try c.log("Release {s} has no {s} binary.", .{ release.version, key });
        return null;
    };
    const bytes = readAsset(c, release, asset) orelse {
        try c.log("Could not download ec {s}.", .{release.version});
        return null;
    };
    const sum = sha256Hex(bytes);
    if (!eq(u8, &sum, asset.sha256)) {
        try c.log("Refusing ec {s}: checksum did not match.", .{release.version});
        return null;
    }
    return bytes;
}

// For a config checkout without ec's sources: install the latest release when it is newer than
// this binary. Development builds keep themselves, so sync never replaces one with an older release.
pub fn syncLatest(c: *C, o: O) !void {
    if (updatesDisabled(c) or !validVersion(version)) return;
    const release = freshRelease(c) orelse return;
    if (c.env.get("EC_RELEASE_ATTEMPTED")) |previous| if (eq(u8, previous, release.hash)) return;
    if (!newer(release.version, version)) return;
    const bytes = try download(c, release) orelse return;
    const dest = try c.path(&.{ c.home, ".local/bin/ec" });
    try c.write(dest, bytes, 0o755);
    try c.log("Updating ec {s} to {s}.", .{ version, release.version });
    try reexec(c, o, dest, release.hash);
}

pub const version = @import("build_options").version;

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

// How this copy of ec was installed, which decides how ec update replaces it.
pub const Method = enum { development, standalone, package, project };
pub fn method(v: []const u8, exe: []const u8, project_manifest: bool) Method {
    if (!validVersion(v)) return .development;
    if (std.mem.indexOf(u8, exe, "/node_modules/") == null) return .standalone;
    for ([_][]const u8{ "/install/global/node_modules/", "/yarn/global/node_modules/", "/yarn/data/global/node_modules/" }) |global| {
        if (std.mem.indexOf(u8, exe, global) != null) return .package;
    }
    // pnpm keeps global packages under global/<n>/ or global/v<n>/<id>/, with their own package.json.
    if (std.mem.indexOf(u8, exe, "/global/") != null and std.mem.indexOf(u8, exe, "/.pnpm/") != null) return .package;
    // npm installs global packages under <prefix>/lib/node_modules, beside no package.json.
    return if (project_manifest) .project else .package;
}
fn projectDir(exe: []const u8) []const u8 {
    const pos = std.mem.indexOf(u8, exe, "/node_modules/") orelse return exe;
    return exe[0..pos];
}
fn currentMethod(c: *C) !struct { method: Method, exe: []const u8 } {
    const exe = try std.process.executablePathAlloc(c.io, c.a);
    const manifest = c.exists(try c.path(&.{ projectDir(exe), "package.json" }));
    return .{ .method = method(version, exe, manifest), .exe = exe };
}
fn notesUrl(c: *C, v: []const u8) ![]const u8 {
    return c.fmt("https://github.com/{s}/releases/tag/v{s}", .{ repoSlug(c), v });
}

// ec update and ec update --check.
pub fn run(c: *C, check: bool) !void {
    const how = try currentMethod(c);
    const release = freshRelease(c) orelse return c.fail("Could not read the latest ec release. Check your network, or run gh auth login while releases are private.", .{});
    const available = newer(release.version, version);
    const notes = try notesUrl(c, release.version);
    const Data = struct { current: []const u8, latest: []const u8, update_available: bool, updated: bool, method: Method, release_notes: []const u8 };
    var data: Data = .{ .current = version, .latest = release.version, .update_available = available, .updated = false, .method = how.method, .release_notes = notes };
    const head = try c.fmt("Update available {s} → {s}\n  Release notes  {s}", .{ version, release.version, notes });
    if (how.method == .development) {
        return c.resultData("update", true, try c.fmt("This ec is a development build. The latest release is {s}.\nRebuild it from source, or install the release:\n\n    curl -fsSL https://github.com/{s}/releases/latest/download/install.sh | sh", .{ release.version, repoSlug(c) }), data);
    }
    if (!available) return c.resultData("update", true, try c.fmt("ec {s} is up to date.", .{version}), data);
    if (check) {
        const next = if (how.method == .standalone) "Run ec update to install it." else "Run ec update for the install command.";
        return c.resultData("update", true, try c.fmt("{s}\n\n{s}", .{ head, next }), data);
    }
    switch (how.method) {
        .package => return c.resultData("update", true, try c.fmt("{s}\n\nec was installed from the npm tarball. Install the new one:\n\n    gh release download v{s} --repo {s} --pattern ender-chest-{s}.tgz\n    npm install --global ./ender-chest-{s}.tgz", .{ head, release.version, repoSlug(c), release.version, release.version }), data),
        .project => return c.resultData("update", true, try c.fmt("{s}\n\nec is a dependency of the project in {s}. Update ender-chest there.", .{ head, projectDir(how.exe) }), data),
        else => {},
    }
    const bytes = try download(c, release) orelse return c.fail("ec {s} was not installed; {s} is unchanged.", .{ release.version, how.exe });
    try replace(c, how.exe, bytes, release.version);
    data.updated = true;
    try c.resultData("update", true, try c.fmt("Updated ec {s} → {s}\n  Release notes  {s}", .{ version, release.version, notes }), data);
}

// Stages the new binary beside the old one, runs it once, then renames it into place.
fn replace(c: *C, exe: []const u8, bytes: []const u8, v: []const u8) !void {
    var random: [8]u8 = undefined;
    std.Io.random(c.io, &random);
    const dir = std.fs.path.dirname(exe) orelse ".";
    const staged = try c.path(&.{ dir, try c.fmt(".ec-update-{x}", .{random}) });
    c.write(staged, bytes, 0o755) catch return c.fail("Cannot write to {s}. Rerun the installer with EC_INSTALL_DIR set to a directory you own.", .{dir});
    defer c.remove(staged) catch {};
    const probe = c.capture(&.{ staged, "--version" }, null, 15) catch null;
    const expected = try c.fmt("ec {s} ", .{v});
    const ran = if (probe) |r| core.success(r.term) and std.mem.startsWith(u8, r.stdout, expected) else false;
    if (!ran) return c.fail("The downloaded ec {s} did not run on this machine; {s} is unchanged.", .{ v, exe });
    core.cwd().rename(staged, core.cwd(), exe, c.io) catch return c.fail("Cannot replace {s}.", .{exe});
}

// After an interactive command, says once a day when a newer release exists. The check sends one
// request to GitHub at most once a day and gives up after about three seconds.
pub fn notice(c: *C, command: @import("options.zig").Command) void {
    switch (command) {
        .verify, .push, .status, .plugin, .secret => {},
        else => return,
    }
    if (c.json or updatesDisabled(c) or truthy(c.env.get("NO_UPDATE_NOTIFIER")) or truthy(c.env.get("CI"))) return;
    if (!(std.Io.File.stdin().isTty(c.io) catch false) or !(c.stderr.isTty(c.io) catch false)) return;
    const how = currentMethod(c) catch return;
    if (how.method != .standalone and how.method != .package) return;
    var state = loadState(c);
    const now = nowSeconds(c.io);
    if (due(state.checked_at, now)) {
        state.checked_at = now;
        if (latestTag(c)) |tag| state.latest = tag;
        saveState(c, state);
    }
    if (!newer(state.latest, version) or !due(state.notified_at, now)) return;
    c.log("Update available {s} → {s} · Run ec update", .{ version, state.latest }) catch return;
    state.notified_at = now;
    saveState(c, state);
}
fn truthy(value: ?[]const u8) bool {
    const v = value orelse return false;
    return v.len > 0 and !eq(u8, v, "0") and !eq(u8, v, "false");
}
// A clock that moved backwards makes a saved time due again.
pub fn due(since: i64, now: i64) bool {
    return now < since or now - since >= day_seconds;
}
const State = struct { checked_at: i64 = 0, latest: []const u8 = "", notified_at: i64 = 0 };
fn statePath(c: *C) ![]const u8 {
    return c.path(&.{ c.home, ".config/ender-chest/update-check.json" });
}
fn loadState(c: *C) State {
    const v = c.readJson(statePath(c) catch return .{}) catch return .{};
    if (v != .object) return .{};
    const int = struct {
        fn get(o: std.json.Value, key: []const u8) i64 {
            const x = o.object.get(key) orelse return 0;
            return if (x == .integer) x.integer else 0;
        }
    }.get;
    return .{ .checked_at = int(v, "checked_at"), .latest = core.string(v, "latest") orelse "", .notified_at = int(v, "notified_at") };
}
fn saveState(c: *C, state: State) void {
    const text = std.json.Stringify.valueAlloc(c.a, state, .{}) catch return;
    c.write(statePath(c) catch return, text, 0o600) catch {};
}
fn recordLatest(c: *C, v: []const u8) void {
    var state = loadState(c);
    state.checked_at = nowSeconds(c.io);
    state.latest = v;
    saveState(c, state);
}
// The latest release's version from its tag, in one quick request.
fn latestTag(c: *C) ?[]const u8 {
    const token = githubToken(c) orelse "";
    const url = c.fmt("https://api.github.com/repos/{s}/releases/latest", .{repoSlug(c)}) catch return null;
    const body = request(c, token, url, "application/vnd.github+json", true) orelse return null;
    const tag = core.string(c.parse(body) catch return null, "tag_name") orelse return null;
    const v = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    return if (validVersion(v)) v else null;
}
// The latest release with its manifest, read now rather than from a cache.
fn freshRelease(c: *C) ?Release {
    const release = if (c.env.get("EC_RELEASE_MANIFEST")) |path| (if (path.len > 0) readManifestFile(c, path) else null) else null;
    const found = release orelse blk: {
        const fetched = fetchRelease(c) orelse return null;
        break :blk switch (fetched) {
            .release => |r| r,
            else => return null,
        };
    };
    if (validVersion(found.version)) recordLatest(c, found.version);
    return found;
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
    return request(c, token, url, accept, false);
}
// quick allows one attempt of about three seconds and stays silent, for the launch notice.
fn request(c: *C, token: []const u8, url: []const u8, accept: []const u8, quick: bool) ?[]const u8 {
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
    const argv: []const []const u8 = if (quick) &.{ "curl", "-fsSL", "--max-time", "3", "--config", cfg, "-o", out, "--", url } else &.{ "curl", "-fsSL", "--retry", "3", "--max-time", "30", "--config", cfg, "-o", out, "--", url };
    const result = c.capture(argv, null, if (quick) 5 else 45) catch return null;
    if (!core.success(result.term)) {
        if (quick) return null;
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

test "versions compare by number and reject anything but X.Y.Z" {
    try std.testing.expect(validVersion("0.0.1") and validVersion("10.20.30"));
    for ([_][]const u8{ "dev", "", "1.2", "1.2.3.4", "01.2.3", "1.2.3-beta", "v1.2.3", "1..3" }) |bad| try std.testing.expect(!validVersion(bad));
    try std.testing.expect(newer("0.0.10", "0.0.9") and newer("0.1.0", "0.0.99") and newer("1.0.0", "0.9.9"));
    try std.testing.expect(!newer("0.0.9", "0.0.10") and !newer("0.0.5", "0.0.5"));
    // A development build is never older or newer than a release.
    try std.testing.expect(!newer("0.0.9", "dev") and !newer("dev", "0.0.1"));
}

test "install method follows where the binary lives" {
    try std.testing.expectEqual(Method.development, method("dev", "/home/u/.local/bin/ec", false));
    try std.testing.expectEqual(Method.standalone, method("0.0.5", "/home/u/.local/bin/ec", false));
    try std.testing.expectEqual(Method.package, method("0.0.5", "/opt/homebrew/lib/node_modules/ender-chest/native/ec-aarch64-macos", false));
    try std.testing.expectEqual(Method.package, method("0.0.5", "/home/u/.bun/install/global/node_modules/ender-chest/native/ec-x86_64-linux", true));
    try std.testing.expectEqual(Method.package, method("0.0.5", "/home/u/.local/share/pnpm/global/v11/abc/node_modules/.pnpm/ender-chest@0.0.5/node_modules/ender-chest/native/ec-x86_64-linux", true));
    try std.testing.expectEqual(Method.project, method("0.0.5", "/work/app/node_modules/ender-chest/native/ec-x86_64-linux", true));
    try std.testing.expectEqualStrings("/work/app", projectDir("/work/app/node_modules/ender-chest/native/ec"));
}

test "update checks and notices are due once a day" {
    try std.testing.expect(due(0, day_seconds) and !due(100, 100 + day_seconds - 1));
    try std.testing.expect(due(100, 50));
}
