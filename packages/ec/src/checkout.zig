// Finds the config checkout and this machine's profile, and brings the checkout up to date.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const paths = @import("paths.zig");
const C = core.Context;
const eq = core.eql;

// How resolve and profile choose, as help shows it for --repo and --profile.
pub const resolve_rule = "EC_REPO, current or saved checkout; linked worktrees use the primary checkout";
pub const profile_rule = "mac on macOS, cloud in CI, containers, and Linux";

// The checkout from --repo, EC_REPO, the current directory, or the one the last sync used. A
// linked worktree resolves to its primary checkout unless --repo or EC_REPO names it.
pub fn resolve(c: *C, flag: ?[]const u8) ![]const u8 {
    const configured = c.env.get("EC_REPO");
    const saved = try c.optional(try paths.inHome(c, paths.saved_repo));
    const current = try std.process.currentPathAlloc(c.io, c.a);
    const chosen = flag orelse configured orelse if (c.exists(try c.path(&.{ current, paths.manifest_file }))) current else if (saved) |s| core.trim(s) else current;
    var repo: []const u8 = try std.fs.path.resolve(c.a, &.{chosen});
    if (flag == null and configured == null) repo = try primaryCheckout(c, repo);
    if (!c.exists(try c.path(&.{ repo, paths.manifest_file }))) return c.fail("No ender-chest config checkout at {s}: it has no {s}. Use --repo PATH or set EC_REPO.", .{ repo, paths.manifest_file });
    return repo;
}
pub fn remember(c: *C) !void {
    try c.write(try paths.inHome(c, paths.saved_repo), try c.fmt("{s}\n", .{c.repo}), 0o600);
}
pub fn profile(c: *C, flag: ?[]const u8) []const u8 {
    if (flag) |f| return f;
    for ([_][]const u8{ "CODESPACES", "GITHUB_CODESPACE_TOKEN", "CODEX_CLOUD", "CLOUD_AGENT", "CI" }) |key| {
        if (c.env.get(key)) |v| if (v.len > 0) return "cloud";
    }
    return if (builtin.os.tag == .macos and !c.exists("/.dockerenv")) "mac" else "cloud";
}
fn primaryCheckout(c: *C, repo: []const u8) ![]const u8 {
    if (!c.exists(try c.path(&.{ repo, ".git" }))) return repo;
    const r = try c.capture(&.{ "git", "rev-parse", "--git-common-dir" }, repo, 15);
    if (!core.success(r.term)) return repo;
    const common = core.trim(r.stdout);
    if (common.len == 0) return repo;
    const abs = if (std.fs.path.isAbsolute(common)) common else try c.path(&.{ repo, common });
    const resolved = try std.fs.path.resolve(c.a, &.{abs});
    if (std.mem.endsWith(u8, resolved, "/.git")) return resolved[0 .. resolved.len - 5];
    return repo;
}
// Fast-forwards a clean checkout. Offline machines and failed pulls keep the local tree.
pub fn pull(c: *C) !void {
    if (!c.exists(try paths.inRepo(c, ".git"))) return;
    const dirty = try c.capture(&.{ "git", "status", "--porcelain" }, c.repo, 15);
    if (!core.success(dirty.term)) return error.GitStatusFailed;
    if (core.trim(dirty.stdout).len > 0) {
        try c.log("Working tree has changes; applying it without pulling.", .{});
        return;
    }
    const remote = try c.capture(&.{ "git", "remote" }, c.repo, 15);
    if (core.trim(remote.stdout).len == 0) return;
    const fetched = c.capture(&.{ "git", "fetch" }, c.repo, 15) catch {
        try c.log("warning: git fetch failed or timed out; applying the local tree.", .{});
        return;
    };
    if (!core.success(fetched.term)) {
        try c.log("warning: git fetch failed; applying the local tree.", .{});
        return;
    }
    const target = try pullTarget(c) orelse return;
    const merged = c.capture(&.{ "git", "merge", "--ff-only", target }, c.repo, 15) catch {
        try c.log("warning: git pull failed or timed out; applying the local tree.", .{});
        return;
    };
    if (!core.success(merged.term)) try c.log("warning: git pull failed; applying the local tree.", .{});
}
fn pullTarget(c: *C) !?[]const u8 {
    const upstream = try c.capture(&.{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, c.repo, 15);
    if (core.success(upstream.term)) {
        const name = core.trim(upstream.stdout);
        if (name.len > 0) return name;
    }
    const branch = try c.capture(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, c.repo, 15);
    if (!core.success(branch.term)) return null;
    const current = core.trim(branch.stdout);
    if (current.len == 0 or eq(u8, current, "HEAD")) return null;
    const head = try c.capture(&.{ "git", "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" }, c.repo, 15);
    if (core.success(head.term)) {
        const ref = core.trim(head.stdout);
        const prefix = "refs/remotes/";
        if (std.mem.startsWith(u8, ref, prefix)) {
            const remote_branch = ref[prefix.len..];
            const slash = std.mem.lastIndexOfScalar(u8, remote_branch, '/') orelse return null;
            if (eq(u8, current, remote_branch[slash + 1 ..])) return remote_branch;
        }
        return null;
    }
    if (eq(u8, current, "main") or eq(u8, current, "master")) {
        const candidate = try c.fmt("origin/{s}", .{current});
        const has = try c.capture(&.{ "git", "rev-parse", "--verify", "--quiet", candidate }, c.repo, 15);
        if (core.success(has.term)) return candidate;
    }
    return null;
}
