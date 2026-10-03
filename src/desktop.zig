const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const C = core.Context;
const O = @import("options.zig").Options;
const eq = core.eql;

pub fn validHost(s: []const u8, user: bool) bool {
    var parts = std.mem.splitScalar(u8, s, '@');
    const first = parts.next().?;
    if (parts.next()) |host| {
        if (!user or parts.next() != null or first.len == 0 or (!std.ascii.isAlphanumeric(first[0]) and first[0] != '_')) return false;
        for (first) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.' and ch != '-') return false;
        return validHost(host, false);
    }
    if (s.len == 0 or !std.ascii.isAlphanumeric(s[0])) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.' and ch != '-') return false;
    return true;
}
pub fn magicPacket(mac: []const u8) ![102]u8 {
    if (mac.len != 17) return error.InvalidMac;
    var bytes: [6]u8 = undefined;
    for (0..6) |i| {
        if (i < 5 and mac[i * 3 + 2] != ':') return error.InvalidMac;
        if (!std.ascii.isHex(mac[i * 3]) or !std.ascii.isHex(mac[i * 3 + 1])) return error.InvalidMac;
        bytes[i] = std.fmt.parseInt(u8, mac[i * 3 ..][0..2], 16) catch return error.InvalidMac;
    }
    var packet: [102]u8 = undefined;
    @memset(packet[0..6], 0xff);
    for (0..16) |i| @memcpy(packet[6 + i * 6 ..][0..6], &bytes);
    return packet;
}
const Ifaddrs = extern struct {
    next: ?*Ifaddrs,
    name: [*:0]const u8,
    flags: c_uint,
    addr: ?*std.c.sockaddr,
    netmask: ?*std.c.sockaddr,
    broadaddr: ?*std.c.sockaddr,
    data: ?*anyopaque,
};
extern "c" fn getifaddrs(list: *?*Ifaddrs) c_int;
extern "c" fn freeifaddrs(list: ?*Ifaddrs) void;
// An up interface that broadcasts to this address shares the desktop's LAN.
pub fn onLan(broadcast: [4]u8) bool {
    var list: ?*Ifaddrs = null;
    if (getifaddrs(&list) != 0) return false;
    defer freeifaddrs(list);
    var it = list;
    while (it) |entry| : (it = entry.next) {
        const up_broadcast: c_uint = 0x1 | 0x2;
        if (entry.flags & up_broadcast != up_broadcast) continue;
        const sa = entry.broadaddr orelse continue;
        if (sa.family != std.c.AF.INET) continue;
        const in: *const std.c.sockaddr.in = @ptrCast(@alignCast(sa));
        if (eq(u8, std.mem.asBytes(&in.addr), &broadcast)) return true;
    }
    return false;
}
fn nowSeconds(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.toSeconds();
}
fn configHost(c: *C, config: core.Value) ![]const u8 {
    const host = core.string(config, "host") orelse return c.fail("Missing desktop hostname.", .{});
    if (!validHost(host, false)) return c.fail("Invalid desktop hostname.", .{});
    return host;
}
fn sshTarget(c: *C, config: core.Value, comptime purpose: []const u8) ![]const u8 {
    const host = core.string(config, "host") orelse return c.fail(purpose ++ " needs host and sshUser in desktop/config.json.", .{});
    const user = core.string(config, "sshUser") orelse return c.fail(purpose ++ " needs host and sshUser in desktop/config.json.", .{});
    const target = try c.fmt("{s}@{s}", .{ user, host });
    if (!validHost(host, false) or !validHost(target, true)) return c.fail(purpose ++ " needs a valid host and sshUser.", .{});
    return target;
}
fn waitSeconds(c: *C, config: core.Value) !i64 {
    const value: core.Value = config.object.get("waitSeconds") orelse return 180;
    if (value != .integer or value.integer < 1 or value.integer > 3600) return c.fail("Invalid waitSeconds. Use 1 to 3600.", .{});
    return value.integer;
}
fn reachable(c: *C, host: []const u8) !bool {
    const r = c.capture(&.{ "ping", "-c", "1", host }, null, 5) catch |err| {
        if (err != error.Timeout) return err;
        return false;
    };
    return core.success(r.term);
}
fn waitFor(c: *C, host: []const u8, up: bool, seconds: i64) !bool {
    const started = nowSeconds(c.io);
    while (true) {
        if (try reachable(c, host) == up) return true;
        if (nowSeconds(c.io) - started >= seconds) return false;
        try std.Io.sleep(c.io, .fromSeconds(2), .awake);
    }
}
pub fn run(c: *C, o: O) !bool {
    const configured = c.env.get("DESKTOP_CONFIG") orelse "";
    const file = if (configured.len > 0) configured else try c.path(&.{ c.home, ".config/desktop/config.json" });
    const config = c.readJson(file) catch return c.fail("Cannot read desktop settings at {s}. Run ec sync or check DESKTOP_CONFIG.", .{file});
    switch (o.action) {
        .auth => {
            try c.result("desktop auth", true, try authWith(c, config, o, builtin.os.tag, RealRunner{}, 0));
            return true;
        },
        .status => {
            const host = try configHost(c, config);
            const ok = try reachable(c, host);
            if (!ok) c.error_code = "unreachable";
            try c.result("desktop status", ok, if (ok) try c.fmt("Desktop is reachable at {s}.", .{host}) else try c.fmt("Desktop is not reachable at {s}. It may be off, booting, or disconnected from Tailscale.", .{host}));
            return ok;
        },
        .start => return start(c, config, o),
        .stop => return stop(c, config, o),
        else => unreachable,
    }
}
fn start(c: *C, config: core.Value, o: O) !bool {
    const auto_local = !o.local and o.via == null and homeLan(config);
    if (o.no_wait) {
        try c.result("desktop start", true, try c.fmt("{s} Run ec desktop status to check reachability.", .{try wake(c, config, o, auto_local)}));
        return true;
    }
    const host = try configHost(c, config);
    const wait = try waitSeconds(c, config);
    const already = try reachable(c, host);
    if (!already) {
        try c.log("{s} Waiting up to {d}s for {s}...", .{ try wake(c, config, o, auto_local), wait, host });
        // Another network can share the home subnet, so a silent desktop also gets the relay's packet.
        const fallback = @min(20, wait);
        var up = try waitFor(c, host, true, if (auto_local) fallback else wait);
        if (!up and auto_local) {
            try c.log("No answer yet. Trying the relay too, in case this is a different network.", .{});
            if (wake(c, config, o, false)) |sent| try c.log("{s}", .{sent}) else |err| {
                if (err != error.Reported) return err;
                try c.log("{s}", .{c.message orelse "Wake relay failed."});
                c.message = null;
            }
            up = try waitFor(c, host, true, wait - fallback);
        }
        if (!up) return c.failCode("unreachable", "Wake packet sent, but {s} did not respond within {d}s. Check that it is plugged into the home LAN and that wake-on-LAN is enabled.", .{ host, wait });
    }
    const awake = if (already) "Desktop is already awake." else "Desktop is awake.";
    if (o.no_auth or builtin.os.tag != .macos or core.string(config, "sshUser") == null) {
        try c.result("desktop start", true, awake);
        return true;
    }
    try c.log("{s} Unlocking its wallet...", .{awake});
    const unlocked = authWith(c, config, .{ .json = o.json }, builtin.os.tag, RealRunner{}, wait) catch |err| {
        if (err == error.Reported) c.message = try c.fmt("{s} {s} Run ec desktop auth to retry.", .{ awake, c.message orelse "Wallet unlock failed." });
        return err;
    };
    try c.result("desktop start", true, try c.fmt("{s} {s}", .{ awake, unlocked }));
    return true;
}
fn homeLan(config: core.Value) bool {
    const address = core.string(config, "broadcast") orelse return false;
    const ip = std.Io.net.IpAddress.parseIp4(address, 0) catch return false;
    return onLan(ip.ip4.bytes);
}
// Returns what was sent, for the caller to report.
fn wake(c: *C, config: core.Value, o: O, auto_local: bool) ![]const u8 {
    const broadcast = core.string(config, "broadcast");
    if (auto_local) try c.log("On the desktop's network; sending the wake packet directly.", .{});
    if (o.local or auto_local) {
        const mac = core.string(config, "mac") orelse return c.fail("Missing desktop MAC address.", .{});
        const packet = magicPacket(mac) catch return c.fail("Invalid desktop MAC address. Expected six colon-separated hex pairs.", .{});
        const port_value: core.Value = config.object.get("port") orelse .{ .integer = 9 };
        if (port_value != .integer or port_value.integer < 1 or port_value.integer > 65535) return c.fail("Invalid wake port.", .{});
        const dest = std.Io.net.IpAddress.parseIp4(broadcast orelse return c.fail("Missing broadcast address.", .{}), @intCast(port_value.integer)) catch return c.fail("Invalid broadcast address. Expected IPv4.", .{});
        const source: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) };
        const socket = try source.bind(c.io, .{ .mode = .dgram, .protocol = .udp, .allow_broadcast = true });
        defer socket.close(c.io);
        try socket.send(c.io, &dest, &packet);
        return c.fmt("Wake packet sent to {s} via {s}.", .{ mac, broadcast.? });
    }
    const relay = o.via orelse c.env.get("DESKTOP_RELAY") orelse core.string(config, "relay") orelse return c.fail("Missing wake relay.", .{});
    if (!validHost(relay, true)) return c.fail("Invalid wake relay. Use an SSH hostname or USER@HOST.", .{});
    try c.log("Sending wake request through {s}...", .{relay});
    const r = c.capture(&.{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", relay, "\"$HOME/.local/bin/ec\" desktop start --local --no-wait" }, null, 20) catch return c.fail("Wake relay failed. Check SSH access and run ec sync on the relay.", .{});
    if (r.stderr.len > 0) try std.Io.File.stderr().writeStreamingAll(c.io, r.stderr);
    if (r.term == .exited and r.term.exited == 2) return c.fail("The ec on {s} is too old to relay. Run ec sync there, or ec fleet sync from here.", .{relay});
    if (r.term == .exited and r.term.exited == 255) return c.fail("Cannot SSH to the wake relay {s}. If the connection was refused, turn on Remote Login in its System Settings. At home, try ec desktop start --local.", .{relay});
    if (!core.success(r.term)) return c.fail("Wake relay failed. Check SSH access to {s}; at home, try ec desktop start --local.", .{relay});
    return c.fmt("Wake packet sent through {s}.", .{relay});
}
// KDE's own logout path ends the session cleanly and needs no polkit or sudo rule.
const shutdown_command = "echo ready; export DBUS_SESSION_BUS_ADDRESS=\"unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus\"; busctl --user call org.kde.Shutdown /Shutdown org.kde.Shutdown logoutAndShutdown";
fn stop(c: *C, config: core.Value, o: O) !bool {
    const host = try configHost(c, config);
    const target = try sshTarget(c, config, "Desktop stop");
    const wait = try waitSeconds(c, config);
    if (!try reachable(c, host)) {
        try c.result("desktop stop", true, try c.fmt("Desktop is not reachable at {s}. It is likely already off.", .{host}));
        return true;
    }
    try c.log("Asking KDE on {s} to shut down...", .{target});
    const r = c.capture(&.{ "ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", target, shutdown_command }, null, 45) catch |err| switch (err) {
        // The connection can stall while the desktop goes down.
        error.Timeout => null,
        else => return err,
    };
    if (r) |result| {
        if (result.stderr.len > 0) try std.Io.File.stderr().writeStreamingAll(c.io, result.stderr);
        if (std.mem.indexOf(u8, result.stdout, "ready") == null) return c.fail("Cannot SSH to {s}. Check Tailscale SSH access, then retry.", .{target});
        // 255 after "ready" means the connection dropped during shutdown.
        if (!core.success(result.term) and !(result.term == .exited and result.term.exited == 255)) return c.fail("KDE did not accept the shutdown request. The Plasma session may not be running on the desktop.", .{});
    }
    if (o.no_wait) {
        try c.result("desktop stop", true, "Shutdown requested. Run ec desktop status to check reachability.");
        return true;
    }
    try c.log("Shutdown requested. Waiting up to {d}s for {s} to go offline...", .{ wait, host });
    if (!try waitFor(c, host, false, wait)) return c.fail("Shutdown requested, but {s} still responds after {d}s. An app may have blocked logout; check the desktop.", .{ host, wait });
    try c.result("desktop stop", true, "Desktop is off.");
    return true;
}

// Capture only stdout. Secrets never share a diagnostic buffer or become argv/env values.
fn child(c: *C, args: []const []const u8, input: ?[]const u8, interactive: bool, secret: bool, seconds: i64) !std.process.RunResult {
    return core.bounded(c, childInner, .{ c, args, input, interactive, secret, seconds }, seconds);
}
fn childInner(c: *C, args: []const []const u8, input: ?[]const u8, interactive: bool, secret: bool, seconds: i64) anyerror!std.process.RunResult {
    var p = try std.process.spawn(c.io, .{ .argv = args, .environ_map = c.env, .stdin = if (input != null) .pipe else if (interactive) .inherit else .ignore, .stdout = .pipe, .stderr = if (secret) .ignore else .{ .file = c.stderr } });
    defer p.kill(c.io);
    if (input) |data| {
        try p.stdin.?.writeStreamingAll(c.io, data);
        p.stdin.?.close(c.io);
        p.stdin = null;
    }
    var buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(if (secret) std.heap.page_allocator else c.a, c.io, buffer.toStreams(), &.{p.stdout.?});
    defer reader.deinit();
    defer if (secret) std.crypto.secureZero(u8, @constCast(reader.reader(0).buffered()));
    const deadline = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } }).toDeadline(c.io);
    while (reader.fill(if (secret) 8193 else 128, deadline)) |_| {
        if (reader.reader(0).buffered().len > 8192) return error.StreamTooLong;
    } else |err| if (err != error.EndOfStream) return err;
    try reader.checkAnyError();
    return .{ .term = try p.wait(c.io), .stdout = if (secret) try c.a.dupe(u8, reader.reader(0).buffered()) else try reader.toOwnedSlice(0), .stderr = &.{} };
}
pub fn passwordBytes(bytes: []const u8) ![]const u8 {
    const password = if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
    if (password.len == 0 or password.len > 4096 or std.mem.indexOfAny(u8, password, "\n\x00") != null) return error.InvalidPassword;
    return password;
}
const RealRunner = struct {
    fn run(_: @This(), c: *C, args: []const []const u8, input: ?[]const u8, interactive: bool, secret: bool, seconds: i64) !std.process.RunResult {
        return child(c, args, input, interactive, secret, seconds);
    }
};
// wait > 0 retries the first SSH check while a just-booted desktop starts its session.
fn authWith(c: *C, config: core.Value, o: O, platform: std.Target.Os.Tag, runner: anytype, wait: i64) ![]const u8 {
    if (o.json and (o.setup or o.local)) return c.failCode("interaction_required", "Interactive wallet setup cannot use --json. Run ec desktop auth --setup in a terminal first.", .{});
    const target = try sshTarget(c, config, "Desktop auth");
    if (o.local) {
        if (platform != .linux) return c.fail("Local wallet unlock is only available on Linux.", .{});
        const r = try runner.run(c, &.{ "python3", try c.path(&.{ c.home, ".local/lib/desktop/unlock-wallet.py" }), "--prompt" }, null, true, false, 180);
        if (!core.success(r.term)) return c.fail("Wallet unlock failed.", .{});
        return core.trim(r.stdout);
    }
    if (platform != .macos) return c.fail("Remote desktop auth uses macOS Keychain. On Linux use ec desktop auth --local.", .{});
    const security = "/usr/bin/security";
    const service = "ender.desktop.kdewallet";
    if (o.forget) {
        const r = try runner.run(c, &.{ security, "delete-generic-password", "-a", target, "-s", service }, null, false, true, 15);
        if (!core.success(r.term) and !(r.term == .exited and r.term.exited == 44)) return c.fail("Could not remove the saved Keychain password.", .{});
        return "Removed this desktop's wallet password from macOS Keychain.";
    }
    const remote = "python3 \"$HOME/.local/lib/desktop/unlock-wallet.py\"";
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(c.a, &.{ "ssh", "-T", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", if (o.setup) "BatchMode=no" else "BatchMode=yes" });
    if (o.setup) {
        try args.appendSlice(c.a, &.{ "-o", "StrictHostKeyChecking=ask" });
        try c.log("Connecting to the desktop. SSH may ask you to confirm its host key or authenticate.", .{});
    }
    try args.appendSlice(c.a, &.{ target, try c.fmt("{s} --status", .{remote}) });
    const no_answer: std.process.RunResult = .{ .term = .{ .exited = 255 }, .stdout = &.{}, .stderr = &.{} };
    var state_result = runner.run(c, args.items, null, o.setup, false, if (o.setup) 180 else 15) catch |err| if (wait > 0 and err == error.Timeout) no_answer else return err;
    const started = nowSeconds(c.io);
    if (wait > 0 and !core.success(state_result.term)) try c.log("Waiting for the desktop session to start...", .{});
    while (wait > 0 and !core.success(state_result.term) and nowSeconds(c.io) - started < wait) {
        try std.Io.sleep(c.io, .fromSeconds(3), .awake);
        state_result = runner.run(c, args.items, null, false, false, 15) catch |err| if (err == error.Timeout) no_answer else return err;
    }
    if (!core.success(state_result.term)) return c.fail("Cannot reach the wallet on {s}. Make sure it is awake, apply ec sync there, then retry ec desktop auth --setup.", .{target});
    const state = core.trim(state_result.stdout);
    if (!eq(u8, state, "locked") and !eq(u8, state, "unlocked")) return c.fail("Unexpected wallet status. Update ec on the desktop.", .{});
    if (eq(u8, state, "unlocked") and !o.setup) return "Desktop wallet is already unlocked.";
    var saved = if (o.setup) std.process.RunResult{ .term = .{ .exited = 44 }, .stdout = &.{}, .stderr = &.{} } else try runner.run(c, &.{ security, "find-generic-password", "-a", target, "-s", service, "-w" }, null, false, true, 30);
    if (saved.term == .exited and saved.term.exited == 44) {
        if (o.json) return c.failCode("interaction_required", "No saved wallet password. Run ec desktop auth --setup in a terminal.", .{});
        try c.log("Enter your KWallet password twice to save it in this Mac's Keychain.", .{});
        const added = try runner.run(c, &.{ security, "add-generic-password", "-U", "-a", target, "-s", service, "-w" }, null, true, false, 180);
        if (!core.success(added.term)) return c.fail("Could not save the wallet password in macOS Keychain.", .{});
        saved = try runner.run(c, &.{ security, "find-generic-password", "-a", target, "-s", service, "-w" }, null, false, true, 30);
    }
    defer std.crypto.secureZero(u8, saved.stdout);
    if (!core.success(saved.term)) return c.fail("Could not read the wallet password from macOS Keychain.", .{});
    const password = passwordBytes(saved.stdout) catch return c.fail("Invalid saved wallet password. Run ec desktop auth --setup to replace it.", .{});
    if (eq(u8, state, "unlocked")) return "Saved in Keychain. The password will be checked on the next unlock.";
    const unlocked = try runner.run(c, &.{ "ssh", "-T", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "BatchMode=yes", target, remote }, password, false, false, 30);
    if (!core.success(unlocked.term)) return c.fail("Wallet unlock failed. If its password changed, run ec desktop auth --setup.", .{});
    return "Desktop wallet unlocked.";
}
test "magic packet has six ff bytes and sixteen MAC repetitions" {
    const p = try magicPacket("02:00:00:00:00:01");
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 255, 255 }, p[0..6]);
    for (0..16) |i| try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0, 1 }, p[6 + i * 6 ..][0..6]);
    try std.testing.expectError(error.InvalidMac, magicPacket("02:00:00:00:00"));
    try std.testing.expectError(error.InvalidMac, magicPacket("gg:00:00:00:00:01"));
}
test "SSH host validation rejects options and shell syntax" {
    for ([_][]const u8{ "-oProxyCommand=bad", "host;echo bad", "$(echo bad)", "a@b@c", "user@-host" }) |host| try std.testing.expect(!validHost(host, true));
    try std.testing.expect(validHost("user@desktop.test", true));
    try std.testing.expect(!validHost("user@desktop.test", false));
}
test "password removes only security newline and preserves spaces" {
    try std.testing.expectEqualStrings(" secret ", try passwordBytes(" secret \n"));
    try std.testing.expectError(error.InvalidPassword, passwordBytes("a\nb\n"));
    try std.testing.expectError(error.InvalidPassword, passwordBytes("\n"));
}

const AuthHarness = struct {
    const Call = struct { args: []const []const u8, input: ?[]const u8, interactive: bool, secret: bool, seconds: i64 };
    calls: std.ArrayList(Call) = .empty,
    password: []u8 = &.{},
    locked: bool = true,
    missing: bool = false,
    denied: bool = false,
    connection_failed: bool = false,
    unlock_failed: bool = false,
    fn run(self: *@This(), c: *C, args: []const []const u8, input: ?[]const u8, interactive: bool, secret: bool, seconds: i64) !std.process.RunResult {
        try self.calls.append(c.a, .{ .args = try c.a.dupe([]const u8, args), .input = if (input) |data| try c.a.dupe(u8, data) else null, .interactive = interactive, .secret = secret, .seconds = seconds });
        var code: u8 = 0;
        var output: []u8 = &.{};
        if (eq(u8, args[0], "ssh") and std.mem.endsWith(u8, args[args.len - 1], "--status")) {
            code = if (self.connection_failed) 255 else 0;
            output = try c.a.dupe(u8, if (self.locked) "locked\n" else "unlocked\n");
        } else if (eq(u8, args[1], "find-generic-password")) {
            if (self.denied) code = 36 else if (self.missing) {
                self.missing = false;
                code = 44;
            } else output = self.password;
        } else if (input != null and self.unlock_failed) code = 1;
        return .{ .term = .{ .exited = code }, .stdout = output, .stderr = &.{} };
    }
};
fn authTest(c: *C, h: *AuthHarness, o: O) !void {
    h.password = try c.a.dupe(u8, "test-wallet-password \n");
    const config = try c.parse("{\"host\":\"desktop.test\",\"sshUser\":\"user\"}");
    _ = try authWith(c, config, o, .macos, h, 0);
}
test "wallet auth sends password only on stdin and wipes it after success or failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const devnull = try core.cwd().createFile(std.testing.io, "/dev/null", .{});
    defer devnull.close(std.testing.io);
    var c: C = .{ .a = arena.allocator(), .io = std.testing.io, .env = &env, .home = "/unused", .stdout = devnull, .stderr = devnull };
    for ([_]bool{ false, true }) |failure| {
        var h: AuthHarness = .{ .unlock_failed = failure };
        if (failure) try std.testing.expectError(error.Reported, authTest(&c, &h, .{})) else try authTest(&c, &h, .{});
        const request = h.calls.items[h.calls.items.len - 1];
        try std.testing.expectEqualStrings("test-wallet-password ", request.input.?);
        for (h.calls.items) |call| for (call.args) |arg| {
            try std.testing.expect(std.mem.indexOf(u8, arg, "test-wallet-password") == null);
        };
        for (h.password) |ch| try std.testing.expectEqual(@as(u8, 0), ch);
        try std.testing.expect(!request.interactive);
    }
}
test "wallet setup confirms first SSH connection before saving in Keychain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const devnull = try core.cwd().createFile(std.testing.io, "/dev/null", .{});
    defer devnull.close(std.testing.io);
    var c: C = .{ .a = arena.allocator(), .io = std.testing.io, .env = &env, .home = "/unused", .stdout = devnull, .stderr = devnull };
    var h: AuthHarness = .{};
    try authTest(&c, &h, .{ .setup = true });
    const first = h.calls.items[0];
    try std.testing.expect(first.interactive and first.seconds >= 120);
    var batch = false;
    var confirm = false;
    for (first.args) |arg| {
        if (eq(u8, arg, "BatchMode=no")) batch = true;
        if (eq(u8, arg, "StrictHostKeyChecking=ask")) confirm = true;
    }
    try std.testing.expect(batch and confirm);
    const save = h.calls.items[1];
    try std.testing.expectEqualStrings("add-generic-password", save.args[1]);
    try std.testing.expect(save.interactive and save.input == null);
    try std.testing.expectEqualStrings("-w", save.args[save.args.len - 1]);
}
test "wallet auth does not overwrite denied credentials or prompt in JSON mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const devnull = try core.cwd().createFile(std.testing.io, "/dev/null", .{});
    defer devnull.close(std.testing.io);
    var c: C = .{ .a = arena.allocator(), .io = std.testing.io, .env = &env, .home = "/unused", .stdout = devnull, .stderr = devnull };
    var denied: AuthHarness = .{ .denied = true };
    try std.testing.expectError(error.Reported, authTest(&c, &denied, .{}));
    try std.testing.expectEqual(@as(usize, 2), denied.calls.items.len);
    var missing: AuthHarness = .{ .missing = true };
    try std.testing.expectError(error.Reported, authTest(&c, &missing, .{ .json = true }));
    try std.testing.expectEqual(@as(usize, 2), missing.calls.items.len);
    var unreachable_host: AuthHarness = .{ .connection_failed = true };
    try std.testing.expectError(error.Reported, authTest(&c, &unreachable_host, .{ .setup = true }));
    try std.testing.expectEqual(@as(usize, 1), unreachable_host.calls.items.len);
}
test "open wallet avoids Keychain but setup can replace its password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const devnull = try core.cwd().createFile(std.testing.io, "/dev/null", .{});
    defer devnull.close(std.testing.io);
    var c: C = .{ .a = arena.allocator(), .io = std.testing.io, .env = &env, .home = "/unused", .stdout = devnull, .stderr = devnull };
    var open: AuthHarness = .{ .locked = false };
    try authTest(&c, &open, .{});
    try std.testing.expectEqual(@as(usize, 1), open.calls.items.len);
    var setup: AuthHarness = .{ .locked = false };
    try authTest(&c, &setup, .{ .setup = true });
    try std.testing.expectEqual(@as(usize, 3), setup.calls.items.len);
    for (setup.password) |ch| try std.testing.expectEqual(@as(u8, 0), ch);
    var forget: AuthHarness = .{};
    try authTest(&c, &forget, .{ .forget = true });
    try std.testing.expectEqual(@as(usize, 1), forget.calls.items.len);
    try std.testing.expectEqualStrings("delete-generic-password", forget.calls.items[0].args[1]);
}
