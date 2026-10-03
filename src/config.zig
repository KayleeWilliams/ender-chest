const std = @import("std");
const toml = @import("toml");
const core = @import("core.zig");
const C = core.Context;

fn table(a: std.mem.Allocator, parent: *toml.Table, key: []const u8) !*toml.Table {
    if (parent.get(key)) |v| {
        if (v != .table) return error.ExpectedTable;
        return v.table;
    }
    const t = try a.create(toml.Table);
    t.* = toml.Table.init(a);
    try parent.put(key, .{ .table = t });
    return t;
}
fn quote(w: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, w);
}
// Orca finds Codex project and hook entries by matching bare [projects. and [hooks.state. headers.
// A quoted ["projects"] header hides an existing entry, so Orca appends a duplicate table.
fn writeKey(w: *std.Io.Writer, text: []const u8) !void {
    if (text.len == 0) return quote(w, text);
    for (text) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return quote(w, text);
    }
    try w.writeAll(text);
}
// Tables inside arrays stay inline; serialize writes every other table as a [section].
fn value(w: *std.Io.Writer, v: toml.Value, a: std.mem.Allocator) anyerror!void {
    switch (v) {
        .string => |s| try quote(w, s),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |n| {
            if (std.math.isNan(n)) try w.writeAll("nan") else if (std.math.isInf(n)) try w.writeAll(if (n < 0) "-inf" else "inf") else {
                const s = try std.fmt.allocPrint(a, "{d}", .{n});
                try w.writeAll(s);
                if (std.mem.indexOfAny(u8, s, ".eE") == null) try w.writeAll(".0");
            }
        },
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |v2, i| {
                if (i > 0) try w.writeAll(", ");
                try value(w, v2, a);
            }
            try w.writeByte(']');
        },
        .table => |t| {
            try w.writeAll("{ ");
            const keys = try sortedKeys(a, t);
            for (keys, 0..) |k, i| {
                if (i > 0) try w.writeAll(", ");
                try writeKey(w, k);
                try w.writeAll(" = ");
                try value(w, t.get(k).?, a);
            }
            try w.writeAll(" }");
        },
        .date => |d| try date(w, d),
        .time => |t| try time(w, t),
        .datetime => |d| {
            try date(w, d.date);
            try w.writeByte('T');
            try time(w, d.time);
            if (d.offset_minutes) |offset| {
                if (offset == 0) try w.writeByte('Z') else {
                    const abs = @abs(offset);
                    try w.print("{s}{d:0>2}:{d:0>2}", .{ if (offset < 0) "-" else "+", abs / 60, abs % 60 });
                }
            }
        },
    }
}
fn date(w: *std.Io.Writer, d: toml.Date) !void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
}
fn time(w: *std.Io.Writer, t: toml.Time) !void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    if (t.nanosecond != 0) try w.print(".{d:0>9}", .{t.nanosecond});
}
fn sortedKeys(a: std.mem.Allocator, t: *const toml.Table) ![][]const u8 {
    const keys = try a.alloc([]const u8, t.count());
    var it = t.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) keys[i] = k.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return keys;
}
// Codex and Grok append [section] headers when they save settings. TOML forbids extending an
// inline table, so writing nested tables inline would let their next save corrupt the file.
fn section(out: *std.Io.Writer.Allocating, a: std.mem.Allocator, path: []const u8, t: *const toml.Table) !void {
    const keys = try sortedKeys(a, t);
    var leaves: usize = 0;
    for (keys) |k| {
        if (t.get(k).? != .table) leaves += 1;
    }
    if (path.len > 0 and (leaves > 0 or keys.len == 0)) {
        if (out.written().len > 0) try out.writer.writeByte('\n');
        try out.writer.print("[{s}]\n", .{path});
    }
    for (keys) |k| {
        const v = t.get(k).?;
        if (v == .table) continue;
        try writeKey(&out.writer, k);
        try out.writer.writeAll(" = ");
        try value(&out.writer, v, a);
        try out.writer.writeByte('\n');
    }
    for (keys) |k| {
        const v = t.get(k).?;
        if (v != .table) continue;
        var name: std.Io.Writer.Allocating = .init(a);
        if (path.len > 0) try name.writer.print("{s}.", .{path});
        try writeKey(&name.writer, k);
        try section(out, a, name.written(), v.table);
    }
}
pub fn serialize(a: std.mem.Allocator, t: *const toml.Table) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try section(&out, a, "", t);
    return out.toOwnedSlice();
}
pub fn configure(a: std.mem.Allocator, current: []const u8, agent: enum { codex, grok }, base: []const u8, key: []const u8, mcp: []const u8) ![]const u8 {
    var parser = toml.Parser(toml.Table).init(a);
    defer parser.deinit();
    var parsed = try parser.parseString(current);
    defer parsed.deinit();
    const alloc = parsed.arena.allocator();
    const root = &parsed.value;
    const servers = try table(alloc, root, "mcp_servers");
    if (servers.get("executor") == null) executor_setup: {
        var shared = try parser.parseString(mcp);
        defer shared.deinit();
        const shared_servers = shared.value.get("mcp_servers") orelse break :executor_setup;
        if (shared_servers != .table) return error.MissingExecutor;
        const executor = shared_servers.table.get("executor") orelse break :executor_setup;
        // Serialize and reparse into the root arena before the shared arena is freed.
        var clone_parser = toml.Parser(toml.Table).init(alloc);
        const clone = try clone_parser.parseString(try std.fmt.allocPrint(alloc, "executor = {s}\n", .{blk: {
            var out: std.Io.Writer.Allocating = .init(alloc);
            try value(&out.writer, executor, alloc);
            break :blk try out.toOwnedSlice();
        }}));
        try servers.put("executor", clone.value.get("executor").?);
    }
    if (key.len == 0) return serialize(a, root);
    const url = try std.fmt.allocPrint(alloc, "{s}/v1", .{base});
    if (agent == .codex) {
        try root.put("model_provider", .{ .string = "cliproxyapi" });
        const providers = try table(alloc, root, "model_providers");
        _ = providers.remove("cliproxyapi");
        const provider = try table(alloc, providers, "cliproxyapi");
        try provider.put("name", .{ .string = "CLIProxyAPI" });
        try provider.put("base_url", .{ .string = url });
        try provider.put("wire_api", .{ .string = "responses" });
        try provider.put("experimental_bearer_token", .{ .string = key });
        try provider.put("requires_openai_auth", .{ .boolean = false });
    } else {
        const models = try table(alloc, root, "models");
        if (models.get("default") == null) try models.put("default", .{ .string = "grok-4.6" });
        const catalog = try table(alloc, root, "model");
        for ([_][]const u8{ "grok-4.7", "grok-4.6", "grok-4.5" }) |id| {
            const model = try table(alloc, catalog, id);
            for ([_][]const u8{ "api_base_url", "env_key", "auth_provider", "model_provider", "extra_headers", "env_http_headers", "query_params", "mtls_cert_dir" }) |old| {
                _ = model.remove(old);
            }
            try model.put("model", .{ .string = id });
            try model.put("base_url", .{ .string = url });
            try model.put("api_key", .{ .string = key });
            try model.put("api_backend", .{ .string = "responses" });
        }
    }
    // Always rewrite, so files from older ec builds lose their inline tables.
    return serialize(a, root);
}
pub fn hasSharedExecutor(c: *C) !bool {
    const text = try c.read(try c.path(&.{ c.repo, "agents/shared/mcp.toml" }));
    var parser = toml.Parser(toml.Table).init(c.a);
    defer parser.deinit();
    var parsed = try parser.parseString(text);
    defer parsed.deinit();
    const servers = parsed.value.get("mcp_servers") orelse return false;
    return servers == .table and servers.table.get("executor") != null;
}

pub fn apply(c: *C) !void {
    const instructions = try c.read(try c.path(&.{ c.repo, "agents/shared/AGENTS.md" }));
    for ([_][]const u8{ ".claude/CLAUDE.md", ".codex/AGENTS.md", ".grok/AGENTS.md" }) |rel| try c.write(try c.path(&.{ c.home, rel }), try c.fmt("{s}\n", .{core.trim(instructions)}), 0o644);
    const credentials = @import("credentials.zig");
    const base = try credentials.endpoint(c, try c.path(&.{ c.home, credentials.endpoint_path }));
    const key = try credentials.loadKey(c) orelse "";
    if (key.len == 0) try c.log("No local proxy token; preserving agent authentication. Run ec cliproxy setup, then ec sync.", .{});
    const mcp = try c.read(try c.path(&.{ c.repo, "agents/shared/mcp.toml" }));
    const dest = try c.path(&.{ c.home, ".claude/settings.json" });
    var settings = if (try c.optional(dest)) |data| try c.parse(data) else c.object();
    if (settings != .object) return error.ExpectedObject;
    var env = settings.object.get("env") orelse c.object();
    if (env != .object) return error.ExpectedObject;
    const portable = try c.readJson(try c.path(&.{ c.repo, "agents/claude/settings.json" }));
    var it = portable.object.iterator();
    while (it.next()) |entry| {
        if (core.eql(u8, entry.key_ptr.*, "env")) {
            if (entry.value_ptr.* != .object) return error.ExpectedObject;
            var eit = entry.value_ptr.object.iterator();
            while (eit.next()) |e| try env.object.put(c.a, e.key_ptr.*, e.value_ptr.*);
        } else try settings.object.put(c.a, entry.key_ptr.*, entry.value_ptr.*);
    }
    if (key.len > 0) {
        try env.object.put(c.a, "ANTHROPIC_BASE_URL", .{ .string = base });
        try env.object.put(c.a, "ANTHROPIC_AUTH_TOKEN", .{ .string = key });
        try env.object.put(c.a, "ANTHROPIC_API_KEY", .{ .string = "" });
    }
    try settings.object.put(c.a, "env", env);
    try c.writeJson(dest, settings, 0o600);
    const claude_file = try c.path(&.{ c.home, ".claude.json" });
    var claude = if (try c.optional(claude_file)) |data| try c.parse(data) else c.object();
    if (claude != .object) return error.ExpectedObject;
    var servers = claude.object.get("mcpServers") orelse c.object();
    if (servers == .null) servers = c.object();
    if (servers != .object) return error.ExpectedObject;
    const executor = servers.object.get("executor");
    if (executor == null or executor.? != .object) executor_setup: {
        var parser = toml.Parser(toml.Table).init(c.a);
        const parsed = try parser.parseString(mcp);
        const s = parsed.value.get("mcp_servers") orelse break :executor_setup;
        if (s != .table) return error.MissingExecutor;
        const e = s.table.get("executor") orelse break :executor_setup;
        if (e != .table) return error.MissingExecutor;
        const url = e.table.get("url") orelse return error.MissingExecutor;
        if (url != .string) return error.MissingExecutor;
        var server = c.object();
        try server.object.put(c.a, "type", .{ .string = "http" });
        try server.object.put(c.a, "url", .{ .string = url.string });
        try servers.object.put(c.a, "executor", server);
        try claude.object.put(c.a, "mcpServers", servers);
        try c.writeJson(claude_file, claude, 0o600);
    }
    inline for (.{ "codex", "grok" }) |agent| {
        const file = try c.path(&.{ c.home, "." ++ agent ++ "/config.toml" });
        const current = try c.optional(file) orelse try c.read(try c.path(&.{ c.repo, "agents/" ++ agent ++ "/config.toml" }));
        const next = configure(c.a, current, if (comptime core.eql(u8, agent, "codex")) .codex else .grok, base, key, mcp) catch return c.fail("Cannot merge {s}. Check its TOML syntax and table types; the file was left intact.", .{file});
        try c.write(file, next, 0o600);
    }
}
test "TOML merge preserves quoted local keys and replaces stale provider auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = "model = 'personal'\n[projects.\"/work/example\"]\ntrust_level = 'trusted'\n[model_providers.cliproxyapi]\nenv_key = 'OLD_KEY'\n";
    const mcp = "[mcp_servers.executor]\nurl = 'https://example.test/mcp'\n";
    const next = try configure(a, current, .codex, "http://proxy.test", "test-key", mcp);
    var parser = toml.Parser(toml.Table).init(a);
    const parsed = try parser.parseString(next);
    try std.testing.expectEqualStrings("personal", parsed.value.get("model").?.string);
    try std.testing.expectEqualStrings("trusted", parsed.value.get("projects").?.table.get("/work/example").?.table.get("trust_level").?.string);
    try std.testing.expect(std.mem.indexOf(u8, next, "OLD_KEY") == null);
    try std.testing.expectEqualStrings(next, try configure(a, next, .codex, "http://proxy.test", "test-key", mcp));
}
test "Grok keeps custom models and preferences but drops stale auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = "[models]\ndefault='grok-4.5'\n[model.\"grok-4.6\"]\ntemperature=0.3\nextra_headers={Authorization='old-secret'}\n[model.custom]\nmodel='mine'\n";
    const next = try configure(a, current, .grok, "http://proxy", "key", "[mcp_servers.executor]\nurl='http://mcp'\n");
    var parser = toml.Parser(toml.Table).init(a);
    const p = try parser.parseString(next);
    try std.testing.expectEqualStrings("grok-4.5", p.value.get("models").?.table.get("default").?.string);
    try std.testing.expectEqualStrings("mine", p.value.get("model").?.table.get("custom").?.table.get("model").?.string);
    try std.testing.expect(std.mem.indexOf(u8, next, "old-secret") == null);
    try std.testing.expectEqual(@as(f64, 0.3), p.value.get("model").?.table.get("grok-4.6").?.table.get("temperature").?.float);
}
