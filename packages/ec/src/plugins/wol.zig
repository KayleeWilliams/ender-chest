// Wakes a machine with Wake-on-LAN and waits until it answers.
const std = @import("std");
const core = @import("../core.zig");
const runtime = @import("runtime.zig");
const C = core.Context;
const Call = runtime.Call;
const eq = core.eql;

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
// An up interface that broadcasts to this address shares the machine's LAN.
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
pub fn nowSeconds(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.toSeconds();
}
pub fn reachable(c: *C, host: []const u8) !bool {
    const r = c.capture(&.{ "ping", "-c", "1", host }, null, 5) catch |err| {
        if (err != error.Timeout) return err;
        return false;
    };
    return core.success(r.term);
}
pub fn waitFor(c: *C, host: []const u8, up: bool, seconds: i64) !bool {
    const started = nowSeconds(c.io);
    while (true) {
        if (try reachable(c, host) == up) return true;
        if (nowSeconds(c.io) - started >= seconds) return false;
        try std.Io.sleep(c.io, .fromSeconds(2), .awake);
    }
}
pub fn waitSeconds(c: *C, call: Call) !i64 {
    const n = call.integer("wait_seconds") orelse 180;
    if (n < 1 or n > 3600) return c.fail("Invalid wait_seconds. Use 1 to 3600.", .{});
    return n;
}
fn hostSetting(c: *C, call: Call) ![]const u8 {
    const h = call.setting("host") orelse "";
    if (!core.validHost(h, false)) return c.fail("Invalid host {s}. Use a hostname such as desktop.example.test.", .{h});
    return h;
}

pub fn run(c: *C, call: Call) !bool {
    if (eq(u8, call.command, "status")) {
        const h = try hostSetting(c, call);
        const ok = try reachable(c, h);
        if (!ok) c.error_code = "unreachable";
        try c.result("wol status", ok, if (ok) try c.fmt("{s} is reachable.", .{h}) else try c.fmt("{s} is not reachable. It may be off, booting, or disconnected from Tailscale.", .{h}));
        return ok;
    }
    if (eq(u8, call.command, "wake")) return wake(c, call);
    return c.fail("Unknown wol command {s}.", .{call.command});
}
fn wake(c: *C, call: Call) !bool {
    const local = call.flag("local");
    const via = call.option("via");
    if (local and via != null) return c.failCode("usage_error", "Use --local or --via, not both.", .{});
    const auto_local = !local and via == null and homeLan(call);
    if (call.flag("no-wait")) {
        try c.result("wol wake", true, try c.fmt("{s} Run ec wol status to check reachability.", .{try send(c, call, local or auto_local)}));
        return true;
    }
    const h = try hostSetting(c, call);
    const wait = try waitSeconds(c, call);
    const already = try reachable(c, h);
    if (!already) {
        try c.log("{s} Waiting up to {d}s for {s}...", .{ try send(c, call, local or auto_local), wait, h });
        // Another network can share the machine's subnet, so a silent machine also gets the relay's packet.
        const fallback = @min(20, wait);
        var up = try waitFor(c, h, true, if (auto_local) fallback else wait);
        if (!up and auto_local) {
            if (call.setting("relay") != null) {
                try c.log("No answer yet. Trying the relay too, in case this is a different network.", .{});
                if (send(c, call, false)) |sent| try c.log("{s}", .{sent}) else |err| {
                    if (err != error.Reported) return err;
                    try c.log("{s}", .{c.message orelse "Wake relay failed."});
                    c.message = null;
                }
            }
            up = try waitFor(c, h, true, wait - fallback);
        }
        if (!up) return c.failCode("unreachable", "Wake packet sent, but {s} did not respond within {d}s. Check that it is plugged into its LAN and that Wake-on-LAN is enabled.", .{ h, wait });
    }
    const awake = if (already) try c.fmt("{s} is already awake.", .{h}) else try c.fmt("{s} is awake.", .{h});
    const after = call.setting("after_wake") orelse "";
    if (core.trim(after).len == 0 or call.flag("skip-after")) {
        try c.result("wol wake", true, awake);
        return true;
    }
    try c.log("{s} Running ec {s}...", .{ awake, after });
    if (!try afterWake(c, after)) return c.fail("{s} ec {s} failed; run it again to retry.", .{ awake, after });
    try c.result("wol wake", true, awake);
    return true;
}
fn homeLan(call: Call) bool {
    const address = call.setting("broadcast") orelse return false;
    const ip = std.Io.net.IpAddress.parseIp4(address, 0) catch return false;
    return onLan(ip.ip4.bytes);
}
// Returns what was sent, for the caller to report.
fn send(c: *C, call: Call, local: bool) ![]const u8 {
    const broadcast = call.setting("broadcast") orelse "";
    if (local) {
        if (!call.flag("local")) try c.log("On the machine's network; sending the wake packet directly.", .{});
        const mac = call.setting("mac") orelse "";
        const packet = magicPacket(mac) catch return c.fail("Invalid mac {s}. Expected six colon-separated hex pairs.", .{mac});
        const port = call.integer("port") orelse 9;
        if (port < 1 or port > 65535) return c.fail("Invalid port {d}. Use 1 to 65535.", .{port});
        const dest = std.Io.net.IpAddress.parseIp4(broadcast, @intCast(port)) catch return c.fail("Invalid broadcast address {s}. Expected IPv4.", .{broadcast});
        const source: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) };
        const socket = try source.bind(c.io, .{ .mode = .dgram, .protocol = .udp, .allow_broadcast = true });
        defer socket.close(c.io);
        try socket.send(c.io, &dest, &packet);
        return c.fmt("Wake packet sent to {s} via {s}.", .{ mac, broadcast });
    }
    const relay = call.option("via") orelse call.setting("relay") orelse return c.fail("No wake relay. Set relay under [plugins.wol], pass --via USER@HOST, or use --local on the machine's LAN.", .{});
    if (!core.validHost(relay, true)) return c.fail("Invalid wake relay. Use an SSH hostname or USER@HOST.", .{});
    try c.log("Sending wake request through {s}...", .{relay});
    const r = c.capture(&.{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", relay, "\"$HOME/.local/bin/ec\" wol wake --local --no-wait" }, null, 20) catch return c.fail("Wake relay failed. Check SSH access to {s} and run ec sync there.", .{relay});
    if (r.stderr.len > 0) try c.stderr.writeStreamingAll(c.io, r.stderr);
    if (r.term == .exited and r.term.exited == 2) return c.fail("The ec on {s} cannot relay: it is too old or its config does not enable wol. Run ec sync there, or ec fleet sync from here.", .{relay});
    if (r.term == .exited and r.term.exited == 255) return c.fail("Cannot SSH to the wake relay {s}. If the connection was refused, turn on Remote Login in its System Settings. On the machine's LAN, try ec wol wake --local.", .{relay});
    if (!core.success(r.term)) return c.fail("Wake relay failed. Check SSH access to {s}; on the machine's LAN, try ec wol wake --local.", .{relay});
    return c.fmt("Wake packet sent through {s}.", .{relay});
}
// Runs `ec <after_wake>` with this terminal. Its stdout joins stderr under --json, so stdout
// stays one result.
fn afterWake(c: *C, command: []const u8) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(c.a, c.env.get("EC_BIN") orelse try std.process.executablePathAlloc(c.io, c.a));
    var words = std.mem.tokenizeScalar(u8, command, ' ');
    while (words.next()) |word| try argv.append(c.a, word);
    var child = try std.process.spawn(c.io, .{ .argv = argv.items, .environ_map = c.env, .stdin = .inherit, .stdout = if (c.json) .{ .file = c.stderr } else .inherit, .stderr = .inherit });
    return core.success(try child.wait(c.io));
}

test "magic packet has six ff bytes and sixteen MAC repetitions" {
    const p = try magicPacket("00:00:5e:00:53:01");
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 255, 255 }, p[0..6]);
    for (0..16) |i| try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x5e, 0, 0x53, 1 }, p[6 + i * 6 ..][0..6]);
    try std.testing.expectError(error.InvalidMac, magicPacket("00:00:5e:00:53"));
    try std.testing.expectError(error.InvalidMac, magicPacket("gg:00:5e:00:53:01"));
}
test "SSH host validation rejects options and shell syntax" {
    for ([_][]const u8{ "-oProxyCommand=bad", "host;echo bad", "$(echo bad)", "a@b@c", "user@-host" }) |h| try std.testing.expect(!core.validHost(h, true));
    try std.testing.expect(core.validHost("user@desktop.example.test", true));
    try std.testing.expect(!core.validHost("user@desktop.example.test", false));
}
