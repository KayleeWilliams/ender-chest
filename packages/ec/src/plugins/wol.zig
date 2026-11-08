const std = @import("std");
const core = @import("../core.zig");
const runtime = @import("runtime.zig");
const host = @import("../host.zig");
const C = core.Context;
const Call = runtime.Call;

pub const manifest = @embedFile("wol.toml");

fn magicPacket(mac: []const u8) ![102]u8 {
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
fn onLan(broadcast: [4]u8) bool {
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
        if (core.eql(u8, std.mem.asBytes(&in.addr), &broadcast)) return true;
    }
    return false;
}
fn hostSetting(c: *C, call: Call) ![]const u8 {
    const h = call.string("host");
    if (!core.validHost(h, false)) return c.fail("Invalid host {s}. Use a hostname such as desktop.example.test.", .{h});
    return h;
}

pub const commands = struct {
    pub fn status(c: *C, call: Call) !core.Outcome {
        const h = try hostSetting(c, call);
        const ok = try host.reachable(c, h);
        if (!ok) return c.failedData("wol status", .@"unreachable", try c.fmt("{s} is not reachable. It may be off, booting, or disconnected from Tailscale.", .{h}), null);
        return c.result("wol status", try c.fmt("{s} is reachable.", .{h}));
    }
    pub fn wake(c: *C, call: Call) !core.Outcome {
        const local = call.flag("local");
        const via = call.option("via");
        if (local and via != null) return c.failCode(.usage_error, "Use --local or --via, not both.", .{});
        const auto_local = !local and via == null and homeLan(call);
        if (call.flag("no-wait")) {
            return c.result("wol wake", try c.fmt("{s} Run ec wol status to check reachability.", .{try send(c, call, local or auto_local)}));
        }
        const h = try hostSetting(c, call);
        const wait = try call.duration(c, "wait_seconds");
        const already = try host.reachable(c, h);
        if (!already) {
            try c.log("{s} Waiting up to {d}s for {s}...", .{ try send(c, call, local or auto_local), wait, h });
            // Another network can share the machine's subnet, so a silent machine also gets the relay's packet.
            const fallback = @min(20, wait);
            var up = try host.waitReachable(c, h, true, if (auto_local) fallback else wait);
            if (!up and auto_local) {
                if (call.setting("relay") != null) {
                    try c.log("No answer yet. Trying the relay too, in case this is a different network.", .{});
                    const sent = send(c, call, false) catch |err| try c.recover(err);
                    try c.log("{s}", .{sent});
                }
                up = try host.waitReachable(c, h, true, wait - fallback);
            }
            if (!up) return c.failCode(.@"unreachable", "Wake packet sent, but {s} did not respond within {d}s. Check that it is plugged into its LAN and that Wake-on-LAN is enabled.", .{ h, wait });
        }
        const awake = if (already) try c.fmt("{s} is already awake.", .{h}) else try c.fmt("{s} is awake.", .{h});
        const after = call.setting("after_wake") orelse "";
        if (core.trim(after).len == 0 or call.flag("skip-after")) {
            return c.result("wol wake", awake);
        }
        try c.log("{s} Running ec {s}...", .{ awake, after });
        if (!try afterWake(c, call, after)) return c.fail("{s} ec {s} failed; run it again to retry.", .{ awake, after });
        return c.result("wol wake", awake);
    }
};
fn homeLan(call: Call) bool {
    const ip = std.Io.net.IpAddress.parseIp4(call.string("broadcast"), 0) catch return false;
    return onLan(ip.ip4.bytes);
}
fn send(c: *C, call: Call, local: bool) ![]const u8 {
    const broadcast = call.string("broadcast");
    if (local) {
        if (!call.flag("local")) try c.log("On the machine's network; sending the wake packet directly.", .{});
        const mac = call.string("mac");
        const packet = magicPacket(mac) catch return c.fail("Invalid mac {s}. Expected six colon-separated hex pairs.", .{mac});
        const port = call.integer("port");
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
    _ = try host.runEc(c, relay, "wol", "wake --local --no-wait", 20);
    return c.fmt("Wake packet sent through {s}.", .{relay});
}
// Runs `ec <after_wake>` with this terminal. Its stdout joins stderr under --json, so stdout
// stays one result.
fn afterWake(c: *C, call: Call, command: []const u8) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(c.a, call.ec_bin);
    var words = std.mem.tokenizeScalar(u8, command, ' ');
    while (words.next()) |word| try argv.append(c.a, word);
    var child = try std.process.spawn(c.io, .{ .argv = argv.items, .environ_map = c.env, .stdin = .inherit, .stdout = if (c.json) .{ .file = c.stderr } else .inherit, .stderr = .inherit });
    return core.success(try child.wait(c.io));
}
