// One Executor MCP server shared by every machine. The host is a Mac that runs it under launchd.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core.zig");
const paths = @import("../paths.zig");
const runtime = @import("runtime.zig");
const host = @import("../host.zig");
const C = core.Context;
const Call = runtime.Call;

pub const manifest = @embedFile("executor.toml");

const label = "sh.executor.server";
// Executor encrypts saved accounts with this key. It stays on the host and never enters the repo.
const encryption_key_rel = ".config/executor/encryption-key";
// The npm package defaults EXECUTOR_DATA_DIR to this path.
const data_rel = ".executor/v2/cli";

const Config = struct { url: []const u8, package: []const u8, host: []const u8, port: u16, https: bool };

// Accepts an origin with an explicit port, such as https://mcp.example.test:4312, so the
// local listener and the Tailscale Serve port can match.
fn parse(url: []const u8, package: []const u8) !Config {
    const https = std.mem.startsWith(u8, url, "https://");
    if (!https and !std.mem.startsWith(u8, url, "http://")) return error.InvalidUrl;
    const authority = url[(std.mem.indexOf(u8, url, "://") orelse unreachable) + 3 ..];
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return error.InvalidUrl;
    const name = authority[0..colon];
    if (!core.validHost(name, false)) return error.InvalidUrl;
    const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.InvalidUrl;
    if (port == 0) return error.InvalidUrl;
    if (!std.mem.startsWith(u8, package, "executor@") or !core.safeName(package[9..])) return error.InvalidPackage;
    return .{ .url = url, .package = package, .host = name, .port = port, .https = https };
}
fn validKey(key: []const u8) bool {
    return key.len >= 32 and host.safeToken(key);
}
fn load(c: *C, call: Call) !Config {
    const url = call.string("url");
    const package = call.string("package");
    return parse(url, package) catch |err| switch (err) {
        error.InvalidUrl => c.fail("Invalid url {s}. Use an origin with a port, as in https://mcp.example.test:4312.", .{url}),
        error.InvalidPackage => c.fail("Invalid package {s}. Use an npm spec such as executor@beta.", .{package}),
    };
}
fn apiKey(c: *C, key: []const u8) ![]const u8 {
    if (!validKey(key)) return c.fail("Invalid Executor key. Use at least 32 characters without spaces or quotes, and replace it with ec secret set executor.", .{});
    return key;
}

pub const commands = struct {
    pub fn url(c: *C, call: Call) !core.Outcome {
        const config = try load(c, call);
        // url does not need the key, but a saved key that cannot work is still worth reporting.
        if (call.setting("key")) |key| _ = try apiKey(c, key);
        const mcp = try c.fmt("{s}/mcp", .{config.url});
        return c.resultData("executor url", mcp, .{ .url = mcp });
    }
    pub fn status(c: *C, call: Call) !core.Outcome {
        const config = try load(c, call);
        const r = try host.get(c, try openapi(c, config.url), try apiKey(c, call.string("key"))) orelse return c.failCode(.@"unreachable", "Cannot reach Executor at {s}. Check Tailscale, or run ec executor restart.", .{config.url});
        if (r.status == 401 or r.status == 403) return c.fail("Executor at {s} rejected the API key. Make sure the executor secret matches the host's, then run ec executor restart.", .{config.url});
        if (r.status != 200) return c.fail("Executor at {s} returned HTTP {d}.", .{ config.url, r.status });
        const mcp = try c.fmt("{s}/mcp", .{config.url});
        return c.resultData("executor status", try c.fmt("Executor answers at {s}. MCP: {s}", .{ config.url, mcp }), .{ .url = config.url, .mcp = mcp });
    }
    // The launch agent runs this. The keys reach Executor through its environment, so the
    // plist holds no secret.
    pub fn serve(c: *C, call: Call) !core.Outcome {
        const config = try load(c, call);
        const dir = try useNode(c);
        try executorEnv(c, config, try apiKey(c, call.string("key")));
        const err = std.process.replace(c.io, .{ .argv = &.{ try executorBin(c, dir), "serve" }, .environ_map = c.env });
        return c.fail("Cannot run executor serve: {s}. Run ec executor update.", .{@errorName(err)});
    }
    pub fn restart(c: *C, call: Call) !core.Outcome {
        const config = try load(c, call);
        const key = try apiKey(c, call.string("key"));
        if (!try isHost(c, config)) return remoteThenWait(c, config, key, "restart", 120);
        try requireMac(c);
        const plist = try host.agentPlist(c, label);
        if (!c.exists(plist)) return c.fail("{s} is missing. Run ec executor update.", .{plist});
        try host.restartAgent(c, label);
        try waitFor(c, try localUrl(c, config), key);
        return c.result("executor restart", "Executor restarted.");
    }
    pub fn update(c: *C, call: Call) !core.Outcome {
        const config = try load(c, call);
        const key = try apiKey(c, call.string("key"));
        // Installing the npm package can take minutes.
        if (!try isHost(c, config)) return remoteThenWait(c, config, key, "update", 900);
        try requireMac(c);
        const ec = try paths.inHome(c, paths.ec_bin);
        if (!c.exists(ec)) return c.fail("{s} is missing. Run ec sync first.", .{ec});
        const dir = try useNode(c);
        try c.log("Installing {s}...", .{config.package});
        try c.command(&.{ try c.path(&.{ dir, "npm" }), "install", "--global", config.package, "--include=optional" }, null);
        try ensureEncryptionKey(c);
        try c.write(try host.agentPlist(c, label), try renderPlist(c.a, ec, c.env.get("PATH").?, c.home), 0o644);
        try host.reloadAgent(c, label);
        if (config.https) {
            const port = try c.fmt("--https={d}", .{config.port});
            try c.command(&.{ try host.tailscale(c), "serve", "--bg", port, try localUrl(c, config) }, null);
        }
        try waitFor(c, try localUrl(c, config), key);
        const version = c.capture(&.{ try executorBin(c, dir), "--version" }, null, 30) catch null;
        const text = if (version) |v| core.trim(v.stdout) else config.package;
        return c.resultData("executor update", try c.fmt("{s} runs at {s}.", .{ text, config.url }), .{ .url = config.url, .version = text });
    }
    pub fn pair(c: *C, call: Call) !core.Outcome {
        const config = try load(c, call);
        const key = try apiKey(c, call.string("key"));
        if (!try isHost(c, config)) {
            const link = try remote(c, config, "pair", 120);
            return c.resultData("executor pair", link, .{ .url = link });
        }
        const dir = try useNode(c);
        try executorEnv(c, config, key);
        const r = try c.capture(&.{ try executorBin(c, dir), "pair" }, null, 30);
        if (!core.success(r.term)) {
            try c.stderr.writeStreamingAll(c.io, r.stderr);
            return c.fail("executor pair failed. Check that Executor is running with ec executor status.", .{});
        }
        const link = core.trim(r.stdout);
        return c.resultData("executor pair", link, .{ .url = link });
    }
};

// The host is the machine whose Tailscale name matches the configured URL, or one that
// already has the launch agent.
fn isHost(c: *C, config: Config) !bool {
    if (c.exists(try host.agentPlist(c, label))) return true;
    const name = try host.tailnetName(c) orelse return false;
    return std.ascii.eqlIgnoreCase(name, config.host);
}
fn requireMac(c: *C) !void {
    if (builtin.os.tag != .macos) return c.fail("The Executor host runs under launchd, so it must be a Mac.", .{});
}

// SSH sessions may not have Homebrew on PATH. Puts npm's directory first on PATH, because the
// executor launcher runs node through env, and returns that directory.
fn useNode(c: *C) ![]const u8 {
    const npm = c.resolveCommand("npm") catch for ([_][]const u8{ "/opt/homebrew/bin/npm", "/usr/local/bin/npm" }) |npm| {
        if (c.exists(npm)) break npm;
    } else return c.fail("Cannot find npm. Install Node 24.14 or newer, such as brew install node.", .{});
    const dir = std.fs.path.dirname(npm).?;
    try c.env.put("PATH", try c.fmt("{s}:{s}", .{ dir, c.env.get("PATH") orelse "/usr/bin:/bin" }));
    return dir;
}
fn executorBin(c: *C, node_dir: []const u8) ![]const u8 {
    const bin = try c.path(&.{ node_dir, "executor" });
    if (!c.exists(bin)) return c.fail("{s} is missing. Run ec executor update.", .{bin});
    return bin;
}

fn ensureEncryptionKey(c: *C) !void {
    const file = try paths.inHome(c, encryption_key_rel);
    if (c.exists(file)) return c.chmod(file, 0o600);
    const data = try paths.inHome(c, data_rel);
    if (c.exists(data)) return c.fail("{s} exists but {s} is missing. Restore the key from a backup; a new key cannot read saved accounts.", .{ data, file });
    var bytes: [32]u8 = undefined;
    std.Io.random(c.io, &bytes);
    try c.write(file, try c.fmt("{x}\n", .{bytes}), 0o600);
    try c.log("Created {s}. Back it up with {s}.", .{ file, data });
}

fn renderPlist(a: std.mem.Allocator, ec: []const u8, path: []const u8, home: []const u8) ![]const u8 {
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

fn executorEnv(c: *C, config: Config, key: []const u8) !void {
    const file = try paths.inHome(c, encryption_key_rel);
    const encryption = core.trim(try c.optional(file) orelse return c.fail("{s} is missing. Run ec executor update.", .{file}));
    if (encryption.len != 64) return c.fail("{s} must hold 64 hexadecimal characters.", .{file});
    try c.env.put("EXECUTOR_API_KEY", key);
    try c.env.put("EXECUTOR_ENCRYPTION_KEY", encryption);
    try c.env.put("EXECUTOR_PORT", try c.fmt("{d}", .{config.port}));
    // Pairing links and OAuth callbacks use this origin, and the dashboard accepts its Host.
    if (config.https) try c.env.put("EXECUTOR_BROWSER_ORIGIN", config.url);
    // ec executor update handles upgrades.
    try c.env.put("EXECUTOR_NO_UPDATE_CHECK", "1");
    // Supplied keys cannot be combined with a key storage choice.
    _ = c.env.swapRemove("EXECUTOR_KEY_STORAGE");
}

// Runs `ec executor ACTION` on the host and returns its output.
fn remote(c: *C, config: Config, action: []const u8, limit: i64) ![]const u8 {
    try c.log("Running ec executor {s} on {s}...", .{ action, config.host });
    return host.runEc(c, config.host, "executor", action, limit);
}
fn remoteThenWait(c: *C, config: Config, key: []const u8, action: []const u8, limit: i64) !core.Outcome {
    const output = try remote(c, config, action, limit);
    try waitFor(c, config.url, key);
    return c.result(try c.fmt("executor {s}", .{action}), try c.fmt("{s}\nExecutor answers at {s}.", .{ output, config.url }));
}

fn localUrl(c: *C, config: Config) ![]const u8 {
    return c.fmt("http://127.0.0.1:{d}", .{config.port});
}
fn openapi(c: *C, origin: []const u8) ![]const u8 {
    return c.fmt("{s}/openapi.json", .{origin});
}
// The OpenAPI document needs the API key, so a 200 also proves the key works.
fn waitFor(c: *C, origin: []const u8, key: []const u8) !void {
    const limit = try host.envSeconds(c, "EXECUTOR_RESTART_TIMEOUT", 120);
    if (!try host.waitOk(c, try openapi(c, origin), key, limit)) return c.failCode(.@"unreachable", "Executor did not answer at {s} within {d}s. Check ~/Library/Logs/executor.log on the host.", .{ origin, limit });
}

test "parse requires an origin with a port and an executor package" {
    const config = try parse("https://mcp.example.test:4312", "executor@beta");
    try std.testing.expectEqualStrings("mcp.example.test", config.host);
    try std.testing.expectEqual(@as(u16, 4312), config.port);
    const bad = [_]struct { url: []const u8, package: []const u8 = "executor@beta" }{
        .{ .url = "https://mcp.example.test" },
        .{ .url = "https://mcp.example.test:4312/mcp" },
        .{ .url = "ftp://mcp:4312" },
        .{ .url = "https://mcp:4312", .package = "other@1" },
        .{ .url = "https://mcp:4312", .package = "executor@beta;rm" },
    };
    for (bad) |b| try std.testing.expect(std.meta.isError(parse(b.url, b.package)));
    try std.testing.expect(!validKey("short") and validKey("k" ** 32));
}
