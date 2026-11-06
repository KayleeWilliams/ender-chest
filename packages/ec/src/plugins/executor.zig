// One Executor MCP server shared by every machine. The host is a Mac that runs it under launchd.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core.zig");
const runtime = @import("runtime.zig");
const C = core.Context;
const Call = runtime.Call;
const eq = core.eql;

pub const label = "sh.executor.server";
// Executor encrypts saved accounts with this key. It stays on the host and never enters the repo.
const encryption_key_rel = ".config/executor/encryption-key";
// The npm package defaults EXECUTOR_DATA_DIR to this path.
const data_rel = ".executor/v2/cli";

pub const Config = struct { url: []const u8, key: ?[]const u8, package: []const u8, host: []const u8, port: u16, https: bool };

// Accepts an origin with an explicit port, such as https://mcp.example.test:4312, so the
// local listener and the Tailscale Serve port can match. A missing key stays null, since url
// needs none.
pub fn parse(url_setting: ?[]const u8, key: ?[]const u8, package_setting: ?[]const u8) !Config {
    const url = std.mem.trimEnd(u8, url_setting orelse return error.InvalidUrl, "/");
    const https = std.mem.startsWith(u8, url, "https://");
    if (!https and !std.mem.startsWith(u8, url, "http://")) return error.InvalidUrl;
    const authority = url[(std.mem.indexOf(u8, url, "://") orelse unreachable) + 3 ..];
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return error.InvalidUrl;
    const host = authority[0..colon];
    if (!core.validHost(host, false)) return error.InvalidUrl;
    const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.InvalidUrl;
    if (port == 0) return error.InvalidUrl;
    if (key) |k| if (k.len < 32 or std.mem.indexOfAny(u8, k, " \t\r\n\"\\") != null) return error.InvalidKey;
    const package = package_setting orelse "executor@beta";
    if (!std.mem.startsWith(u8, package, "executor@") or !core.safeName(package[9..])) return error.InvalidPackage;
    return .{ .url = url, .key = key, .package = package, .host = host, .port = port, .https = https };
}
fn load(c: *C, call: Call) !Config {
    return parse(call.setting("url"), call.setting("key"), call.setting("package")) catch |err| switch (err) {
        error.InvalidUrl => c.fail("Invalid url {s}. Use an origin with a port, as in https://mcp.example.test:4312.", .{call.setting("url") orelse ""}),
        error.InvalidKey => c.fail("Invalid Executor key. Use at least 32 characters without spaces or quotes, and replace it with ec secret set executor.", .{}),
        error.InvalidPackage => c.fail("Invalid package {s}. Use an npm spec such as executor@beta.", .{call.setting("package") orelse ""}),
    };
}
fn requireKey(c: *C, config: Config) ![]const u8 {
    return config.key orelse c.failCode("interaction_required", "No Executor API key. Set it with key = {{ secret = \"executor\" }} under [plugins.executor], then run ec secret set executor.", .{});
}

pub fn run(c: *C, call: Call) !bool {
    const config = try load(c, call);
    const command = call.command;
    if (eq(u8, command, "url")) {
        const mcp = try c.fmt("{s}/mcp", .{config.url});
        try c.resultData("executor url", true, mcp, .{ .url = mcp });
        return true;
    }
    _ = try requireKey(c, config);
    if (eq(u8, command, "status")) {
        try status(c, config);
    } else if (eq(u8, command, "serve")) {
        try serve(c, config);
    } else if (eq(u8, command, "restart") or eq(u8, command, "update") or eq(u8, command, "pair")) {
        if (!try isHost(c, config)) {
            try remote(c, config, command);
        } else if (eq(u8, command, "restart")) try restart(c, config) else if (eq(u8, command, "update")) try update(c, config) else try pair(c, config);
    } else return c.fail("Unknown executor command {s}.", .{command});
    return true;
}

fn status(c: *C, config: Config) !void {
    const code = try get(c, config, config.url) orelse return c.failCode("unreachable", "Cannot reach Executor at {s}. Check Tailscale, or run ec executor restart.", .{config.url});
    if (code == 401 or code == 403) return c.fail("Executor at {s} rejected the API key. Make sure the executor secret matches the host's, then run ec executor restart.", .{config.url});
    if (code != 200) return c.fail("Executor at {s} returned HTTP {d}.", .{ config.url, code });
    const mcp = try c.fmt("{s}/mcp", .{config.url});
    try c.resultData("executor status", true, try c.fmt("Executor answers at {s}. MCP: {s}", .{ config.url, mcp }), .{ .url = config.url, .mcp = mcp });
}

// The host is the machine whose Tailscale name matches the configured URL, or one that
// already has the launch agent.
fn isHost(c: *C, config: Config) !bool {
    if (c.exists(try plistPath(c))) return true;
    const tailscale = @import("../fleet.zig").tailscale(c) catch {
        c.message = null;
        return false;
    };
    const r = c.capture(&.{ tailscale, "status", "--json", "--peers=false" }, null, 15) catch return false;
    if (!core.success(r.term)) return false;
    const parsed = c.parse(r.stdout) catch return false;
    const self = if (parsed == .object) parsed.object.get("Self") orelse return false else return false;
    const dns = core.string(self, "DNSName") orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, dns, "."), config.host);
}

fn plistPath(c: *C) ![]const u8 {
    return c.path(&.{ c.home, "Library/LaunchAgents/" ++ label ++ ".plist" });
}
fn requireMac(c: *C) !void {
    if (builtin.os.tag != .macos) return c.fail("The Executor host runs under launchd, so it must be a Mac.", .{});
}

// Installs or upgrades the npm package, then reloads the launch agent and Tailscale Serve.
fn update(c: *C, config: Config) !void {
    try requireMac(c);
    const ec = try c.path(&.{ c.home, ".local/bin/ec" });
    if (!c.exists(ec)) return c.fail("{s} is missing. Run ec sync first.", .{ec});
    const dir = try nodePath(c);
    try c.log("Installing {s}...", .{config.package});
    try c.command(&.{ try c.path(&.{ dir, "npm" }), "install", "--global", config.package, "--include=optional" }, null);
    try ensureEncryptionKey(c);
    const plist = try plistPath(c);
    try c.write(plist, try renderPlist(c.a, ec, c.env.get("PATH").?, c.home), 0o644);
    const domain = try c.fmt("gui/{d}", .{std.c.getuid()});
    // bootout fails when the agent is not loaded, which is fine.
    _ = try c.capture(&.{ "launchctl", "bootout", try c.fmt("{s}/" ++ label, .{domain}) }, null, 30);
    try bootstrap(c, domain, plist);
    if (config.https) {
        const tailscale = try @import("../fleet.zig").tailscale(c);
        const port = try c.fmt("--https={d}", .{config.port});
        try c.command(&.{ tailscale, "serve", "--bg", port, try c.fmt("http://127.0.0.1:{d}", .{config.port}) }, null);
    }
    try waitFor(c, config, try localUrl(c, config));
    const version = c.capture(&.{ try executorBin(c), "--version" }, null, 30) catch null;
    const text = if (version) |v| core.trim(v.stdout) else config.package;
    try c.resultData("executor update", true, try c.fmt("{s} runs at {s}.", .{ text, config.url }), .{ .url = config.url, .version = text });
}

// SSH sessions may not have Homebrew on PATH. Puts npm's directory first, because the
// executor launcher runs node through env, and returns that directory.
fn nodePath(c: *C) ![]const u8 {
    const npm = c.resolveCommand("npm") catch for ([_][]const u8{ "/opt/homebrew/bin/npm", "/usr/local/bin/npm" }) |npm| {
        if (c.exists(npm)) break npm;
    } else return c.fail("Cannot find npm. Install Node 24.14 or newer, such as brew install node.", .{});
    const dir = std.fs.path.dirname(npm).?;
    try c.env.put("PATH", try c.fmt("{s}:{s}", .{ dir, c.env.get("PATH") orelse "/usr/bin:/bin" }));
    return dir;
}
fn executorBin(c: *C) ![]const u8 {
    const bin = try c.path(&.{ try nodePath(c), "executor" });
    if (!c.exists(bin)) return c.fail("{s} is missing. Run ec executor update.", .{bin});
    return bin;
}

// bootstrap can fail briefly while launchd finishes a bootout.
fn bootstrap(c: *C, domain: []const u8, plist: []const u8) !void {
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

fn ensureEncryptionKey(c: *C) !void {
    const file = try c.path(&.{ c.home, encryption_key_rel });
    if (c.exists(file)) return c.chmod(file, 0o600);
    const data = try c.path(&.{ c.home, data_rel });
    if (c.exists(data)) return c.fail("{s} exists but {s} is missing. Restore the key from a backup; a new key cannot read saved accounts.", .{ data, file });
    var bytes: [32]u8 = undefined;
    std.Io.random(c.io, &bytes);
    try c.write(file, try c.fmt("{x}\n", .{bytes}), 0o600);
    try c.log("Created {s}. Back it up with {s}.", .{ file, data });
}

pub fn renderPlist(a: std.mem.Allocator, ec: []const u8, path: []const u8, home: []const u8) ![]const u8 {
    const log = try std.fs.path.join(a, &.{ home, "Library/Logs/executor.log" });
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>
    ++ label ++
        \\</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>
    );
    try xml(w, ec);
    try w.writeAll(
        \\</string>
        \\    <string>executor</string>
        \\    <string>serve</string>
        \\  </array>
        \\  <key>EnvironmentVariables</key>
        \\  <dict>
        \\    <key>PATH</key>
        \\    <string>
    );
    try xml(w, path);
    try w.writeAll(
        \\</string>
        \\  </dict>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>KeepAlive</key>
        \\  <true/>
        \\  <key>ThrottleInterval</key>
        \\  <integer>10</integer>
        \\  <key>ProcessType</key>
        \\  <string>Background</string>
        \\  <key>WorkingDirectory</key>
        \\  <string>
    );
    try xml(w, home);
    try w.writeAll(
        \\</string>
        \\  <key>StandardOutPath</key>
        \\  <string>
    );
    try xml(w, log);
    try w.writeAll(
        \\</string>
        \\  <key>StandardErrorPath</key>
        \\  <string>
    );
    try xml(w, log);
    try w.writeAll(
        \\</string>
        \\</dict>
        \\</plist>
        \\
    );
    return out.toOwnedSlice();
}
fn xml(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(ch),
    };
}

// The launch agent runs this. The keys reach Executor through its environment, so the
// plist holds no secret.
fn serve(c: *C, config: Config) !void {
    try executorEnv(c, config);
    const bin = try executorBin(c);
    const err = std.process.replace(c.io, .{ .argv = &.{ bin, "serve" }, .environ_map = c.env });
    return c.fail("Cannot run executor serve: {s}. Run ec executor update.", .{@errorName(err)});
}
fn executorEnv(c: *C, config: Config) !void {
    const file = try c.path(&.{ c.home, encryption_key_rel });
    const encryption = core.trim(try c.optional(file) orelse return c.fail("{s} is missing. Run ec executor update.", .{file}));
    if (encryption.len != 64) return c.fail("{s} must hold 64 hexadecimal characters.", .{file});
    try c.env.put("EXECUTOR_API_KEY", try requireKey(c, config));
    try c.env.put("EXECUTOR_ENCRYPTION_KEY", encryption);
    try c.env.put("EXECUTOR_PORT", try c.fmt("{d}", .{config.port}));
    // Pairing links and OAuth callbacks use this origin, and the dashboard accepts its Host.
    if (config.https) try c.env.put("EXECUTOR_BROWSER_ORIGIN", config.url);
    // ec executor update handles upgrades.
    try c.env.put("EXECUTOR_NO_UPDATE_CHECK", "1");
    // Supplied keys cannot be combined with a key storage choice.
    _ = c.env.swapRemove("EXECUTOR_KEY_STORAGE");
    // Executor gets its key above, not every plugin setting.
    _ = c.env.swapRemove("EC_PLUGIN_SETTINGS");
}

fn restart(c: *C, config: Config) !void {
    try requireMac(c);
    const plist = try plistPath(c);
    if (!c.exists(plist)) return c.fail("{s} is missing. Run ec executor update.", .{plist});
    const domain = try c.fmt("gui/{d}", .{std.c.getuid()});
    const kicked = try c.capture(&.{ "launchctl", "kickstart", "-k", try c.fmt("{s}/" ++ label, .{domain}) }, null, 30);
    // kickstart fails when the agent is not loaded; bootstrap starts it because of RunAtLoad.
    if (!core.success(kicked.term)) try bootstrap(c, domain, plist);
    try waitFor(c, config, try localUrl(c, config));
    try c.result("executor restart", true, "Executor restarted.");
}

fn pair(c: *C, config: Config) !void {
    try executorEnv(c, config);
    const r = try c.capture(&.{ try executorBin(c), "pair" }, null, 30);
    if (!core.success(r.term)) {
        try c.stderr.writeStreamingAll(c.io, r.stderr);
        return c.fail("executor pair failed. Check that Executor is running with ec executor status.", .{});
    }
    const link = core.trim(r.stdout);
    try c.resultData("executor pair", true, link, .{ .url = link });
}

// Runs the same command on the host, then checks the server over Tailscale.
fn remote(c: *C, config: Config, action: []const u8) !void {
    const command = try c.fmt("\"$HOME/.local/bin/ec\" executor {s}", .{action});
    const seconds: i64 = if (eq(u8, action, "update")) 900 else 120;
    try c.log("Running ec executor {s} on {s}...", .{ action, config.host });
    const r = c.capture(&.{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1", config.host, command }, null, seconds) catch |err| {
        if (err == error.Timeout) return c.fail("ec executor {s} on {s} timed out.", .{ action, config.host });
        return err;
    };
    if (r.stderr.len > 0) try c.stderr.writeStreamingAll(c.io, r.stderr);
    if (r.term == .exited and r.term.exited == 255) return c.fail("Cannot SSH to {s}. This machine's SSH key must be allowed on the Executor host.", .{config.host});
    if (r.term == .exited and r.term.exited == 2) return c.fail("The ec on {s} cannot manage Executor: it is too old or its config does not enable executor. Run ec fleet sync.", .{config.host});
    if (!core.success(r.term)) return c.fail("ec executor {s} failed on {s}.", .{ action, config.host });
    const output = core.trim(r.stdout);
    if (eq(u8, action, "pair")) return c.resultData("executor pair", true, output, .{ .url = output });
    try waitFor(c, config, config.url);
    try c.result(try c.fmt("executor {s}", .{action}), true, try c.fmt("{s}\nExecutor answers at {s}.", .{ output, config.url }));
}

fn localUrl(c: *C, config: Config) ![]const u8 {
    return c.env.get("EXECUTOR_LOCAL_URL") orelse c.fmt("http://127.0.0.1:{d}", .{config.port});
}
fn waitFor(c: *C, config: Config, url: []const u8) !void {
    const configured = c.env.get("EXECUTOR_RESTART_TIMEOUT") orelse "120";
    const seconds = std.fmt.parseInt(i64, configured, 10) catch return c.fail("Invalid EXECUTOR_RESTART_TIMEOUT. Use whole seconds.", .{});
    const started = std.Io.Clock.Timestamp.now(c.io, .awake).raw.toSeconds();
    while (true) {
        if (try get(c, config, url)) |code| if (code == 200) return;
        if (std.Io.Clock.Timestamp.now(c.io, .awake).raw.toSeconds() - started >= seconds) return c.failCode("unreachable", "Executor did not answer at {s} within {d}s. Check ~/Library/Logs/executor.log on the host.", .{ url, seconds });
        try std.Io.sleep(c.io, .fromSeconds(1), .awake);
    }
}
// Requests the OpenAPI document, which needs the API key. Returns null when curl cannot connect.
fn get(c: *C, config: Config, url: []const u8) !?u16 {
    const args = [_][]const u8{ "curl", "--config", "-", "--silent", "--output", "/dev/null", "--connect-timeout", "10", "--max-time", "30", "--write-out", "%{http_code}", try c.fmt("{s}/openapi.json", .{url}) };
    // Send the key on stdin so it never appears in curl's arguments.
    const header = try c.fmt("header = \"Authorization: Bearer {s}\"\n", .{try requireKey(c, config)});
    const r = core.bounded(c, @import("cliproxyapi.zig").curl, .{ c, &args, header }, 40) catch |err| {
        if (err == error.Timeout) return null;
        return err;
    };
    if (!core.success(r.term)) return null;
    const code = std.fmt.parseInt(u16, core.trim(r.stdout), 10) catch return null;
    return if (code == 0) null else code;
}

test "parse requires an origin with a port and a long key" {
    const k = "k" ** 32;
    const config = try parse("https://mcp.example.test:4312/", k, null);
    try std.testing.expectEqualStrings("https://mcp.example.test:4312", config.url);
    try std.testing.expectEqualStrings("mcp.example.test", config.host);
    try std.testing.expectEqual(@as(u16, 4312), config.port);
    try std.testing.expectEqualStrings("executor@beta", config.package);
    // url works before the key is set.
    try std.testing.expect((try parse("https://mcp.example.test:4312", null, null)).key == null);
    const bad = [_]struct { url: []const u8, key: ?[]const u8 = k, package: ?[]const u8 = null }{
        .{ .url = "https://mcp.example.test" },
        .{ .url = "https://mcp.example.test:4312/mcp" },
        .{ .url = "ftp://mcp:4312" },
        .{ .url = "https://mcp:4312", .key = "short" },
        .{ .url = "https://mcp:4312", .package = "other@1" },
        .{ .url = "https://mcp:4312", .package = "executor@beta;rm" },
    };
    for (bad) |b| try std.testing.expect(std.meta.isError(parse(b.url, b.key, b.package)));
}
test "the launch agent plist escapes paths and runs ec executor serve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plist = try renderPlist(arena.allocator(), "/Users/a&b/.local/bin/ec", "/opt/homebrew/bin:/usr/bin", "/Users/a&b");
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>/Users/a&amp;b/.local/bin/ec</string>\n    <string>executor</string>\n    <string>serve</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>/Users/a&amp;b/Library/Logs/executor.log</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "EXECUTOR_API_KEY") == null);
}
