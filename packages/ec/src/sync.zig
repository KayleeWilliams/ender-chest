// ec sync, verify, and push: apply the checkout to this machine, check it, or capture changes back.
const std = @import("std");
const core = @import("core.zig");
const C = core.Context;
const cli = @import("options.zig");
const O = cli.Options;
const release = @import("release.zig");
const build_info = @import("build_info.zig");
const paths = @import("paths.zig");
const checkout = @import("checkout.zig");
const manifest = @import("manifest.zig");
const plugin = @import("plugin.zig");
const contribution = @import("contributions.zig");
const files = @import("files.zig");
const packages = @import("packages.zig");
const agents = @import("agents.zig");
const skills = @import("skills.zig");
const eq = core.eql;

// Selects the checkout and returns this machine's profile. Git never prompts, and setup steps
// and plugins see the checkout as EC_REPO.
fn open(c: *C, o: O) ![]const u8 {
    c.repo = try checkout.resolve(c, o.repo);
    try c.env.put("GIT_TERMINAL_PROMPT", "0");
    try c.env.put("GIT_PAGER", "cat");
    try c.env.put("EC_REPO", c.repo);
    return checkout.profile(c, o.profile);
}
// Set to the checkout when sync resumes itself with a newer ec, which then skips the pull and
// the release check that already ran.
const resumed_var = "EC_SYNC_RESUMED";
pub fn sync(c: *C, o: O) !core.Outcome {
    const p = try open(c, o);
    const resumed = if (c.env.get(resumed_var)) |r| eq(u8, r, c.repo) else false;
    _ = c.env.swapRemove(resumed_var);
    if (!resumed) {
        try checkout.pull(c);
        try selfUpdate(c, o);
    }
    const m = try manifest.load(c);
    const plugins = try plugin.loadAll(c, m, true);
    const contrib = try plugin.contributions(c, plugins);
    // Files first, so setup steps see them and installers that keep an existing ~/.zshrc keep ours.
    try files.apply(c, m, p);
    try packages.apply(c, m, p, o.skip_packages);
    try agents.apply(c, contrib);
    try skills.apply(c, p, o.update_skills);
    try installBinary(c);
    try checkout.remember(c);
    for (plugins) |e| if (!try plugin.hook(c, e, e.plugin.hook_sync)) return c.fail("The {s} plugin's sync hook failed. Check the output above.", .{e.plugin.name});
    try check(c, m, p, plugins, contrib);
    return c.result("sync", try c.fmt("Synced {s} profile. Verification passed.", .{p}));
}
// Installs a newer release over the installed ec, then resumes this sync with it. Development
// builds keep themselves. A release that cannot install leaves this ec to finish the sync.
fn selfUpdate(c: *C, o: O) !void {
    if (release.disabled(c) or !release.validVersion(build_info.version)) return;
    const r = release.latest(c) orelse return c.log("Could not check for a newer ec release; syncing with ec {s}.", .{build_info.version});
    if (!release.newer(r.version, build_info.version)) return;
    const dest = try paths.inHome(c, paths.ec_bin);
    release.install(c, r, dest) catch |err| return c.log("{s}", .{try c.recover(err)});
    try c.log("Updating ec {s} to {s}.", .{ build_info.version, r.version });
    try c.env.put(resumed_var, c.repo);
    var again = o;
    again.repo = c.repo;
    const err = std.process.replace(c.io, .{ .argv = try cli.argv(c.a, dest, again), .environ_map = c.env });
    return c.fail("Cannot run the new ec at {s}: {s}.", .{ dest, @errorName(err) });
}
pub fn verify(c: *C, o: O) !core.Outcome {
    const p = try open(c, o);
    const m = try manifest.load(c);
    const plugins = try plugin.loadAll(c, m, false);
    try check(c, m, p, plugins, try plugin.contributions(c, plugins));
    return c.result("verify", "Verification passed.");
}
fn check(c: *C, m: manifest.Manifest, p: []const u8, plugins: []const plugin.Enabled, contrib: contribution.Contributions) !void {
    var checks: core.Checks = .{};
    try files.verify(c, m, p, &checks);
    try agents.verify(c, contrib, &checks);
    try checks.file(c, try paths.inHome(c, paths.ec_bin));
    for (plugins) |e| if (!try plugin.hook(c, e, e.plugin.hook_verify)) try checks.fail(c, "the {s} plugin's verify hook failed.", .{e.plugin.name});
    try skills.verify(c, p, &checks);
    if (checks.failed > 0) return c.failCode(.verification_failed, "Verification failed with {d} issue(s). Run ec sync to apply missing files.", .{checks.failed});
}
fn installBinary(c: *C) !void {
    const exe = try std.process.executablePathAlloc(c.io, c.a);
    const dest = try paths.inHome(c, paths.ec_bin);
    if (!eq(u8, exe, dest)) try c.copy(exe, dest, 0o755);
}

pub fn push(c: *C, o: O) !core.Outcome {
    const p = try open(c, o);
    const m = try manifest.load(c);
    const extra = try files.capture(c, m, p);
    try skills.capture(c);
    try files.refusePrivate(c, try agents.privatePaths(c));
    const status = try c.capture(&.{ "git", "status", "--short" }, c.repo, 15);
    if (!core.success(status.term)) return error.GitStatusFailed;
    if (core.trim(status.stdout).len == 0) return c.result("push", "Nothing to upload.");
    try c.stderr.writeStreamingAll(c.io, status.stdout);
    if (o.dry_run) return c.result("push", "Dry-run: captured managed files without committing or pushing.");
    const staged = try c.capture(&.{ "git", "diff", "--cached", "--name-only", "-z" }, c.repo, 15);
    if (!core.success(staged.term)) return error.GitStatusFailed;
    var names = std.mem.splitScalar(u8, staged.stdout, 0);
    while (names.next()) |n| {
        if (n.len > 0 and !allowed(n, extra)) return c.fail("Unrelated staged file: {s}. Unstage it before ec push.", .{n});
    }
    var present: std.ArrayList([]const u8) = .empty;
    for (paths.upload) |path| try addPath(c, &present, path);
    for (extra) |path| try addPath(c, &present, path);
    if (present.items.len > 0) try c.command(try std.mem.concat(c.a, []const u8, &.{ &.{ "git", "add", "-A", "--" }, present.items }), c.repo);
    const diff = try c.capture(&.{ "git", "diff", "--cached", "--quiet" }, c.repo, 15);
    if (core.success(diff.term)) return c.result("push", "No managed changes to upload.");
    if (diff.term != .exited or diff.term.exited != 1) return error.GitDiffFailed;
    try c.command(&.{ "git", "commit", "-m", "Update machine config" }, c.repo);
    try c.command(&.{ "git", "pull", "--rebase", "--autostash" }, c.repo);
    try c.command(&.{ "git", "push" }, c.repo);
    return c.result("push", "Uploaded. Run ec sync on each other machine when ready.");
}
fn allowed(path: []const u8, extra: []const []const u8) bool {
    for (paths.upload) |p| if (under(path, p)) return true;
    for (extra) |p| if (under(path, p)) return true;
    return false;
}
fn under(path: []const u8, p: []const u8) bool {
    return eq(u8, path, p) or (std.mem.startsWith(u8, path, p) and path.len > p.len and path[p.len] == '/');
}
fn addPath(c: *C, args: *std.ArrayList([]const u8), path: []const u8) !void {
    if (c.exists(try paths.inRepo(c, path))) return args.append(c.a, path);
    const tracked = try c.capture(&.{ "git", "ls-files", "--", path }, c.repo, 15);
    if (core.trim(tracked.stdout).len > 0) try args.append(c.a, path);
}
