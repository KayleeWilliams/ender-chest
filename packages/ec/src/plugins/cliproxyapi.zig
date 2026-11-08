// Client side of a shared CLIProxyAPI server.
const std = @import("std");
const core = @import("../core.zig");
const contribution = @import("../contributions.zig");
const runtime = @import("runtime.zig");
const host = @import("../host.zig");
const C = core.Context;
const Call = runtime.Call;

pub const manifest = @embedFile("cliproxyapi.toml");

const label = "io.cliproxyapi";

fn validBase(origin: []const u8) bool {
    const start: usize = if (std.mem.startsWith(u8, origin, "https://")) 8 else if (std.mem.startsWith(u8, origin, "http://")) 7 else return false;
    if (origin.len <= start or origin[start] == '/' or origin[start] == '-') return false;
    if (std.mem.indexOfAny(u8, origin, "@?#\\\" \t\r\n") != null) return false;
    for (origin) |ch| if (ch < 32 or ch == 127) return false;
    return !std.mem.endsWith(u8, origin, "/v1");
}
fn validKey(text: []const u8) bool {
    if (text.len > 4096 or !host.safeToken(text)) return false;
    for (text) |ch| if (ch >= 127) return false;
    return true;
}

fn base(c: *C, call: Call) ![]const u8 {
    const url = call.string("url");
    if (!validBase(url)) return c.fail("Invalid url. Use an HTTP or HTTPS URL without credentials, query parameters, or /v1.", .{});
    return url;
}
fn key(c: *C, call: Call) ![]const u8 {
    const k = call.string("key");
    if (!validKey(k)) return c.fail("Invalid CLIProxyAPI key. Replace it with ec secret set cliproxyapi.", .{});
    return k;
}

pub const commands = struct {
    pub fn url(c: *C, call: Call) !core.Outcome {
        const openai = try contribution.openaiUrl(c.a, try base(c, call));
        return c.resultData("cliproxyapi url", openai, .{ .url = openai });
    }
    pub fn run(c: *C, call: Call) !core.Outcome {
        if (call.args.len == 0) return c.failCode(.usage_error, "ec cliproxyapi run needs a command, as in ec cliproxyapi run codex.", .{});
        try c.env.put("OPENAI_BASE_URL", try contribution.openaiUrl(c.a, try base(c, call)));
        try c.env.put("OPENAI_API_KEY", try key(c, call));
        const err = std.process.replace(c.io, .{ .argv = call.args, .environ_map = c.env });
        return c.fail("Cannot run {s}: {s}.", .{ call.args[0], @errorName(err) });
    }
    pub fn models(c: *C, call: Call) !core.Outcome {
        const origin = try base(c, call);
        const r = try host.get(c, try modelsUrl(c, origin), try key(c, call)) orelse return c.failCode(.@"unreachable", "Cannot reach CLIProxyAPI at {s}. Check Tailscale, or run ec cliproxyapi restart.", .{origin});
        if (r.status == 401) return c.fail("CLIProxyAPI at {s} rejected the client key. Replace it with ec secret set cliproxyapi, then run ec sync.", .{origin});
        if (r.status != 200) return c.fail("CLIProxyAPI at {s} returned HTTP {d}.", .{ origin, r.status });
        const body = c.parse(r.body) catch return c.fail("CLIProxyAPI at {s} returned a model list that is not JSON.", .{origin});
        var ids: std.ArrayList([]const u8) = .empty;
        for (core.array(body, "data")) |entry| if (core.string(entry, "id")) |id| try ids.append(c.a, id);
        core.sortStrings(ids.items);
        return c.resultData("cliproxyapi models", try std.mem.join(c.a, "\n", ids.items), .{ .models = ids.items });
    }
    // launchd restarts the agent at once, but the proxy needs a moment before it answers.
    pub fn restart(c: *C, call: Call) !core.Outcome {
        const origin = try base(c, call);
        const k = try key(c, call);
        if (c.exists(try host.agentPlist(c, label))) {
            try host.restartAgent(c, label);
            try waitFor(c, c.env.get("CLIPROXY_LOCAL_URL") orelse "http://127.0.0.1:8317", k);
            return c.result("cliproxyapi restart", "CLIProxyAPI restarted.");
        }
        const target = try sshHost(c, call, origin);
        try c.log("Restarting CLIProxyAPI on {s}...", .{target});
        _ = try host.runEc(c, target, "cliproxyapi", "restart", 90);
        try waitFor(c, origin, k);
        return c.result("cliproxyapi restart", try c.fmt("CLIProxyAPI restarted on {s} and answers at {s}.", .{ target, origin }));
    }
};
fn modelsUrl(c: *C, origin: []const u8) ![]const u8 {
    return c.fmt("{s}/models", .{try contribution.openaiUrl(c.a, origin)});
}
fn sshHost(c: *C, call: Call, origin: []const u8) ![]const u8 {
    if (call.setting("host")) |h| {
        if (!core.validHost(h, true)) return c.fail("Invalid host {s}. Use HOST or USER@HOST.", .{h});
        return h;
    }
    const after_scheme = origin[std.mem.indexOf(u8, origin, "://").? + 3 ..];
    const h = after_scheme[0 .. std.mem.indexOfAny(u8, after_scheme, ":/") orelse after_scheme.len];
    if (!core.validHost(h, false)) return c.fail("Invalid CLIProxyAPI host {s}. Set host under [plugins.cliproxyapi].", .{h});
    return h;
}
fn waitFor(c: *C, origin: []const u8, k: []const u8) !void {
    const limit = try host.envSeconds(c, "CLIPROXY_RESTART_TIMEOUT", 30);
    if (!try host.waitOk(c, try modelsUrl(c, origin), k, limit)) return c.failCode(.@"unreachable", "CLIProxyAPI did not answer at {s} within {d}s after restarting. Check ~/.local/share/cliproxyapi/logs on the host.", .{ origin, limit });
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
