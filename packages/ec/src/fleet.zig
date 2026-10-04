const std = @import("std");
const core = @import("core.zig");
const C = core.Context;
const O = @import("options.zig").Options;
const eq = core.eql;

pub const Machine = struct {
    name: []const u8,
    host: []const u8,
    os: []const u8,
    here: bool = false,
    online: bool = true,
    state: []const u8 = "unknown",
    version: ?[]const u8 = null,
    source_hash: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    detail: []const u8 = "",
};
const Expected = struct { version: ?[]const u8 = null, source_hash: ?[]const u8 = null, commit: ?[]const u8 = null };

const probe_command = "\"$HOME/.local/bin/ec\" --version --json; r=$(cat \"$HOME/.config/ender-chest/repo\" 2>/dev/null) && git -C \"$r\" rev-parse HEAD 2>/dev/null";
const sync_command = "exec \"${SHELL:-/bin/sh}\" -lc '\"$HOME/.local/bin/ec\" sync --skip-packages'";

pub fn run(c: *C, o: O) !bool {
    @import("sync.zig").resolveRepo(c, o) catch |err| {
        if (err != error.Reported) return err;
        c.message = null;
        c.repo = "";
    };
    const expected = try latest(c);
    const machines = try discover(c);
    for (machines) |*m| try probe(c, m, expected);
    if (o.action == .sync) {
        var failed: usize = 0;
        var synced: usize = 0;
        for (machines) |*m| {
            if (!eq(u8, m.state, "behind")) continue;
            try c.log("\n== {s} ==", .{m.name});
            const ok = if (m.here) try stream(c, &.{ try std.process.executablePathAlloc(c.io, c.a), "sync", "--skip-packages" }, 900) else try stream(c, &.{ "ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", m.host, sync_command }, 900);
            // Report what the machine runs now, not what the sync claimed.
            m.* = .{ .name = m.name, .host = m.host, .os = m.os, .here = m.here };
            try probe(c, m, expected);
            if (!ok) {
                failed += 1;
                try c.log("ec sync failed on {s}.", .{m.name});
            } else if (!eq(u8, m.state, "current")) {
                // A sync that cannot fetch still succeeds, using the local tree.
                failed += 1;
                try c.log("{s} is still behind after ec sync. Check the warnings above; git fetch may lack GitHub credentials there.", .{m.name});
            } else synced += 1;
        }
        const text = try report(c, machines, expected);
        if (failed > 0) c.error_code = "sync_failed";
        const summary = if (synced + failed == 0) "Nothing to sync." else try c.fmt("Synced {d} machine(s); {d} failed.", .{ synced, failed });
        try c.resultData("fleet sync", failed == 0, try c.fmt("{s}\n{s}", .{ text, summary }), .{ .release = expected, .machines = machines });
        return failed == 0;
    }
    try c.resultData("fleet status", true, try report(c, machines, expected), .{ .release = expected, .machines = machines });
    return true;
}

fn latest(c: *C) !Expected {
    var expected: Expected = .{};
    if (@import("update.zig").latest(c)) |release| {
        expected.version = release.version;
        expected.source_hash = release.hash;
    } else try c.log("Could not read the latest ec release; binary versions are listed without comparison.", .{});
    if (c.repo.len > 0) {
        const r = c.capture(&.{ "git", "ls-remote", "origin", "HEAD" }, c.repo, 20) catch null;
        if (r) |result| if (core.success(result.term)) {
            const sha = std.mem.sliceTo(core.trim(result.stdout), '\t');
            if (isCommit(sha)) expected.commit = sha;
        };
    }
    return expected;
}

fn tailscale(c: *C) ![]const u8 {
    if (c.commandExists("tailscale")) return "tailscale";
    const app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
    if (c.exists(app)) return app;
    return c.fail("Cannot find the Tailscale CLI. Install Tailscale or add tailscale to PATH.", .{});
}

// Lists this account's macOS and Linux machines on the tailnet, this one first.
fn discover(c: *C) ![]Machine {
    const r = c.capture(&.{ try tailscale(c), "status", "--json" }, null, 15) catch return c.fail("tailscale status timed out.", .{});
    if (!core.success(r.term)) return c.fail("tailscale status failed. Is Tailscale running and logged in?", .{});
    const status = c.parse(r.stdout) catch return c.fail("Could not parse tailscale status.", .{});
    const self = if (status == .object) status.object.get("Self") orelse return c.fail("tailscale status has no Self entry.", .{}) else return c.fail("Could not parse tailscale status.", .{});
    const owner = if (self == .object) self.object.get("UserID") else null;
    var list: std.ArrayList(Machine) = .empty;
    if (machine(self, true)) |m| try list.append(c.a, m);
    var peers: std.ArrayList(Machine) = .empty;
    if (status.object.get("Peer")) |peer_map| if (peer_map == .object) {
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
    const host = std.mem.trimEnd(u8, dns, ".");
    if (!@import("desktop.zig").validHost(host, false)) return null;
    // The DNS label is ASCII and matches tailscale status; HostName can hold typographic quotes.
    const name = std.mem.sliceTo(host, '.');
    const online = if (v.object.get("Online")) |field| field == .bool and field.bool else false;
    return .{ .name = name, .host = host, .os = os, .here = here, .online = here or online };
}

fn probe(c: *C, m: *Machine, expected: Expected) !void {
    if (m.here) {
        m.version = @import("build_options").version;
        m.source_hash = @import("build_options").source_hash;
        if (c.repo.len > 0) {
            const r = c.capture(&.{ "git", "rev-parse", "HEAD" }, c.repo, 15) catch null;
            if (r) |result| if (core.success(result.term) and isCommit(core.trim(result.stdout))) {
                m.commit = core.trim(result.stdout);
            };
        }
        return classify(c, m, expected);
    }
    if (!m.online) {
        m.state = "offline";
        m.detail = "offline in Tailscale";
        return;
    }
    const r = c.capture(&.{ "ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", m.host, probe_command }, null, 25) catch {
        m.state = "unreachable";
        m.detail = "SSH timed out";
        return;
    };
    if (r.term == .exited and r.term.exited == 255) {
        m.state = "unreachable";
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
        if (isCommit(line)) m.commit = line;
        if (line.len == 0 or line[0] != '{') continue;
        const parsed = c.parse(line) catch continue;
        found = true;
        const data = if (parsed == .object) parsed.object.get("data") orelse .null else .null;
        m.version = core.string(data, "version");
        m.source_hash = core.string(data, "source_hash");
        if (m.version == null) if (core.string(parsed, "message")) |message| {
            if (std.mem.startsWith(u8, message, "ec ")) m.version = message[3..];
        };
    }
    if (!found) {
        m.state = "missing";
        m.detail = "ec is not installed. Clone the config repo there and run ./ec sync.";
        return;
    }
    return classify(c, m, expected);
}

fn classify(c: *C, m: *Machine, expected: Expected) !void {
    const binary = if (m.source_hash) |hash| try c.fmt("ec {s} ({s})", .{ m.version orelse "?", hash[0..@min(7, hash.len)] }) else try c.fmt("ec {s}, built before source hashes", .{m.version orelse "?"});
    const config = if (m.commit) |commit| try c.fmt("config {s}", .{commit[0..7]}) else "config unknown";
    m.detail = try c.fmt("{s}, {s}", .{ binary, config });
    const stale_binary = m.source_hash == null or (expected.source_hash != null and !eq(u8, m.source_hash.?, expected.source_hash.?));
    const stale_config = expected.commit != null and (m.commit == null or !eq(u8, m.commit.?, expected.commit.?));
    m.state = if (stale_binary or stale_config) "behind" else "current";
}

fn report(c: *C, machines: []const Machine, expected: Expected) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    const release = if (expected.source_hash) |hash| try c.fmt("{s} ({s})", .{ expected.version orelse "?", hash[0..7] }) else "unknown";
    const main = if (expected.commit) |commit| commit[0..7] else "unknown";
    try text.appendSlice(c.a, try c.fmt("Latest release: {s}. Config main: {s}.\n\n", .{ release, main }));
    var width: usize = 0;
    for (machines) |m| width = @max(width, m.name.len + if (m.here) " (here)".len else 0);
    var current: usize = 0;
    for (machines) |m| {
        if (eq(u8, m.state, "current")) current += 1;
        const label = if (m.here) try c.fmt("{s} (here)", .{m.name}) else m.name;
        try text.appendSlice(c.a, label);
        try text.appendNTimes(c.a, ' ', width - label.len + 2);
        try text.appendSlice(c.a, try c.fmt("{s: <12} {s}\n", .{ m.state, m.detail }));
    }
    try text.appendSlice(c.a, try c.fmt("\n{d} of {d} machines current.", .{ current, machines.len }));
    for (machines) |m| if (eq(u8, m.state, "behind")) {
        try text.appendSlice(c.a, " Run ec fleet sync to update the reachable ones.");
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

fn isCommit(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
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
    try std.testing.expectEqualStrings("current", current.state);
    var old: Machine = .{ .name = "m", .host = "m.test", .os = "linux", .version = "0.1.0", .commit = commit };
    try classify(&c, &old, expected);
    try std.testing.expectEqualStrings("behind", old.state);
    var stale: Machine = .{ .name = "m", .host = "m.test", .os = "linux", .version = "0.0.2", .source_hash = hash, .commit = "b" ** 40 };
    try classify(&c, &stale, expected);
    try std.testing.expectEqualStrings("behind", stale.state);
}
