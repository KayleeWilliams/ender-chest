// ec update, and the daily notice that a newer release exists.
const std = @import("std");
const core = @import("core.zig");
const release = @import("release.zig");
const build_info = @import("build_info.zig");
const C = core.Context;
const version = build_info.version;

// How this copy of ec was installed, which decides how ec update replaces it.
const Method = enum { development, standalone, package, project };
fn method(v: []const u8, exe: []const u8, project_manifest: bool) Method {
    if (!release.validVersion(v)) return .development;
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

pub fn run(c: *C, check: bool) !core.Outcome {
    const how = try currentMethod(c);
    const r = release.latest(c) orelse return c.fail("Could not read the latest ec release. Check your network, or run gh auth login while releases are private.", .{});
    const available = release.newer(r.version, version);
    const notes = try release.notesUrl(c, r.version);
    const Data = struct { current: []const u8, latest: []const u8, update_available: bool, updated: bool, method: Method, release_notes: []const u8 };
    var data: Data = .{ .current = version, .latest = r.version, .update_available = available, .updated = false, .method = how.method, .release_notes = notes };
    const head = try c.fmt("Update available {s} → {s}\n  Release notes  {s}", .{ version, r.version, notes });
    if (how.method == .development) {
        return c.resultData("update", try c.fmt("This ec is a development build. The latest release is {s}.\nRebuild it from source, or install the release:\n\n    {s}", .{ r.version, try release.installerCommand(c) }), data);
    }
    if (!available) return c.resultData("update", try c.fmt("ec {s} is up to date.", .{version}), data);
    if (check) {
        const next = if (how.method == .standalone) "Run ec update to install it." else "Run ec update for the install command.";
        return c.resultData("update", try c.fmt("{s}\n\n{s}", .{ head, next }), data);
    }
    switch (how.method) {
        .package => {
            if (std.ascii.eqlIgnoreCase(release.repoSlug(c), "KayleeWilliams/ender-chest")) {
                return c.resultData("update", try c.fmt("{s}\n\nec was installed with npm. Install the new version:\n\n    npm install --global ender-chest@{s}", .{ head, r.version }), data);
            }
            const file = try release.tarball(c, r.version);
            return c.resultData("update", try c.fmt("{s}\n\nec was installed from the npm tarball. Install the new one:\n\n    gh release download v{s} --repo {s} --pattern {s}\n    npm install --global ./{s}", .{ head, r.version, release.repoSlug(c), file, file }), data);
        },
        .project => return c.resultData("update", try c.fmt("{s}\n\nec is a dependency of the project in {s}. Update ender-chest there.", .{ head, projectDir(how.exe) }), data),
        .standalone, .development => {},
    }
    try release.install(c, r, how.exe);
    data.updated = true;
    return c.resultData("update", try c.fmt("Updated ec {s} → {s}\n  Release notes  {s}", .{ version, r.version, notes }), data);
}

pub fn notice(c: *C) void {
    if (c.json or release.disabled(c) or core.truthy(c.env.get("NO_UPDATE_NOTIFIER")) or core.truthy(c.env.get("CI"))) return;
    if (!(std.Io.File.stdin().isTty(c.io) catch false) or !(c.stderr.isTty(c.io) catch false)) return;
    const how = currentMethod(c) catch return;
    if (how.method != .standalone and how.method != .package) return;
    var cache = release.Cache.load(c);
    const now = core.unixSeconds(c.io);
    if (release.due(cache.checked_at, now)) {
        cache.checked_at = now;
        if (release.latestVersion(c)) |v| cache.latest = v;
        cache.save(c);
    }
    if (!release.newer(cache.latest, version) or !release.due(cache.notified_at, now)) return;
    c.log("Update available {s} → {s} · Run ec update", .{ version, cache.latest }) catch return;
    cache.notified_at = now;
    cache.save(c);
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
