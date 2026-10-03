const std = @import("std");
const core = @import("core.zig");
const C = core.Context;
const O = @import("options.zig").Options;
const validHost = @import("desktop.zig").validHost;

const credentials = @import("credentials.zig");

const label = "io.cliproxyapi";
const Proxy = struct { base: []const u8, key: []const u8 };
const Response = struct { status: u16, body: []const u8 };

fn load(c: *C, need_key: bool) !Proxy {
    const file = try c.path(&.{ c.home, credentials.endpoint_path });
    const override = c.env.get("CLIPROXY_BASE_URL") orelse "";
    const base = if (override.len > 0) std.mem.trimEnd(u8, override, "/") else try credentials.endpoint(c, file);
    if (!credentials.validBase(base)) return c.fail("Invalid proxy endpoint. Use an HTTP or HTTPS URL without credentials, query parameters, or /v1.", .{});
    const key = if (need_key) try credentials.loadKey(c) orelse return c.failCode("interaction_required", "No local proxy token. Run ec cliproxy setup on this device.", .{}) else "";
    return .{ .base = base, .key = key };
}

fn setup(c: *C, o: O) !void {
    if (o.json and !o.key_stdin) return c.failCode("interaction_required", "Run ec cliproxy setup in a terminal, or supply --key-stdin.", .{});
    const file = try c.path(&.{ c.home, credentials.endpoint_path });
    const base = if (o.url) |url| std.mem.trimEnd(u8, url, "/") else try credentials.endpoint(c, file);
    if (!credentials.validBase(base)) return c.fail("Invalid proxy endpoint. Use an HTTP or HTTPS URL without credentials, query parameters, or /v1.", .{});
    const input = if (o.key_stdin) blk: {
        var buffer: [4097]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(c.io, &buffer);
        break :blk reader.interface.allocRemaining(c.a, .limited(4097)) catch return c.fail("Cannot read proxy token from stdin.", .{});
    } else blk: {
        const script =
            \\set -eu
            \\exec 3<>/dev/tty
            \\saved=$(stty -g <&3)
            \\trap 'stty "$saved" <&3; printf "\n" >&3' EXIT
            \\trap 'exit 1' HUP INT TERM
            \\stty -echo <&3
            \\printf 'Proxy token: ' >&3
            \\IFS= read -r token <&3
            \\printf '%s' "$token"
        ;
        const r = try std.process.run(c.a, c.io, .{ .argv = &.{ "/bin/sh", "-c", script }, .environ_map = c.env, .stdout_limit = .limited(4097), .stderr_limit = .limited(4096) });
        if (!core.success(r.term)) return c.failCode("interaction_required", "Could not read a token. Run ec cliproxy setup in a terminal or use --key-stdin.", .{});
        break :blk r.stdout;
    };
    defer @memset(input, 0);
    const token = std.mem.trimEnd(u8, input, "\r\n");
    try credentials.save(c, token);
    var config = c.object();
    try config.object.put(c.a, "baseURL", .{ .string = base });
    try c.writeJson(file, config, 0o600);
    try c.result("cliproxy setup", true, "Saved proxy credentials on this device. Run ec sync to update agent settings.");
}

pub fn run(c: *C, o: O) !bool {
    if (o.action == .setup) {
        try setup(c, o);
        return true;
    }
    // A read-only URL query does not migrate credentials or need a token.
    if (o.action != .url) try credentials.migrate(c);
    const proxy = try load(c, o.action != .url);
    switch (o.action) {
        .url => {
            const url = try c.fmt("{s}/v1", .{proxy.base});
            try c.resultData("cliproxy url", true, url, .{ .url = url });
        },
        .models => try models(c, proxy),
        .restart => try restart(c, proxy),
        .run => {
            try c.env.put("OPENAI_BASE_URL", try c.fmt("{s}/v1", .{proxy.base}));
            try c.env.put("OPENAI_API_KEY", proxy.key);
            const err = std.process.replace(c.io, .{ .argv = o.rest, .environ_map = c.env });
            return c.fail("Cannot run {s}: {s}.", .{ o.rest[0], @errorName(err) });
        },
        else => unreachable,
    }
    return true;
}
fn models(c: *C, proxy: Proxy) !void {
    const r = try get(c, proxy, proxy.base) orelse return c.failCode("unreachable", "Cannot reach CLIProxyAPI at {s}. Check Tailscale, or run ec cliproxy restart.", .{proxy.base});
    if (r.status == 401) return c.fail("CLIProxyAPI at {s} rejected the client key. Run ec cliproxy setup to replace it, then ec sync.", .{proxy.base});
    if (r.status != 200) return c.fail("CLIProxyAPI at {s} returned HTTP {d}.", .{ proxy.base, r.status });
    const body = c.parse(r.body) catch return c.fail("CLIProxyAPI at {s} returned a model list that is not JSON.", .{proxy.base});
    var ids: std.ArrayList([]const u8) = .empty;
    for (core.array(body, "data")) |entry| if (core.string(entry, "id")) |id| try ids.append(c.a, id);
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    try c.resultData("cliproxy models", true, try std.mem.join(c.a, "\n", ids.items), .{ .models = ids.items });
}
// launchd restarts the agent at once, but the proxy needs a moment before it answers.
fn restart(c: *C, proxy: Proxy) !void {
    const plist = try c.path(&.{ c.home, "Library/LaunchAgents/" ++ label ++ ".plist" });
    if (c.exists(plist)) {
        const domain = try c.fmt("gui/{d}", .{std.c.getuid()});
        const kicked = try c.capture(&.{ "launchctl", "kickstart", "-k", try c.fmt("{s}/" ++ label, .{domain}) }, null, 30);
        // kickstart fails when the agent is not loaded; bootstrap starts it because of RunAtLoad.
        if (!core.success(kicked.term)) {
            const loaded = try c.capture(&.{ "launchctl", "bootstrap", domain, plist }, null, 30);
            if (!core.success(loaded.term)) {
                try c.stderr.writeStreamingAll(c.io, loaded.stderr);
                return c.fail("launchctl could not start {s} from {s}.", .{ label, plist });
            }
        }
        const local = c.env.get("CLIPROXY_LOCAL_URL") orelse "http://127.0.0.1:8317";
        try waitFor(c, proxy, local);
        try c.result("cliproxy restart", true, "CLIProxyAPI restarted.");
        return;
    }
    const after_scheme = proxy.base[std.mem.indexOf(u8, proxy.base, "://").? + 3 ..];
    const host = after_scheme[0 .. std.mem.indexOfAny(u8, after_scheme, ":/") orelse after_scheme.len];
    if (!validHost(host, false)) return c.fail("Invalid CLIProxyAPI host {s}.", .{host});
    try c.log("Restarting CLIProxyAPI on {s}...", .{host});
    const r = c.capture(&.{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1", host, "\"$HOME/.local/bin/ec\" cliproxy restart" }, null, 90) catch |err| {
        if (err == error.Timeout) return c.fail("Restarting CLIProxyAPI on {s} timed out.", .{host});
        return err;
    };
    if (r.stderr.len > 0) try c.stderr.writeStreamingAll(c.io, r.stderr);
    if (r.term == .exited and r.term.exited == 255) return c.fail("Cannot SSH to {s}. This machine's SSH key must be allowed on the proxy host.", .{host});
    if (r.term == .exited and r.term.exited == 2) return c.fail("The ec on {s} is too old to restart CLIProxyAPI. Run ec fleet sync.", .{host});
    if (!core.success(r.term)) return c.fail("Restarting CLIProxyAPI on {s} failed.", .{host});
    try waitFor(c, proxy, proxy.base);
    try c.result("cliproxy restart", true, try c.fmt("CLIProxyAPI restarted on {s} and answers at {s}.", .{ host, proxy.base }));
}
fn waitFor(c: *C, proxy: Proxy, url: []const u8) !void {
    const configured = c.env.get("CLIPROXY_RESTART_TIMEOUT") orelse "30";
    const seconds = std.fmt.parseInt(i64, configured, 10) catch return c.fail("Invalid CLIPROXY_RESTART_TIMEOUT. Use whole seconds.", .{});
    const started = std.Io.Clock.Timestamp.now(c.io, .awake).raw.toSeconds();
    while (true) {
        if (try get(c, proxy, url)) |r| if (r.status == 200) return;
        if (std.Io.Clock.Timestamp.now(c.io, .awake).raw.toSeconds() - started >= seconds) return c.failCode("unreachable", "CLIProxyAPI did not answer at {s} within {d}s after restarting. Check ~/.local/share/cliproxyapi/logs on the host.", .{ url, seconds });
        try std.Io.sleep(c.io, .fromSeconds(1), .awake);
    }
}
// Returns null when curl cannot connect or times out.
fn get(c: *C, proxy: Proxy, url: []const u8) !?Response {
    const args = [_][]const u8{ "curl", "--config", "-", "--silent", "--connect-timeout", "10", "--max-time", "30", "--write-out", "\n%{http_code}", try c.fmt("{s}/v1/models", .{url}) };
    // Send the key on stdin so it never appears in curl's arguments.
    const header = try c.fmt("header = \"Authorization: Bearer {s}\"\n", .{proxy.key});
    const r = core.bounded(c, curl, .{ c, &args, header }, 40) catch |err| {
        if (err == error.Timeout) return null;
        return err;
    };
    if (!core.success(r.term)) return null;
    const split = std.mem.lastIndexOfScalar(u8, r.stdout, '\n') orelse return null;
    const status = std.fmt.parseInt(u16, r.stdout[split + 1 ..], 10) catch return null;
    return .{ .status = status, .body = r.stdout[0..split] };
}
fn curl(c: *C, args: []const []const u8, input: []const u8) anyerror!std.process.RunResult {
    var p = try std.process.spawn(c.io, .{ .argv = args, .environ_map = c.env, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    defer p.kill(c.io);
    try p.stdin.?.writeStreamingAll(c.io, input);
    p.stdin.?.close(c.io);
    p.stdin = null;
    var buffer: [4096]u8 = undefined;
    var reader = p.stdout.?.readerStreaming(c.io, &buffer);
    const out = try reader.interface.allocRemaining(c.a, .limited(8 * 1024 * 1024));
    return .{ .term = try p.wait(c.io), .stdout = out, .stderr = &.{} };
}
