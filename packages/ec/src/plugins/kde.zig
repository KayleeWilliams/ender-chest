const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core.zig");
const runtime = @import("runtime.zig");
const host = @import("../host.zig");
const C = core.Context;
const Call = runtime.Call;
const eq = core.eql;

pub const manifest = @embedFile("kde.toml");

// The helper travels on stdin, so the machine needs only Python and python-dbus, not ec. A
// length line lets the password follow the script on the same stream.
const helper = @embedFile("unlock-wallet.py");
const loader = "python3 -c 'import sys;b=sys.stdin.buffer;exec(b.read(int(b.readline())))'";
fn helperInput(c: *C, password: []const u8) ![]u8 {
    return std.fmt.allocPrint(c.a, "{d}\n{s}{s}", .{ helper.len, helper, password });
}

// `security`'s exit status when the Keychain has no such item.
const not_found: u8 = 44;

const Flags = struct { setup: bool = false, forget: bool = false, local: bool = false };

fn target(c: *C, call: Call) ![]const u8 {
    const t = call.string("host");
    if (!core.validHost(t, true)) return c.fail("Invalid host {s}. Use HOST or USER@HOST.", .{t});
    return t;
}
fn hostname(t: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, t, '@')) |at| t[at + 1 ..] else t;
}

pub const commands = struct {
    pub fn unlock(c: *C, call: Call) !core.Outcome {
        const o: Flags = .{ .setup = call.flag("setup"), .forget = call.flag("forget"), .local = call.flag("local") };
        if (@as(u8, @intFromBool(o.setup)) + @intFromBool(o.forget) + @intFromBool(o.local) > 1) return c.failCode(.usage_error, "Use only one of --setup, --forget, or --local.", .{});
        const t = try target(c, call);
        const wait = if (call.flag("wait")) try call.duration(c, "wait_seconds") else 0;
        return c.result("kde unlock", try unlockWallet(c, t, o, builtin.os.tag, RealRunner{}, wait));
    }
    pub const shutdown = shutdownMachine;
};

// KDE's own logout path ends the session cleanly and needs no polkit or sudo rule.
const shutdown_command = "echo ready; export DBUS_SESSION_BUS_ADDRESS=\"unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus\"; busctl --user call org.kde.Shutdown /Shutdown org.kde.Shutdown logoutAndShutdown";
fn shutdownMachine(c: *C, call: Call) !core.Outcome {
    const t = try target(c, call);
    const name = hostname(t);
    const wait = try call.duration(c, "wait_seconds");
    if (!try host.reachable(c, name)) {
        return c.result("kde shutdown", try c.fmt("{s} is not reachable. It is likely already off.", .{name}));
    }
    try c.log("Asking KDE on {s} to shut down...", .{t});
    const r = c.capture(try host.sshArgv(c, t, false, shutdown_command), null, 45) catch |err| switch (err) {
        // The connection can stall while the machine goes down.
        error.Timeout => null,
        else => return err,
    };
    if (r) |result| {
        if (result.stderr.len > 0) try c.stderr.writeStreamingAll(c.io, result.stderr);
        if (std.mem.indexOf(u8, result.stdout, "ready") == null) return c.fail("Cannot SSH to {s}. Check SSH access to it, then retry.", .{t});
        // ssh failing after "ready" means the connection dropped during shutdown.
        if (!core.success(result.term) and !(result.term == .exited and result.term.exited == host.ssh_failed)) return c.fail("KDE did not accept the shutdown request. The Plasma session may not be running on {s}.", .{name});
    }
    if (call.flag("no-wait")) {
        return c.result("kde shutdown", "Shutdown requested.");
    }
    try c.log("Shutdown requested. Waiting up to {d}s for {s} to go offline...", .{ wait, name });
    if (!try host.waitReachable(c, name, false, wait)) return c.fail("Shutdown requested, but {s} still responds after {d}s. An app may have blocked logout; check the machine.", .{ name, wait });
    return c.result("kde shutdown", try c.fmt("{s} is off.", .{name}));
}

// Capture only stdout. Secrets never share a diagnostic buffer or become argv/env values.
fn child(c: *C, args: []const []const u8, input: ?[]const u8, interactive: bool, secret: bool, seconds: i64) !std.process.RunResult {
    return core.bounded(c, childInner, .{ c, args, input, interactive, secret, seconds }, seconds);
}
fn childInner(c: *C, args: []const []const u8, input: ?[]const u8, interactive: bool, secret: bool, seconds: i64) anyerror!std.process.RunResult {
    var p = try std.process.spawn(c.io, .{ .argv = args, .environ_map = c.env, .stdin = if (input != null) .pipe else if (interactive) .inherit else .ignore, .stdout = .pipe, .stderr = if (secret) .ignore else .{ .file = c.stderr } });
    defer p.kill(c.io);
    if (input) |data| {
        // A child that exits without reading its input reports through its exit status.
        p.stdin.?.writeStreamingAll(c.io, data) catch |err| if (err != error.BrokenPipe) return err;
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
fn passwordBytes(bytes: []const u8) ![]const u8 {
    const password = if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
    if (password.len == 0 or password.len > 4096 or std.mem.indexOfAny(u8, password, "\n\x00") != null) return error.InvalidPassword;
    return password;
}
const RealRunner = struct {
    fn run(_: @This(), c: *C, args: []const []const u8, input: ?[]const u8, interactive: bool, secret: bool, seconds: i64) !std.process.RunResult {
        return child(c, args, input, interactive, secret, seconds);
    }
};
// wait > 0 retries the first SSH check while a just-woken machine starts its session.
fn unlockWallet(c: *C, t: []const u8, o: Flags, platform: std.Target.Os.Tag, runner: anytype, wait: i64) ![]const u8 {
    if (c.json and (o.setup or o.local)) return c.failCode(.interaction_required, "ec kde unlock {s} prompts, so it cannot use --json. Run it in a terminal.", .{if (o.setup) "--setup" else "--local"});
    if (o.local) {
        if (platform != .linux) return c.fail("Local wallet unlock is only available on Linux.", .{});
        const r = try runner.run(c, &.{ "python3", "-c", helper, "--prompt" }, null, true, false, 180);
        if (!core.success(r.term)) return c.fail("Wallet unlock failed.", .{});
        return core.trim(r.stdout);
    }
    if (platform != .macos) return c.fail("Remote wallet unlock uses macOS Keychain. On the KDE machine itself, use ec kde unlock --local.", .{});
    const security = "/usr/bin/security";
    const service = try c.fmt("ec.kde.{s}", .{t});
    if (o.forget) {
        const r = try runner.run(c, &.{ security, "delete-generic-password", "-a", t, "-s", service }, null, false, true, 15);
        if (!core.success(r.term) and !(r.term == .exited and r.term.exited == not_found)) return c.fail("Could not remove the saved Keychain password.", .{});
        return c.fmt("Removed the wallet password for {s} from this Mac's Keychain.", .{t});
    }
    if (o.setup) try c.log("Connecting to {s}. SSH may ask you to confirm its host key or authenticate.", .{t});
    const status_argv = try host.sshArgv(c, t, o.setup, loader ++ " --status");
    const script = try helperInput(c, "");
    const no_answer: std.process.RunResult = .{ .term = .{ .exited = host.ssh_failed }, .stdout = &.{}, .stderr = &.{} };
    var state_result = runner.run(c, status_argv, script, o.setup, false, if (o.setup) 180 else 15) catch |err| if (wait > 0 and err == error.Timeout) no_answer else return err;
    const started = host.seconds(c.io);
    if (wait > 0 and !core.success(state_result.term)) try c.log("Waiting for the session on {s} to start...", .{t});
    while (wait > 0 and !core.success(state_result.term) and host.seconds(c.io) - started < wait) {
        try std.Io.sleep(c.io, .fromSeconds(3), .awake);
        state_result = runner.run(c, status_argv, script, false, false, 15) catch |err| if (err == error.Timeout) no_answer else return err;
    }
    if (!core.success(state_result.term)) return c.fail("Cannot reach the wallet on {s}. Make sure it is awake and logged in to Plasma, with python3 and python-dbus installed, then retry ec kde unlock --setup.", .{t});
    const state = core.trim(state_result.stdout);
    if (!eq(u8, state, "locked") and !eq(u8, state, "unlocked")) return c.fail("Unexpected wallet status from {s}.", .{t});
    if (eq(u8, state, "unlocked") and !o.setup) return c.fmt("The wallet on {s} is already unlocked.", .{t});
    var saved = if (o.setup) std.process.RunResult{ .term = .{ .exited = not_found }, .stdout = &.{}, .stderr = &.{} } else try runner.run(c, &.{ security, "find-generic-password", "-a", t, "-s", service, "-w" }, null, false, true, 30);
    if (saved.term == .exited and saved.term.exited == not_found) {
        if (c.json) return c.failCode(.interaction_required, "No saved wallet password for {s}. Run ec kde unlock --setup in a terminal.", .{t});
        try c.log("Enter your KWallet password twice to save it in this Mac's Keychain.", .{});
        const added = try runner.run(c, &.{ security, "add-generic-password", "-U", "-a", t, "-s", service, "-w" }, null, true, false, 180);
        if (!core.success(added.term)) return c.fail("Could not save the wallet password in macOS Keychain.", .{});
        saved = try runner.run(c, &.{ security, "find-generic-password", "-a", t, "-s", service, "-w" }, null, false, true, 30);
    }
    defer std.crypto.secureZero(u8, saved.stdout);
    if (!core.success(saved.term)) return c.fail("Could not read the wallet password from macOS Keychain.", .{});
    const password = passwordBytes(saved.stdout) catch return c.fail("Invalid saved wallet password. Run ec kde unlock --setup to replace it.", .{});
    if (eq(u8, state, "unlocked")) return "Saved in Keychain. The password will be checked on the next unlock.";
    const input = try helperInput(c, password);
    defer std.crypto.secureZero(u8, input);
    const unlocked = try runner.run(c, try host.sshArgv(c, t, false, loader), input, false, false, 30);
    if (!core.success(unlocked.term)) return c.fail("Wallet unlock failed. If its password changed, run ec kde unlock --setup.", .{});
    return c.fmt("The wallet on {s} is unlocked.", .{t});
}

test "password removes only security newline and preserves spaces" {
    try std.testing.expectEqualStrings(" secret ", try passwordBytes(" secret \n"));
    try std.testing.expectError(error.InvalidPassword, passwordBytes("a\nb\n"));
    try std.testing.expectError(error.InvalidPassword, passwordBytes("\n"));
}
const AuthHarness = struct {
    const Run = struct { args: []const []const u8, input: ?[]const u8, interactive: bool };
    calls: std.ArrayList(Run) = .empty,
    password: []u8 = &.{},
    locked: bool = true,
    missing: bool = false,
    denied: bool = false,
    connection_failed: bool = false,
    unlock_failed: bool = false,
    fn run(self: *@This(), c: *C, args: []const []const u8, input: ?[]const u8, interactive: bool, _: bool, _: i64) !std.process.RunResult {
        try self.calls.append(c.a, .{ .args = try c.a.dupe([]const u8, args), .input = if (input) |data| try c.a.dupe(u8, data) else null, .interactive = interactive });
        var code: u8 = 0;
        var output: []u8 = &.{};
        if (eq(u8, args[0], "ssh") and std.mem.endsWith(u8, args[args.len - 1], "--status")) {
            code = if (self.connection_failed) host.ssh_failed else 0;
            output = try c.a.dupe(u8, if (self.locked) "locked\n" else "unlocked\n");
        } else if (eq(u8, args[1], "find-generic-password")) {
            if (self.denied) code = 36 else if (self.missing) {
                self.missing = false;
                code = not_found;
            } else output = self.password;
        } else if (eq(u8, args[0], "ssh") and self.unlock_failed) code = 1;
        return .{ .term = .{ .exited = code }, .stdout = output, .stderr = &.{} };
    }
    fn keychain(self: *@This(), subcommand: []const u8) ?usize {
        for (self.calls.items, 0..) |call, i| if (eq(u8, call.args[0], "/usr/bin/security") and eq(u8, call.args[1], subcommand)) return i;
        return null;
    }
    fn ssh(self: *@This(), suffix: []const u8) ?usize {
        for (self.calls.items, 0..) |call, i| if (eq(u8, call.args[0], "ssh") and std.mem.endsWith(u8, call.args[call.args.len - 1], suffix)) return i;
        return null;
    }
    fn wiped(self: *@This()) bool {
        for (self.password) |ch| if (ch != 0) return false;
        return true;
    }
};
fn authTest(c: *C, h: *AuthHarness, o: Flags) !void {
    h.password = try c.a.dupe(u8, "test-wallet-password \n");
    _ = try unlockWallet(c, "user@desktop.example.test", o, .macos, h, 0);
}
fn testContext(arena: *std.heap.ArenaAllocator, env: *std.process.Environ.Map, devnull: std.Io.File) C {
    return .{ .a = arena.allocator(), .io = std.testing.io, .env = env, .home = "/unused", .stdout = devnull, .stderr = devnull };
}
test "wallet unlock sends the helper and password only on stdin and wipes the password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const devnull = try core.cwd().createFile(std.testing.io, "/dev/null", .{});
    defer devnull.close(std.testing.io);
    var c = testContext(&arena, &env, devnull);
    const expected = try std.fmt.allocPrint(arena.allocator(), "{d}\n{s}test-wallet-password ", .{ helper.len, helper });
    for ([_]bool{ false, true }) |failure| {
        var h: AuthHarness = .{ .unlock_failed = failure };
        if (failure) try std.testing.expectError(error.Reported, authTest(&c, &h, .{})) else try authTest(&c, &h, .{});
        const request = h.calls.items[h.ssh(loader).?];
        try std.testing.expectEqualStrings(expected, request.input.?);
        try std.testing.expect(!request.interactive);
        for (h.calls.items) |call| for (call.args) |arg| {
            try std.testing.expect(std.mem.indexOf(u8, arg, "test-wallet-password") == null);
        };
        try std.testing.expect(h.wiped());
        // The status check gets the helper without a password.
        try std.testing.expect(std.mem.endsWith(u8, h.calls.items[h.ssh("--status").?].input.?, helper));
    }
}
test "wallet setup confirms the SSH connection before saving the password in this host's Keychain item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const devnull = try core.cwd().createFile(std.testing.io, "/dev/null", .{});
    defer devnull.close(std.testing.io);
    var c = testContext(&arena, &env, devnull);
    var h: AuthHarness = .{};
    try authTest(&c, &h, .{ .setup = true });
    const connect = h.ssh("--status").?;
    const save = h.keychain("add-generic-password").?;
    try std.testing.expect(connect < save);
    const first = h.calls.items[connect];
    try std.testing.expect(first.interactive);
    var batch = false;
    var confirm = false;
    for (first.args) |arg| {
        if (eq(u8, arg, "BatchMode=no")) batch = true;
        if (eq(u8, arg, "StrictHostKeyChecking=ask")) confirm = true;
    }
    try std.testing.expect(batch and confirm);
    const saved = h.calls.items[save];
    // security prompts for the password only when -w ends the arguments; ec never holds it in one.
    try std.testing.expect(saved.interactive and saved.input == null);
    try std.testing.expectEqualStrings("-w", saved.args[saved.args.len - 1]);
    var account = false;
    for (h.calls.items) |call| for (call.args) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, "test-wallet-password") == null);
    };
    for (saved.args) |arg| {
        if (eq(u8, arg, "ec.kde.user@desktop.example.test")) account = true;
    }
    try std.testing.expect(account);
}
test "wallet unlock does not overwrite denied credentials or prompt in JSON mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const devnull = try core.cwd().createFile(std.testing.io, "/dev/null", .{});
    defer devnull.close(std.testing.io);
    var c = testContext(&arena, &env, devnull);
    var denied: AuthHarness = .{ .denied = true };
    try std.testing.expectError(error.Reported, authTest(&c, &denied, .{}));
    try std.testing.expect(denied.keychain("add-generic-password") == null);
    c.json = true;
    var missing: AuthHarness = .{ .missing = true };
    try std.testing.expectError(error.Reported, authTest(&c, &missing, .{}));
    try std.testing.expect(missing.keychain("add-generic-password") == null);
    c.json = false;
    var unreachable_host: AuthHarness = .{ .connection_failed = true };
    try std.testing.expectError(error.Reported, authTest(&c, &unreachable_host, .{ .setup = true }));
    try std.testing.expect(unreachable_host.keychain("add-generic-password") == null and unreachable_host.keychain("find-generic-password") == null);
}
test "open wallet avoids Keychain but setup can replace its password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const devnull = try core.cwd().createFile(std.testing.io, "/dev/null", .{});
    defer devnull.close(std.testing.io);
    var c = testContext(&arena, &env, devnull);
    var open: AuthHarness = .{ .locked = false };
    try authTest(&c, &open, .{});
    try std.testing.expect(open.keychain("find-generic-password") == null);
    var setup: AuthHarness = .{ .locked = false };
    try authTest(&c, &setup, .{ .setup = true });
    try std.testing.expect(setup.keychain("add-generic-password") != null);
    try std.testing.expect(setup.ssh(loader) == null);
    try std.testing.expect(setup.wiped());
    var forget: AuthHarness = .{};
    try authTest(&c, &forget, .{ .forget = true });
    try std.testing.expect(forget.keychain("delete-generic-password") != null);
    try std.testing.expect(forget.ssh("--status") == null);
}
