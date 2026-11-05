// Stops stale dev servers, watchers, headless browsers, and containers before a benchmark.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core.zig");
const runtime = @import("runtime.zig");
const C = core.Context;
const Call = runtime.Call;
const eq = core.eql;

const idle_seconds = 2 * 60 * 60;

pub const Proc = struct { pid: i32, ppid: i32, age: i64, cpu: f64, command: []const u8 };
const Server = struct { pid: i32, kind: []const u8, age: i64, cwd: []const u8 = "", reason: []const u8 = "" };
const Container = struct { id: []const u8, name: []const u8 };
const Busy = struct { pid: i32, cpu: f64, name: []const u8 };

// Dev tools that agents start and forget. Agent CLIs also run on node, so match the tool, not the runtime.
const signatures = [_]struct { needle: []const u8, kind: []const u8 }{
    .{ .needle = "node_modules/next/dist/", .kind = "next" },
    .{ .needle = "next-server", .kind = "next" },
    .{ .needle = "next dev", .kind = "next" },
    .{ .needle = "next start", .kind = "next" },
    .{ .needle = "vite/bin/vite", .kind = "vite" },
    .{ .needle = "storybook", .kind = "storybook" },
    .{ .needle = "node_modules/astro/", .kind = "astro" },
    .{ .needle = "nuxi", .kind = "nuxt" },
    .{ .needle = "nuxt dev", .kind = "nuxt" },
    .{ .needle = "node_modules/nuxt/", .kind = "nuxt" },
    .{ .needle = "node_modules/wrangler/", .kind = "wrangler" },
    .{ .needle = "wrangler dev", .kind = "wrangler" },
    .{ .needle = "workerd serve", .kind = "wrangler" },
    .{ .needle = "esbuild --service", .kind = "esbuild" },
    .{ .needle = "turbo run dev", .kind = "turbo" },
    .{ .needle = "turbo dev", .kind = "turbo" },
    .{ .needle = "tsx watch", .kind = "tsx" },
    .{ .needle = "webpack serve", .kind = "webpack" },
    .{ .needle = "playwright run-server", .kind = "playwright" },
    .{ .needle = "chrome-headless-shell", .kind = "headless-chrome" },
    .{ .needle = "ms-playwright", .kind = "headless-chrome" },
};
// Never touch agents, T3 Code, or the servers the executor and cliproxyapi plugins run, even
// when a path matches above.
const protected = [_][]const u8{ "claude", "codex", "grok", "t3code", "T3 Code", "/.t3/tools/", "/.t3/runtime/", "executor", "cliproxy" };
fn guarded(command: []const u8) bool {
    for (protected) |word| if (std.mem.indexOf(u8, command, word) != null) return true;
    return false;
}

pub fn kind(command: []const u8) ?[]const u8 {
    if (guarded(command)) return null;
    for (signatures) |s| if (std.mem.indexOf(u8, command, s.needle) != null) return s.kind;
    return null;
}

// ps prints elapsed time as [[dd-]hh:]mm:ss.
pub fn elapsed(text: []const u8) ?i64 {
    var days: i64 = 0;
    var rest = text;
    if (std.mem.indexOfScalar(u8, text, '-')) |dash| {
        days = std.fmt.parseInt(i64, text[0..dash], 10) catch return null;
        rest = text[dash + 1 ..];
    }
    var total: i64 = 0;
    var it = std.mem.splitScalar(u8, rest, ':');
    var parts: usize = 0;
    while (it.next()) |part| : (parts += 1) total = total * 60 + (std.fmt.parseInt(i64, part, 10) catch return null);
    if (parts < 2 or parts > 3) return null;
    return days * 86400 + total;
}

pub fn parsePs(c: *C, text: []const u8) ![]Proc {
    var list: std.ArrayList(Proc) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const pid = std.fmt.parseInt(i32, fields.next() orelse continue, 10) catch continue;
        const ppid = std.fmt.parseInt(i32, fields.next() orelse continue, 10) catch continue;
        const age = elapsed(fields.next() orelse continue) orelse continue;
        const cpu = std.fmt.parseFloat(f64, fields.next() orelse continue) catch continue;
        const command = core.trim(fields.rest());
        if (command.len == 0) continue;
        try list.append(c.a, .{ .pid = pid, .ppid = ppid, .age = age, .cpu = cpu, .command = command });
    }
    return list.items;
}

fn duration(c: *C, seconds: i64) ![]const u8 {
    const h = @divFloor(seconds, 3600);
    const m = @divFloor(@mod(seconds, 3600), 60);
    const hu: u64 = @intCast(h);
    const mu: u64 = @intCast(m);
    if (hu >= 48) return c.fmt("{d}d", .{hu / 24});
    if (hu > 0) return c.fmt("{d}h{d:0>2}m", .{ hu, mu });
    return c.fmt("{d}m", .{mu});
}
fn short(c: *C, p: []const u8) ![]const u8 {
    if (c.home.len > 0 and std.mem.startsWith(u8, p, c.home)) return c.fmt("~{s}", .{p[c.home.len..]});
    return p;
}
fn inside(dir: []const u8, p: []const u8) bool {
    return eq(u8, dir, p) or (std.mem.startsWith(u8, p, dir) and p.len > dir.len and p[dir.len] == '/');
}

pub fn run(c: *C, call: Call) !bool {
    if (!eq(u8, call.command, "stop")) return c.fail("Unknown quiet command {s}.", .{call.command});
    const all = call.flag("all");
    const dry_run = call.flag("dry-run");
    const listed = try c.capture(&.{ "ps", "-x", "-U", try c.fmt("{d}", .{std.c.getuid()}), "-o", "pid=,ppid=,etime=,pcpu=,command=" }, null, 15);
    if (!core.success(listed.term)) return c.fail("ps failed: {s}", .{core.trim(listed.stderr)});
    const procs = try parsePs(c, listed.stdout);

    // Keep this process's ancestors (the agent that called ec) and the caller's worktree.
    var ancestors: std.AutoHashMapUnmanaged(i32, void) = .empty;
    var pid: i32 = std.c.getpid();
    var hops: usize = 0;
    while (pid > 1 and hops < 64) : (hops += 1) {
        try ancestors.put(c.a, pid, {});
        pid = for (procs) |p| {
            if (p.pid == pid) break p.ppid;
        } else break;
    }
    const keep_dir: ?[]const u8 = blk: {
        const r = c.capture(&.{ "git", "rev-parse", "--show-toplevel" }, null, 10) catch break :blk null;
        break :blk if (core.success(r.term)) core.trim(r.stdout) else null;
    };

    var found: std.ArrayList(Server) = .empty;
    for (procs) |p| {
        if (ancestors.contains(p.pid)) continue;
        const k = kind(p.command) orelse continue;
        // Preview browsers and helpers that an agent owns are direct children of a protected process.
        if (for (procs) |parent| {
            if (parent.pid == p.ppid) break guarded(parent.command);
        } else false) continue;
        try found.append(c.a, .{ .pid = p.pid, .kind = k, .age = p.age });
    }
    try workingDirs(c, found.items);

    var stop: std.ArrayList(Server) = .empty;
    var kept_here: usize = 0;
    var kept_young: usize = 0;
    for (found.items) |*s| {
        if (guarded(s.cwd)) continue;
        if (s.cwd.len > 0 and !c.exists(s.cwd)) {
            s.reason = "worktree deleted";
        } else if (keep_dir != null and s.cwd.len > 0 and inside(keep_dir.?, s.cwd)) {
            kept_here += 1;
            continue;
        } else if (s.age >= idle_seconds) {
            s.reason = try c.fmt("running {s}", .{try duration(c, s.age)});
        } else if (all) {
            s.reason = "--all";
        } else {
            kept_young += 1;
            continue;
        }
        try stop.append(c.a, s.*);
    }

    const containers = try runningContainers(c);
    var failed: std.ArrayList(i32) = .empty;
    var containers_failed = false;
    if (!dry_run) {
        if (stop.items.len > 0) failed = try terminate(c, stop.items);
        if (containers.len > 0) {
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(c.a, &.{ "docker", "stop", "--time", "10" });
            for (containers) |ct| try args.append(c.a, ct.id);
            const r = c.capture(args.items, null, 180) catch null;
            containers_failed = r == null or !core.success(r.?.term);
        }
    }

    // Report the heaviest processes left, without touching them.
    var busy: std.ArrayList(Busy) = .empty;
    for (procs) |p| {
        if (p.cpu < 10 or ancestors.contains(p.pid)) continue;
        if (for (stop.items) |s| {
            if (s.pid == p.pid) break true;
        } else false) continue;
        const first = std.mem.sliceTo(p.command, ' ');
        try busy.append(c.a, .{ .pid = p.pid, .cpu = p.cpu, .name = std.fs.path.basename(first) });
    }
    std.mem.sort(Busy, busy.items, {}, struct {
        fn more(_: void, x: Busy, y: Busy) bool {
            return x.cpu > y.cpu;
        }
    }.more);
    const busiest = busy.items[0..@min(busy.items.len, 5)];
    const disk_free_gb = diskFree(c);

    var text: std.ArrayList(u8) = .empty;
    const verb = if (dry_run) "Would stop" else "Stopped";
    if (stop.items.len + containers.len == 0) {
        try text.appendSlice(c.a, "Nothing to stop.\n");
    } else {
        try text.appendSlice(c.a, try c.fmt("{s} {d} dev process(es) and {d} container(s).\n", .{ verb, stop.items.len, containers.len }));
        for (stop.items) |s| try text.appendSlice(c.a, try c.fmt("  {s:<16} pid {d:<7} {s}  ({s})\n", .{ s.kind, @as(u32, @intCast(s.pid)), if (s.cwd.len > 0) try short(c, s.cwd) else "?", s.reason }));
        for (containers) |ct| try text.appendSlice(c.a, try c.fmt("  {s:<16} {s}\n", .{ "container", ct.name }));
    }
    if (kept_here > 0) try text.appendSlice(c.a, try c.fmt("Kept {d} in this worktree.\n", .{kept_here}));
    if (kept_young > 0) try text.appendSlice(c.a, try c.fmt("Kept {d} started in the last 2h. Add --all to stop them too.\n", .{kept_young}));
    if (failed.items.len > 0) try text.appendSlice(c.a, try c.fmt("Could not stop {d} process(es).\n", .{failed.items.len}));
    if (containers_failed) try text.appendSlice(c.a, "docker stop failed for some containers.\n");
    if (busiest.len > 0) {
        try text.appendSlice(c.a, "Busiest now:");
        for (busiest, 0..) |b, i| try text.appendSlice(c.a, try c.fmt("{s} {s} {d:.0}%", .{ if (i == 0) "" else ",", b.name, b.cpu }));
        try text.appendSlice(c.a, "\n");
    }
    if (disk_free_gb) |gb| try text.appendSlice(c.a, try c.fmt("Disk free: {d} GB.\n", .{gb}));

    const ok = failed.items.len == 0 and !containers_failed;
    if (!ok) c.error_code = "stop_failed";
    try c.resultData("quiet stop", ok, core.trim(text.items), .{ .dry_run = dry_run, .stopped = stop.items, .containers = containers, .kept_in_worktree = kept_here, .kept_recent = kept_young, .failed = failed.items, .busiest = busiest, .disk_free_gb = disk_free_gb });
    return ok;
}

fn workingDirs(c: *C, servers: []Server) !void {
    if (servers.len == 0) return;
    if (builtin.os.tag == .linux) {
        for (servers) |*s| {
            const r = c.capture(&.{ "readlink", try c.fmt("/proc/{d}/cwd", .{s.pid}) }, null, 5) catch continue;
            if (!core.success(r.term)) continue;
            const target = core.trim(r.stdout);
            s.cwd = if (std.mem.endsWith(u8, target, " (deleted)")) target[0 .. target.len - 10] else target;
        }
        return;
    }
    var pids: std.ArrayList(u8) = .empty;
    for (servers, 0..) |s, i| try pids.appendSlice(c.a, try c.fmt("{s}{d}", .{ if (i == 0) "" else ",", s.pid }));
    // lsof exits 1 when one of the processes is gone; the rest of its output still counts.
    const r = c.capture(&.{ "lsof", "-a", "-d", "cwd", "-Fpn", "-p", pids.items }, null, 20) catch return;
    var current: i32 = 0;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        if (line[0] == 'p') current = std.fmt.parseInt(i32, line[1..], 10) catch 0;
        if (line[0] == 'n') for (servers) |*s| if (s.pid == current) {
            s.cwd = line[1..];
        };
    }
}

fn runningContainers(c: *C) ![]Container {
    if (!c.commandExists("docker")) return &.{};
    const r = c.capture(&.{ "docker", "ps", "--format", "{{.ID}}\t{{.Names}}" }, null, 15) catch return &.{};
    // A stopped daemon is a quiet daemon.
    if (!core.success(r.term)) return &.{};
    var list: std.ArrayList(Container) = .empty;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        try list.append(c.a, .{ .id = line[0..tab], .name = core.trim(line[tab + 1 ..]) });
    }
    return list.items;
}

// SIGTERM first so dev servers can clean up, then SIGKILL whatever is left after five seconds.
fn terminate(c: *C, servers: []const Server) !std.ArrayList(i32) {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(c.a, &.{ "kill", "-TERM" });
    for (servers) |s| try args.append(c.a, try c.fmt("{d}", .{s.pid}));
    _ = c.capture(args.items, null, 10) catch {};
    var alive: std.ArrayList(i32) = .empty;
    var waited: usize = 0;
    while (true) : (waited += 1) {
        alive.clearRetainingCapacity();
        for (servers) |s| if (try running(c, s.pid)) try alive.append(c.a, s.pid);
        if (alive.items.len == 0 or waited >= 5) break;
        try std.Io.sleep(c.io, .fromSeconds(1), .awake);
    }
    if (alive.items.len == 0) return alive;
    args.items[1] = "-KILL";
    args.shrinkRetainingCapacity(2);
    for (alive.items) |p| try args.append(c.a, try c.fmt("{d}", .{p}));
    _ = c.capture(args.items, null, 10) catch {};
    var failed: std.ArrayList(i32) = .empty;
    for (alive.items) |p| if (try running(c, p)) try failed.append(c.a, p);
    return failed;
}
fn running(c: *C, pid: i32) !bool {
    const r = c.capture(&.{ "kill", "-0", try c.fmt("{d}", .{pid}) }, null, 5) catch return false;
    return core.success(r.term);
}

fn diskFree(c: *C) ?u64 {
    const r = c.capture(&.{ "df", "-Pk", if (c.home.len > 0) c.home else "/" }, null, 10) catch return null;
    if (!core.success(r.term)) return null;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    _ = lines.next();
    var fields = std.mem.tokenizeAny(u8, lines.next() orelse return null, " \t");
    _ = fields.next();
    _ = fields.next();
    _ = fields.next();
    const kb = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    return kb / (1024 * 1024);
}

test "match dev tools but never agents" {
    try std.testing.expectEqualStrings("next", kind("node /w/node_modules/.bin/../next/dist/bin/next dev --port 3000").?);
    try std.testing.expectEqualStrings("next", kind("node /w/node_modules/.pnpm/next@16/node_modules/next/dist/telemetry/detached-flush.js dev /w/apps/x").?);
    try std.testing.expectEqualStrings("vite", kind("node /w/node_modules/vite/bin/vite.js").?);
    try std.testing.expectEqualStrings("headless-chrome", kind("/home/user/.cache/ms-playwright/chromium-1200/chrome-linux/chrome --headless").?);
    try std.testing.expect(kind("node /opt/homebrew/bin/claude --resume") == null);
    try std.testing.expect(kind("node /home/user/.claude/storybook-helper.js") == null);
    try std.testing.expect(kind("/Applications/Browser.app/Contents/MacOS/Browser") == null);
    try std.testing.expect(kind("/home/user/.t3/tools/chrome-headless-shell/linux64/154/chrome-headless-shell --headless") == null);
}
test "parse ps elapsed times" {
    try std.testing.expectEqual(@as(?i64, 75), elapsed("01:15"));
    try std.testing.expectEqual(@as(?i64, 3 * 3600 + 5), elapsed("03:00:05"));
    try std.testing.expectEqual(@as(?i64, 2 * 86400 + 3600), elapsed("2-01:00:00"));
    try std.testing.expect(elapsed("abc") == null);
    try std.testing.expect(elapsed("5") == null);
}
