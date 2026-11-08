// Other machines and services: SSH, Tailscale, launchd agents, HTTP, and ping. Used by ec status,
// the release check, and built-in plugins.
const std = @import("std");
const core = @import("core.zig");
const paths = @import("paths.zig");
const C = core.Context;

// ssh's exit status when it cannot connect or authenticate, rather than the remote command's.
pub const ssh_failed: u8 = 255;

pub fn seconds(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.toSeconds();
}

pub fn tailscale(c: *C) ![]const u8 {
    if (c.commandExists("tailscale")) return "tailscale";
    const app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
    if (c.exists(app)) return app;
    return c.fail("Cannot find the Tailscale CLI. Install Tailscale or add tailscale to PATH.", .{});
}
// This machine's Tailscale DNS name without the trailing dot, or null when Tailscale cannot say.
pub fn tailnetName(c: *C) !?[]const u8 {
    const bin = tailscale(c) catch |err| {
        _ = try c.recover(err);
        return null;
    };
    const r = c.capture(&.{ bin, "status", "--json", "--peers=false" }, null, 15) catch return null;
    if (!core.success(r.term)) return null;
    const status = c.parse(r.stdout) catch return null;
    const self = if (status == .object) status.object.get("Self") orelse return null else return null;
    return std.mem.trimEnd(u8, core.string(self, "DNSName") orelse return null, ".");
}

// `interactive` lets SSH ask for a password or a new host key on this terminal.
pub fn sshArgv(c: *C, target: []const u8, interactive: bool, command: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ "ssh", "-T", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1" });
    if (interactive) try argv.appendSlice(c.a, &.{ "-o", "BatchMode=no", "-o", "StrictHostKeyChecking=ask" }) else try argv.appendSlice(c.a, &.{ "-o", "BatchMode=yes" });
    try argv.appendSlice(c.a, &.{ target, command });
    return argv.items;
}
// Runs `ec PLUGIN ARGS` with the ec that ec sync installed on `target`, and returns its stdout.
// Its stderr passes through.
pub fn runEc(c: *C, target: []const u8, plugin: []const u8, args: []const u8, limit: i64) ![]const u8 {
    const remote = try c.fmt("{s} {s} {s}", .{ paths.remote_ec, plugin, args });
    const r = c.capture(try sshArgv(c, target, false, remote), null, limit) catch |err| {
        if (err == error.Timeout) return c.fail("ec {s} {s} on {s} timed out.", .{ plugin, args, target });
        return c.fail("Cannot run ssh: {s}.", .{@errorName(err)});
    };
    if (r.stderr.len > 0) try c.stderr.writeStreamingAll(c.io, r.stderr);
    if (r.term == .exited and r.term.exited == ssh_failed) return c.fail("Cannot SSH to {s}. Allow this machine's SSH key there, and on a Mac turn on Remote Login.", .{target});
    // ec exits 2 for a command it does not know.
    if (r.term == .exited and r.term.exited == 2) return c.fail("The ec on {s} cannot run ec {s} {s}: it is too old or its config does not enable {s}. Run ec sync --all.", .{ target, plugin, args, plugin });
    if (!core.success(r.term)) return c.fail("ec {s} {s} failed on {s}.", .{ plugin, args, target });
    return core.trim(r.stdout);
}

pub fn agentPlist(c: *C, label: []const u8) ![]const u8 {
    return paths.inHome(c, try c.fmt("Library/LaunchAgents/{s}.plist", .{label}));
}
fn guiDomain(c: *C) ![]const u8 {
    return c.fmt("gui/{d}", .{std.c.getuid()});
}
// The agent's RunAtLoad starts it once bootstrap loads it.
pub fn restartAgent(c: *C, label: []const u8) !void {
    const domain = try guiDomain(c);
    const kicked = try c.capture(&.{ "launchctl", "kickstart", "-k", try c.fmt("{s}/{s}", .{ domain, label }) }, null, 30);
    if (!core.success(kicked.term)) try bootstrap(c, domain, label);
}
pub fn reloadAgent(c: *C, label: []const u8) !void {
    const domain = try guiDomain(c);
    _ = try c.capture(&.{ "launchctl", "bootout", try c.fmt("{s}/{s}", .{ domain, label }) }, null, 30);
    try bootstrap(c, domain, label);
}
// bootstrap can fail briefly while launchd finishes a bootout.
fn bootstrap(c: *C, domain: []const u8, label: []const u8) !void {
    const plist = try agentPlist(c, label);
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const r = try c.capture(&.{ "launchctl", "bootstrap", domain, plist }, null, 30);
        if (core.success(r.term)) return;
        if (attempt == 4) {
            try c.stderr.writeStreamingAll(c.io, r.stderr);
            return c.fail("launchctl could not start {s} from {s}.", .{ label, plist });
        }
        try std.Io.sleep(c.io, .fromSeconds(1), .awake);
    }
}

const Response = struct { status: u16, body: []const u8 };
// Null when curl cannot connect or times out.
pub fn get(c: *C, url: []const u8, token: []const u8) !?Response {
    const args = [_][]const u8{ "curl", "--config", "-", "--silent", "--connect-timeout", "10", "--max-time", "30", "--write-out", "\n%{http_code}", url };
    const r = curl(c, &args, try bearer(c, token), 40) catch |err| {
        if (err == error.Timeout) return null;
        return err;
    };
    if (!core.success(r.term)) return null;
    const split = std.mem.lastIndexOfScalar(u8, r.stdout, '\n') orelse return null;
    const status = std.fmt.parseInt(u16, r.stdout[split + 1 ..], 10) catch return null;
    if (status == 0) return null;
    return .{ .status = status, .body = r.stdout[0..split] };
}
// Whether `token` can go in a curl config line: no quotes, backslashes, or whitespace.
pub fn safeToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |ch| if (ch <= ' ' or ch == '"' or ch == '\\') return false;
    return true;
}
// A curl config line that sends `token`.
pub fn bearer(c: *C, token: []const u8) ![]const u8 {
    if (!safeToken(token)) return error.UnsafeToken;
    return c.fmt("header = \"Authorization: Bearer {s}\"\n", .{token});
}
// Runs curl with `config` on stdin, so headers such as a token never appear in its arguments,
// and returns its stdout.
pub fn curl(c: *C, args: []const []const u8, config: []const u8, limit: i64) !std.process.RunResult {
    return core.bounded(c, curlInner, .{ c, args, config }, limit);
}
fn curlInner(c: *C, args: []const []const u8, config: []const u8) anyerror!std.process.RunResult {
    var p = try std.process.spawn(c.io, .{ .argv = args, .environ_map = c.env, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    defer p.kill(c.io);
    try p.stdin.?.writeStreamingAll(c.io, config);
    p.stdin.?.close(c.io);
    p.stdin = null;
    var buffer: [4096]u8 = undefined;
    var reader = p.stdout.?.readerStreaming(c.io, &buffer);
    const out = try reader.interface.allocRemaining(c.a, .limited(32 * 1024 * 1024));
    return .{ .term = try p.wait(c.io), .stdout = out, .stderr = &.{} };
}
pub fn waitOk(c: *C, url: []const u8, token: []const u8, limit: i64) !bool {
    const started = seconds(c.io);
    while (true) {
        if (try get(c, url, token)) |r| if (r.status == 200) return true;
        if (seconds(c.io) - started >= limit) return false;
        try std.Io.sleep(c.io, .fromSeconds(1), .awake);
    }
}
pub fn envSeconds(c: *C, name: []const u8, default: i64) !i64 {
    const text = c.env.get(name) orelse return default;
    return std.fmt.parseInt(i64, text, 10) catch c.fail("Invalid {s}. Use whole seconds.", .{name});
}

pub fn reachable(c: *C, host: []const u8) !bool {
    const r = c.capture(&.{ "ping", "-c", "1", host }, null, 5) catch |err| {
        if (err != error.Timeout) return err;
        return false;
    };
    return core.success(r.term);
}
pub fn waitReachable(c: *C, host: []const u8, up: bool, limit: i64) !bool {
    const started = seconds(c.io);
    while (true) {
        if (try reachable(c, host) == up) return true;
        if (seconds(c.io) - started >= limit) return false;
        try std.Io.sleep(c.io, .fromSeconds(2), .awake);
    }
}
