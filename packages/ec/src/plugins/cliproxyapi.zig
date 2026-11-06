// Client side of a shared CLIProxyAPI server. The url and key come from plugin settings.
const std = @import("std");
const core = @import("../core.zig");
const runtime = @import("runtime.zig");
const C = core.Context;
const Call = runtime.Call;
const eq = core.eql;

const label = "io.cliproxyapi";
const Proxy = struct { base: []const u8, key: []const u8 };
const Response = struct { status: u16, body: []const u8 };

pub fn validBase(base: []const u8) bool {
    const start: usize = if (std.mem.startsWith(u8, base, "https://")) 8 else if (std.mem.startsWith(u8, base, "http://")) 7 else return false;
    if (base.len <= start or base[start] == '/' or base[start] == '-') return false;
    if (std.mem.indexOfAny(u8, base, "@?#\\\" \t\r\n") != null) return false;
    for (base) |ch| if (ch < 32 or ch == 127) return false;
    return !std.mem.endsWith(u8, base, "/v1");
}
// The key goes into a curl config line, so it may not hold quotes, backslashes, or spaces.
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 4096) return false;
    for (key) |ch| if (ch <= 32 or ch >= 127 or ch == '"' or ch == '\\') return false;
    return true;
}

fn load(c: *C, call: Call, need_key: bool) !Proxy {
    const base = std.mem.trimEnd(u8, call.setting("url") orelse "", "/");
    if (!validBase(base)) return c.fail("Invalid url. Use an HTTP or HTTPS URL without credentials, query parameters, or /v1.", .{});
    if (!need_key) return .{ .base = base, .key = "" };
    const key = call.setting("key") orelse return c.failCode("interaction_required", "No CLIProxyAPI key. Set it with key = {{ secret = \"cliproxyapi\" }} under [plugins.cliproxyapi], then run ec secret set cliproxyapi.", .{});
    if (!validKey(key)) return c.fail("Invalid CLIProxyAPI key. Replace it with ec secret set cliproxyapi.", .{});
    return .{ .base = base, .key = key };
}

pub fn run(c: *C, call: Call) !bool {
    if (eq(u8, call.command, "url")) {
        const proxy = try load(c, call, false);
        const url = try c.fmt("{s}/v1", .{proxy.base});
        try c.resultData("cliproxyapi url", true, url, .{ .url = url });
        return true;
    }
    if (eq(u8, call.command, "run")) {
        if (call.args.len == 0) return c.failCode("usage_error", "ec cliproxyapi run needs a command, as in ec cliproxyapi run codex.", .{});
        const proxy = try load(c, call, true);
        try c.env.put("OPENAI_BASE_URL", try c.fmt("{s}/v1", .{proxy.base}));
        try c.env.put("OPENAI_API_KEY", proxy.key);
        // The command gets the key it needs, not every plugin setting.
        _ = c.env.swapRemove("EC_PLUGIN_SETTINGS");
        const err = std.process.replace(c.io, .{ .argv = call.args, .environ_map = c.env });
        return c.fail("Cannot run {s}: {s}.", .{ call.args[0], @errorName(err) });
    }
    const proxy = try load(c, call, true);
    if (eq(u8, call.command, "models")) try models(c, proxy) else if (eq(u8, call.command, "restart")) try restart(c, call, proxy) else return c.fail("Unknown cliproxyapi command {s}.", .{call.command});
    return true;
}
fn models(c: *C, proxy: Proxy) !void {
    const r = try get(c, proxy, proxy.base) orelse return c.failCode("unreachable", "Cannot reach CLIProxyAPI at {s}. Check Tailscale, or run ec cliproxyapi restart.", .{proxy.base});
    if (r.status == 401) return c.fail("CLIProxyAPI at {s} rejected the client key. Replace it with ec secret set cliproxyapi, then run ec sync.", .{proxy.base});
    if (r.status != 200) return c.fail("CLIProxyAPI at {s} returned HTTP {d}.", .{ proxy.base, r.status });
    const body = c.parse(r.body) catch return c.fail("CLIProxyAPI at {s} returned a model list that is not JSON.", .{proxy.base});
    var ids: std.ArrayList([]const u8) = .empty;
    for (core.array(body, "data")) |entry| if (core.string(entry, "id")) |id| try ids.append(c.a, id);
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    try c.resultData("cliproxyapi models", true, try std.mem.join(c.a, "\n", ids.items), .{ .models = ids.items });
}
// The SSH host for restart: the host setting, else the url's hostname.
fn sshHost(c: *C, call: Call, base: []const u8) ![]const u8 {
    if (call.setting("host")) |h| {
        if (!core.validHost(h, true)) return c.fail("Invalid host {s}. Use HOST or USER@HOST.", .{h});
        return h;
    }
    const after_scheme = base[std.mem.indexOf(u8, base, "://").? + 3 ..];
    const h = after_scheme[0 .. std.mem.indexOfAny(u8, after_scheme, ":/") orelse after_scheme.len];
    if (!core.validHost(h, false)) return c.fail("Invalid CLIProxyAPI host {s}. Set host under [plugins.cliproxyapi].", .{h});
    return h;
}
// launchd restarts the agent at once, but the proxy needs a moment before it answers.
fn restart(c: *C, call: Call, proxy: Proxy) !void {
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
        try c.result("cliproxyapi restart", true, "CLIProxyAPI restarted.");
        return;
    }
    const host = try sshHost(c, call, proxy.base);
    try c.log("Restarting CLIProxyAPI on {s}...", .{host});
    const r = c.capture(&.{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1", host, "\"$HOME/.local/bin/ec\" cliproxyapi restart" }, null, 90) catch |err| {
        if (err == error.Timeout) return c.fail("Restarting CLIProxyAPI on {s} timed out.", .{host});
        return err;
    };
    if (r.stderr.len > 0) try c.stderr.writeStreamingAll(c.io, r.stderr);
    if (r.term == .exited and r.term.exited == 255) return c.fail("Cannot SSH to {s}. This machine's SSH key must be allowed on the proxy host.", .{host});
    if (r.term == .exited and r.term.exited == 2) return c.fail("The ec on {s} cannot restart CLIProxyAPI: it is too old or its config does not enable cliproxyapi. Run ec sync --all.", .{host});
    if (!core.success(r.term)) return c.fail("Restarting CLIProxyAPI on {s} failed.", .{host});
    try waitFor(c, proxy, proxy.base);
    try c.result("cliproxyapi restart", true, try c.fmt("CLIProxyAPI restarted on {s} and answers at {s}.", .{ host, proxy.base }));
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
pub fn curl(c: *C, args: []const []const u8, input: []const u8) anyerror!std.process.RunResult {
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

test "reject credentials embedded in endpoint URLs and invalid keys" {
    try std.testing.expect(validBase("https://proxy.example.test:8317"));
    try std.testing.expect(!validBase("https://user:secret@proxy.example.test"));
    try std.testing.expect(!validBase("https://proxy.example.test?token=secret"));
    try std.testing.expect(!validBase("http://proxy.example.test/v1"));
    try std.testing.expect(!validKey("secret\nheader"));
    try std.testing.expect(!validKey("with\"quote"));
    try std.testing.expect(validKey("test-client-key"));
}
