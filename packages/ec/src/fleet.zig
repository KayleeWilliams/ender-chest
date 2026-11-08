// ec status and ec sync --all: every machine's ec and config commit, compared with the latest
// release and the config repo's main branch.
const std = @import("std");
const core = @import("core.zig");
const paths = @import("paths.zig");
const release = @import("release.zig");
const build_info = @import("build_info.zig");
const host = @import("host.zig");
const C = core.Context;
const eq = core.eql;

const State = enum { unknown, current, behind, offline, @"unreachable", missing };

const Machine = struct {
    name: []const u8,
    host: []const u8,
    os: []const u8,
    here: bool = false,
    online: bool = true,
    state: State = .unknown,
    version: ?[]const u8 = null,
    source_hash: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    detail: []const u8 = "",
};
const Expected = struct { version: ?[]const u8 = null, source_hash: ?[]const u8 = null, commit: ?[]const u8 = null };

const probe_command = paths.remote_ec ++ " --version --json; r=$(cat " ++ paths.remote_saved_repo ++ " 2>/dev/null) && git -C \"$r\" rev-parse HEAD 2>/dev/null";
const sync_command = "exec \"${SHELL:-/bin/sh}\" -lc '" ++ paths.remote_ec ++ " sync --skip-packages'";

pub fn status(c: *C) !core.Outcome {
    const fleet = try survey(c);
    return c.resultData("status", try report(c, fleet.machines, fleet.release), fleet);
}
// Syncs every reachable machine that is behind, one at a time.
pub fn syncAll(c: *C) !core.Outcome {
    const fleet = try survey(c);
    var failed: usize = 0;
    var synced: usize = 0;
    for (fleet.machines) |*m| {
        if (m.state != .behind) continue;
        try c.log("\n== {s} ==", .{m.name});
        const ok = if (m.here) try stream(c, &.{ try std.process.executablePathAlloc(c.io, c.a), "sync", "--skip-packages" }, 900) else try stream(c, try host.sshArgv(c, m.host, false, sync_command), 900);
        // Report what the machine runs now, not what the sync claimed.
        m.* = .{ .name = m.name, .host = m.host, .os = m.os, .here = m.here, .online = m.online };
        try probe(c, m, fleet.release);
        if (!ok) {
            failed += 1;
            try c.log("ec sync failed on {s}.", .{m.name});
        } else if (m.state != .current) {
            // A sync that cannot fetch still succeeds, using the local tree.
            failed += 1;
            try c.log("{s} is still behind after ec sync. Check the warnings above; git fetch may lack GitHub credentials there.", .{m.name});
        } else synced += 1;
    }
    const summary = if (synced + failed == 0) "Nothing to sync." else try c.fmt("Synced {d} machine(s); {d} failed.", .{ synced, failed });
    const message = try c.fmt("{s}\n{s}", .{ try report(c, fleet.machines, fleet.release), summary });
    if (failed > 0) return c.failedData("sync --all", .sync_failed, message, fleet);
    return c.resultData("sync --all", message, fleet);
}
// Field names are the JSON result's data.
const Survey = struct { release: Expected, machines: []Machine };
fn survey(c: *C) !Survey {
    // Without a checkout, config commits are listed without comparison.
    c.repo = @import("checkout.zig").resolve(c, null) catch |err| blk: {
        _ = try c.recover(err);
        break :blk "";
    };
    const expected = try latest(c);
    const machines = try discover(c);
    for (machines) |*m| try probe(c, m, expected);
    return .{ .release = expected, .machines = machines };
}

fn latest(c: *C) !Expected {
    var expected: Expected = .{};
    const found = if (release.disabled(c)) null else release.latest(c);
    if (found) |r| {
        expected.version = r.version;
        expected.source_hash = r.source_hash;
    } else try c.log("Could not read the latest ec release; binary versions are listed without comparison.", .{});
    if (c.repo.len > 0) {
        const r = c.capture(&.{ "git", "ls-remote", "origin", "HEAD" }, c.repo, 20) catch null;
        if (r) |result| if (core.success(result.term)) {
            const sha = std.mem.sliceTo(core.trim(result.stdout), '\t');
            if (core.isCommit(sha)) expected.commit = sha;
        };
    }
    return expected;
}

fn discover(c: *C) ![]Machine {
    const r = c.capture(&.{ try host.tailscale(c), "status", "--json" }, null, 15) catch return c.fail("tailscale status timed out.", .{});
    if (!core.success(r.term)) return c.fail("tailscale status failed. Is Tailscale running and logged in?", .{});
    const tailnet = c.parse(r.stdout) catch return c.fail("Could not parse tailscale status.", .{});
    const self = if (tailnet == .object) tailnet.object.get("Self") orelse return c.fail("tailscale status has no Self entry.", .{}) else return c.fail("Could not parse tailscale status.", .{});
    const owner = if (self == .object) self.object.get("UserID") else null;
    var list: std.ArrayList(Machine) = .empty;
    if (machine(self, true)) |m| try list.append(c.a, m);
    var peers: std.ArrayList(Machine) = .empty;
    if (tailnet.object.get("Peer")) |peer_map| if (peer_map == .object) {
        var it = peer_map.object.iterator();
        while (it.next()) |entry| {
            const peer = entry.value_ptr.*;
            if (owner != null and peer == .object) {
                const id = peer.object.get("UserID") orelse continue;
                if (id != .integer or owner.? != .integer or id.integer != owner.?.integer) continue;
            }
            if (machine(peer, false)) |m| try peers.append(c.a, m);
        }
    };
    std.mem.sort(Machine, peers.items, {}, struct {
        fn less(_: void, a: Machine, b: Machine) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    try list.appendSlice(c.a, peers.items);
    return list.items;
}

fn machine(v: core.Value, here: bool) ?Machine {
    const os = core.string(v, "OS") orelse return null;
    if (!eq(u8, os, "macOS") and !eq(u8, os, "linux")) return null;
    const dns = core.string(v, "DNSName") orelse return null;
    const fqdn = std.mem.trimEnd(u8, dns, ".");
    if (!core.validHost(fqdn, false)) return null;
    // The DNS label is ASCII and matches tailscale status; HostName can hold typographic quotes.
    const name = std.mem.sliceTo(fqdn, '.');
    const online = if (v.object.get("Online")) |field| field == .bool and field.bool else false;
    return .{ .name = name, .host = fqdn, .os = os, .here = here, .online = here or online };
}

fn probe(c: *C, m: *Machine, expected: Expected) !void {
    if (m.here) {
        m.version = build_info.version;
        m.source_hash = build_info.source_hash;
        if (c.repo.len > 0) {
            const r = c.capture(&.{ "git", "rev-parse", "HEAD" }, c.repo, 15) catch null;
            if (r) |result| if (core.success(result.term) and core.isCommit(core.trim(result.stdout))) {
                m.commit = core.trim(result.stdout);
            };
        }
        return classify(c, m, expected);
    }
    if (!m.online) {
        m.state = .offline;
        m.detail = "offline in Tailscale";
        return;
    }
    const r = c.capture(try host.sshArgv(c, m.host, false, probe_command), null, 25) catch |err| {
        m.state = .@"unreachable";
        m.detail = if (err == error.Timeout) "SSH timed out" else try c.fmt("Cannot run ssh: {s}", .{@errorName(err)});
        return;
    };
    if (r.term == .exited and r.term.exited == host.ssh_failed) {
        m.state = .@"unreachable";
        const line = std.mem.sliceTo(core.trim(r.stderr), '\n');
        m.detail = if (std.mem.indexOf(u8, line, "Connection refused") != null)
            "SSH refused. Turn on Remote Login on this machine."
        else if (std.mem.indexOf(u8, line, "Host key verification failed") != null)
            try c.fmt("Unknown SSH host key. Run ssh {s} once to confirm it.", .{m.host})
        else if (std.mem.indexOf(u8, line, "Permission denied") != null)
            "SSH key not accepted. Add this machine's key to its authorized_keys."
        else
            try c.fmt("SSH failed: {s}", .{line});
        return;
    }
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    var found = false;
    while (lines.next()) |raw| {
        const line = core.trim(raw);
        if (core.isCommit(line)) m.commit = line;
        if (line.len == 0 or line[0] != '{') continue;
        const parsed = c.parse(line) catch continue;
        found = true;
        const data = if (parsed == .object) parsed.object.get("data") orelse .null else .null;
        m.version = core.string(data, "version");
        m.source_hash = core.string(data, "source_hash");
        if (m.version == null) if (core.string(parsed, "message")) |message| {
            m.version = build_info.parseVersion(message);
        };
    }
    if (!found) {
        m.state = .missing;
        m.detail = "ec is not installed. Run the ec installer there, then ec sync.";
        return;
    }
    return classify(c, m, expected);
}

fn classify(c: *C, m: *Machine, expected: Expected) !void {
    const binary = if (m.source_hash) |hash| try build_info.describe(c.a, m.version orelse "?", hash) else try c.fmt("ec {s}, built before source hashes", .{m.version orelse "?"});
    const config = if (m.commit) |commit| try c.fmt("config {s}", .{build_info.short(commit)}) else "config unknown";
    m.detail = try c.fmt("{s}, {s}", .{ binary, config });
    const stale_binary = m.source_hash == null or (expected.source_hash != null and !eq(u8, m.source_hash.?, expected.source_hash.?));
    const stale_config = expected.commit != null and (m.commit == null or !eq(u8, m.commit.?, expected.commit.?));
    m.state = if (stale_binary or stale_config) .behind else .current;
}

fn report(c: *C, machines: []const Machine, expected: Expected) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    const latest_release = if (expected.source_hash) |hash| try c.fmt("{s} ({s})", .{ expected.version orelse "?", build_info.short(hash) }) else "unknown";
    const main = if (expected.commit) |commit| build_info.short(commit) else "unknown";
    try text.appendSlice(c.a, try c.fmt("Latest release: {s}. Config main: {s}.\n\n", .{ latest_release, main }));
    var width: usize = 0;
    for (machines) |m| width = @max(width, m.name.len + if (m.here) " (here)".len else 0);
    var current: usize = 0;
    for (machines) |m| {
        if (m.state == .current) current += 1;
        const label = if (m.here) try c.fmt("{s} (here)", .{m.name}) else m.name;
        try text.appendSlice(c.a, label);
        try text.appendNTimes(c.a, ' ', width - label.len + 2);
        try text.appendSlice(c.a, try c.fmt("{s: <12} {s}\n", .{ @tagName(m.state), m.detail }));
    }
    try text.appendSlice(c.a, try c.fmt("\n{d} of {d} machines current.", .{ current, machines.len }));
    for (machines) |m| if (m.state == .behind) {
        try text.appendSlice(c.a, " Run ec sync --all to update the reachable ones.");
        break;
    };
    return text.items;
}

fn stream(c: *C, args: []const []const u8, seconds: i64) !bool {
    return core.bounded(c, streamInner, .{ c, args }, seconds) catch |err| {
        if (err != error.Timeout) return err;
        try c.log("Timed out after {d}s.", .{seconds});
        return false;
    };
}
fn streamInner(c: *C, args: []const []const u8) anyerror!bool {
    var p = try std.process.spawn(c.io, .{ .argv = args, .environ_map = c.env, .stdin = .ignore, .stdout = .{ .file = c.stderr }, .stderr = .{ .file = c.stderr } });
    defer p.kill(c.io);
    return core.success(try p.wait(c.io));
}

test "classify compares binary and config against the latest release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    var c: C = .{ .a = arena.allocator(), .io = std.testing.io, .env = &env, .home = "/unused" };
    const hash = "f" ** 64;
    const commit = "a" ** 40;
    const expected: Expected = .{ .version = "0.0.2", .source_hash = hash, .commit = commit };
    var current: Machine = .{ .name = "m", .host = "m.test", .os = "linux", .version = "0.0.2", .source_hash = hash, .commit = commit };
    try classify(&c, &current, expected);
    try std.testing.expectEqual(State.current, current.state);
    var old: Machine = .{ .name = "m", .host = "m.test", .os = "linux", .version = "0.1.0", .commit = commit };
    try classify(&c, &old, expected);
    try std.testing.expectEqual(State.behind, old.state);
    var stale: Machine = .{ .name = "m", .host = "m.test", .os = "linux", .version = "0.0.2", .source_hash = hash, .commit = "b" ** 40 };
    try classify(&c, &stale, expected);
    try std.testing.expectEqual(State.behind, stale.state);
}
