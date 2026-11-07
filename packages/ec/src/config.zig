const std = @import("std");
const toml = @import("toml");
const core = @import("core.zig");
const C = core.Context;

// zig-toml builds each table with an allocator that points at an arena in parseString's stack
// frame, then returns a copy of that arena. Adding a key to such a table can allocate through the
// dead pointer and crash, so parse points every table at a, which must be an arena.
fn parse(a: std.mem.Allocator, text: []const u8) !*toml.Table {
    var parser = toml.Parser(toml.Table).init(a);
    defer parser.deinit();
    const root = try a.create(toml.Table);
    root.* = (try parser.parseString(text)).value;
    rebind(.{ .table = root }, a);
    return root;
}
fn rebind(v: toml.Value, a: std.mem.Allocator) void {
    switch (v) {
        .table => |t| {
            t.allocator = a;
            var it = t.valueIterator();
            while (it.next()) |child| rebind(child.*, a);
        },
        .array => |list| for (list.items) |item| rebind(item, a),
        else => {},
    }
}
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
const plugin = @import("plugin.zig");
// What ec added on the last sync, so it can remove entries a disabled plugin left behind.
pub const Managed = struct { mcp_servers: []const []const u8 = &.{}, provider: ?[]const u8 = null, models: []const []const u8 = &.{}, claude_hooks: []const []const u8 = &.{} };
const header_keys = [_][]const u8{ "bearer_token_env_var", "bearer_token_file", "env_http_headers", "http_headers", "headers" };
const model_auth_keys = [_][]const u8{ "api_base_url", "env_key", "auth_provider", "model_provider", "extra_headers", "env_http_headers", "query_params", "mtls_cert_dir", "base_url", "api_key", "api_backend" };
pub fn configure(a: std.mem.Allocator, current: []const u8, agent: enum { codex, grok }, contrib: plugin.Contributions, previous: Managed) ![]const u8 {
    const alloc = a;
    const root = try parse(a, current);
    if (root.get("mcp_servers")) |v| if (v == .table) {
        for (previous.mcp_servers) |name| if (!contributes(contrib, name)) {
            _ = v.table.remove(name);
        };
    };
    // Keep local choices such as enabled, but replace the endpoint and every way to send a token.
    for (contrib.mcp_servers) |m| {
        const server = try table(alloc, try table(alloc, root, "mcp_servers"), m.name);
        for (header_keys) |old| _ = server.remove(old);
        try server.put("url", .{ .string = m.url });
        if (m.headers.len > 0) {
            const headers = try table(alloc, server, if (agent == .codex) "http_headers" else "headers");
            for (m.headers) |h| try headers.put(h.name, .{ .string = h.value });
        }
    }
    if (previous.provider) |old| if (contrib.provider == null or !std.mem.eql(u8, contrib.provider.?.id, old)) {
        if (agent == .codex) {
            if (root.get("model_provider")) |mp| if (mp == .string and std.mem.eql(u8, mp.string, old)) {
                _ = root.remove("model_provider");
            };
            if (root.get("model_providers")) |mps| if (mps == .table) {
                _ = mps.table.remove(old);
            };
        } else {
            // Remove the model entries ec added; keep any the user extended with other keys.
            if (root.get("model")) |catalog| if (catalog == .table) {
                for (previous.models) |id| if (catalog.table.get(id)) |model| if (model == .table) {
                    for (model_auth_keys) |k| _ = model.table.remove(k);
                    const only_name = model.table.count() == 0 or (model.table.count() == 1 and model.table.get("model") != null);
                    if (only_name) _ = catalog.table.remove(id);
                };
            };
            if (root.get("models")) |models| if (models == .table) if (models.table.get("default")) |d| if (d == .string) {
                for (previous.models) |id| if (std.mem.eql(u8, d.string, id)) {
                    if (root.get("model")) |catalog| if (catalog == .table and catalog.table.get(id) != null) break;
                    _ = models.table.remove("default");
                    break;
                };
            };
        }
    };
    if (contrib.provider) |pr| {
        const url = try std.fmt.allocPrint(alloc, "{s}/v1", .{pr.base_url});
        if (agent == .codex) {
            try root.put("model_provider", .{ .string = pr.id });
            const providers = try table(alloc, root, "model_providers");
            _ = providers.remove(pr.id);
            const provider = try table(alloc, providers, pr.id);
            try provider.put("name", .{ .string = pr.name });
            try provider.put("base_url", .{ .string = url });
            try provider.put("wire_api", .{ .string = "responses" });
            try provider.put("experimental_bearer_token", .{ .string = pr.api_key });
            try provider.put("requires_openai_auth", .{ .boolean = false });
        } else if (pr.models.len > 0) {
            const models = try table(alloc, root, "models");
            if (models.get("default") == null) try models.put("default", .{ .string = pr.models[0] });
            const catalog = try table(alloc, root, "model");
            for (pr.models) |id| {
                const model = try table(alloc, catalog, id);
                for (model_auth_keys) |old| _ = model.remove(old);
                try model.put("model", .{ .string = id });
                try model.put("base_url", .{ .string = url });
                try model.put("api_key", .{ .string = pr.api_key });
                try model.put("api_backend", .{ .string = "responses" });
            }
        }
    }
    // Always rewrite, so files from older ec builds lose their inline tables.
    return serialize(a, root);
}
fn contributes(contrib: plugin.Contributions, name: []const u8) bool {
    for (contrib.mcp_servers) |m| if (std.mem.eql(u8, m.name, name)) return true;
    return false;
}
fn statePath(c: *C) ![]const u8 {
    return c.path(&.{ c.home, ".config/ender-chest/state.json" });
}
pub fn loadManaged(c: *C) !Managed {
    const text = try c.optional(try statePath(c)) orelse return .{};
    const v = c.parse(text) catch return .{};
    var m: Managed = .{ .provider = core.string(v, "provider") };
    var names: std.ArrayList([]const u8) = .empty;
    for (core.array(v, "mcp_servers")) |item| if (item == .string) try names.append(c.a, item.string);
    m.mcp_servers = names.items;
    var models: std.ArrayList([]const u8) = .empty;
    for (core.array(v, "models")) |item| if (item == .string) try models.append(c.a, item.string);
    m.models = models.items;
    var hooks: std.ArrayList([]const u8) = .empty;
    for (core.array(v, "claude_hooks")) |item| if (item == .string) try hooks.append(c.a, item.string);
    m.claude_hooks = hooks.items;
    return m;
}
fn saveManaged(c: *C, contrib: plugin.Contributions, claude_hooks: []const []const u8) !void {
    var v = c.object();
    if (claude_hooks.len > 0) {
        var hooks = std.json.Array.init(c.a);
        for (claude_hooks) |h| try hooks.append(.{ .string = h });
        try v.object.put(c.a, "claude_hooks", .{ .array = hooks });
    }
    var names = std.json.Array.init(c.a);
    for (contrib.mcp_servers) |m| try names.append(.{ .string = m.name });
    try v.object.put(c.a, "mcp_servers", .{ .array = names });
    if (contrib.provider) |pr| {
        try v.object.put(c.a, "provider", .{ .string = pr.id });
        var models = std.json.Array.init(c.a);
        for (pr.models) |id| try models.append(.{ .string = id });
        try v.object.put(c.a, "models", .{ .array = models });
    }
    try c.writeJson(try statePath(c), v, 0o600);
}

// Portable hook groups join the ones already in ~/.claude/settings.json, such as hooks other
// tools install. Groups this config added on an earlier sync are replaced, so editing or
// removing one in the repo carries over instead of leaving a stale copy.
fn mergeHooks(c: *C, local: ?std.json.Value, portable: std.json.Value, previous: []const []const u8) !struct { hooks: std.json.Value, applied: []const []const u8 } {
    if (portable != .object) return error.ExpectedObject;
    var applied: std.ArrayList([]const u8) = .empty;
    var pit = portable.object.iterator();
    while (pit.next()) |entry| {
        if (entry.value_ptr.* != .array) return error.ExpectedArray;
        for (entry.value_ptr.array.items) |group| try applied.append(c.a, try std.json.Stringify.valueAlloc(c.a, group, .{}));
    }
    var hooks = local orelse c.object();
    if (hooks != .object) return error.ExpectedObject;
    // Events whose only groups came from this config are dropped unless the config still adds one.
    var emptied: std.ArrayList([]const u8) = .empty;
    var lit = hooks.object.iterator();
    while (lit.next()) |entry| {
        if (entry.value_ptr.* != .array) continue;
        var kept = std.json.Array.init(c.a);
        for (entry.value_ptr.array.items) |group| {
            const text = try std.json.Stringify.valueAlloc(c.a, group, .{});
            if (!contains(previous, text) and !contains(applied.items, text)) try kept.append(group);
        }
        if (kept.items.len == 0 and entry.value_ptr.array.items.len > 0) try emptied.append(c.a, entry.key_ptr.*);
        entry.value_ptr.* = .{ .array = kept };
    }
    pit = portable.object.iterator();
    while (pit.next()) |entry| {
        var groups = if (hooks.object.get(entry.key_ptr.*)) |v| if (v == .array) v.array else std.json.Array.init(c.a) else std.json.Array.init(c.a);
        try groups.appendSlice(entry.value_ptr.array.items);
        try hooks.object.put(c.a, entry.key_ptr.*, .{ .array = groups });
    }
    for (emptied.items) |k| if (hooks.object.get(k).?.array.items.len == 0) {
        _ = hooks.object.orderedRemove(k);
    };
    return .{ .hooks = hooks, .applied = applied.items };
}
fn contains(list: []const []const u8, text: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, text)) return true;
    return false;
}

pub fn apply(c: *C, contrib: plugin.Contributions) !void {
    const previous = try loadManaged(c);
    const instructions = try c.read(try c.path(&.{ c.repo, "agents/shared/AGENTS.md" }));
    for ([_][]const u8{ ".claude/CLAUDE.md", ".codex/AGENTS.md", ".grok/AGENTS.md" }) |rel| try c.write(try c.path(&.{ c.home, rel }), try c.fmt("{s}\n", .{core.trim(instructions)}), 0o644);
    const dest = try c.path(&.{ c.home, ".claude/settings.json" });
    var settings = if (try c.optional(dest)) |data| try c.parse(data) else c.object();
    if (settings != .object) return error.ExpectedObject;
    var env = settings.object.get("env") orelse c.object();
    if (env != .object) return error.ExpectedObject;
    const portable = try c.readJson(try c.path(&.{ c.repo, "agents/claude/settings.json" }));
    var applied_hooks: []const []const u8 = &.{};
    var it = portable.object.iterator();
    while (it.next()) |entry| {
        if (core.eql(u8, entry.key_ptr.*, "hooks")) {
            const merged = try mergeHooks(c, settings.object.get("hooks"), entry.value_ptr.*, previous.claude_hooks);
            try settings.object.put(c.a, "hooks", merged.hooks);
            applied_hooks = merged.applied;
        } else if (core.eql(u8, entry.key_ptr.*, "env")) {
            if (entry.value_ptr.* != .object) return error.ExpectedObject;
            var eit = entry.value_ptr.object.iterator();
            while (eit.next()) |e| try env.object.put(c.a, e.key_ptr.*, e.value_ptr.*);
        } else try settings.object.put(c.a, entry.key_ptr.*, entry.value_ptr.*);
    }
    if (portable.object.get("hooks") == null and previous.claude_hooks.len > 0) {
        if (settings.object.get("hooks")) |local| try settings.object.put(c.a, "hooks", (try mergeHooks(c, local, c.object(), previous.claude_hooks)).hooks);
    }
    if (contrib.provider) |pr| {
        try env.object.put(c.a, "ANTHROPIC_BASE_URL", .{ .string = pr.base_url });
        try env.object.put(c.a, "ANTHROPIC_AUTH_TOKEN", .{ .string = pr.api_key });
        try env.object.put(c.a, "ANTHROPIC_API_KEY", .{ .string = "" });
    } else if (previous.provider != null) {
        for ([_][]const u8{ "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY" }) |k| _ = env.object.orderedRemove(k);
    }
    try settings.object.put(c.a, "env", env);
    try c.writeJson(dest, settings, 0o600);

    const claude_file = try c.path(&.{ c.home, ".claude.json" });
    var claude = if (try c.optional(claude_file)) |data| try c.parse(data) else c.object();
    if (claude != .object) return error.ExpectedObject;
    var servers = claude.object.get("mcpServers") orelse c.object();
    if (servers == .null) servers = c.object();
    if (servers != .object) return error.ExpectedObject;
    var changed = false;
    for (previous.mcp_servers) |name| if (!contributes(contrib, name) and servers.object.orderedRemove(name)) {
        changed = true;
    };
    for (contrib.mcp_servers) |m| {
        // Keep local keys such as timeout; replace the endpoint and headers.
        var server = c.object();
        if (servers.object.get(m.name)) |old| if (old == .object) {
            var oit = old.object.iterator();
            while (oit.next()) |e| if (!core.eql(u8, e.key_ptr.*, "headers")) try server.object.put(c.a, e.key_ptr.*, e.value_ptr.*);
        };
        try server.object.put(c.a, "type", .{ .string = "http" });
        try server.object.put(c.a, "url", .{ .string = m.url });
        if (m.headers.len > 0) {
            var headers = c.object();
            for (m.headers) |h| try headers.object.put(c.a, h.name, .{ .string = h.value });
            try server.object.put(c.a, "headers", headers);
        }
        const before = if (servers.object.get(m.name)) |old| try std.json.Stringify.valueAlloc(c.a, old, .{}) else "";
        if (!core.eql(u8, before, try std.json.Stringify.valueAlloc(c.a, server, .{}))) changed = true;
        try servers.object.put(c.a, m.name, server);
    }
    // Rewrite only on change. Claude Code rewrites this file while it runs.
    if (changed) {
        try claude.object.put(c.a, "mcpServers", servers);
        try c.writeJson(claude_file, claude, 0o600);
    }
    inline for (.{ "codex", "grok" }) |agent| {
        const file = try c.path(&.{ c.home, "." ++ agent ++ "/config.toml" });
        const current = try c.optional(file) orelse try c.read(try c.path(&.{ c.repo, "agents/" ++ agent ++ "/config.toml" }));
        const next = configure(c.a, current, if (comptime core.eql(u8, agent, "codex")) .codex else .grok, contrib, previous) catch return c.fail("Cannot merge {s}. Check its TOML syntax and table types; the file was left intact.", .{file});
        try c.write(file, next, 0o600);
    }
    try saveManaged(c, contrib, applied_hooks);
}
fn clobberStack() void {
    var junk: [64 * 1024]u8 = undefined;
    @memset(&junk, 0xaa);
    std.mem.doNotOptimizeAway(&junk);
}
test "parsed tables can grow after the parser's stack frame is reused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), "[mcp_servers.local]\nurl = 'https://example.test'\n[[list]]\nname = 'x'\n");
    clobberStack();
    const nested = root.get("list").?.array.items[0].table;
    for (0..64) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "k{d}", .{i});
        try root.put(key, .{ .integer = @intCast(i) });
        try root.get("mcp_servers").?.table.put(key, .{ .integer = 1 });
        try nested.put(key, .{ .integer = 1 });
    }
    try std.testing.expectEqual(@as(u32, 66), root.count());
}
test "TOML merge preserves quoted local keys and replaces stale provider auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = "model = 'personal'\n[projects.\"/work/example\"]\ntrust_level = 'trusted'\n[model_providers.cliproxyapi]\nenv_key = 'OLD_KEY'\n";
    const contrib: plugin.Contributions = .{ .mcp_servers = &.{.{ .name = "executor", .url = "https://example.test/mcp", .headers = &.{.{ .name = "Authorization", .value = "Bearer k" }} }}, .provider = .{ .id = "cliproxyapi", .name = "CLIProxyAPI", .base_url = "http://proxy.test", .api_key = "test-key" } };
    const next = try configure(a, current, .codex, contrib, .{});
    var parser = toml.Parser(toml.Table).init(a);
    const parsed = try parser.parseString(next);
    try std.testing.expectEqualStrings("personal", parsed.value.get("model").?.string);
    try std.testing.expectEqualStrings("trusted", parsed.value.get("projects").?.table.get("/work/example").?.table.get("trust_level").?.string);
    try std.testing.expect(std.mem.indexOf(u8, next, "OLD_KEY") == null);
    try std.testing.expectEqualStrings("Bearer k", parsed.value.get("mcp_servers").?.table.get("executor").?.table.get("http_headers").?.table.get("Authorization").?.string);
    try std.testing.expectEqualStrings(next, try configure(a, next, .codex, contrib, .{ .mcp_servers = &.{"executor"}, .provider = "cliproxyapi" }));
}
test "Grok keeps custom models and preferences but drops stale auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = "[models]\ndefault='grok-4.5'\n[model.\"grok-4.6\"]\ntemperature=0.3\nextra_headers={Authorization='old-secret'}\n[model.custom]\nmodel='mine'\n";
    const next = try configure(a, current, .grok, .{ .provider = .{ .id = "cliproxyapi", .name = "CLIProxyAPI", .base_url = "http://proxy", .api_key = "key", .models = &.{ "grok-4.7", "grok-4.6", "grok-4.5" } } }, .{});
    var parser = toml.Parser(toml.Table).init(a);
    const p = try parser.parseString(next);
    try std.testing.expectEqualStrings("grok-4.5", p.value.get("models").?.table.get("default").?.string);
    try std.testing.expectEqualStrings("mine", p.value.get("model").?.table.get("custom").?.table.get("model").?.string);
    try std.testing.expect(std.mem.indexOf(u8, next, "old-secret") == null);
    try std.testing.expectEqual(@as(f64, 0.3), p.value.get("model").?.table.get("grok-4.6").?.table.get("temperature").?.float);
}
test "disabling a plugin removes what ec added and keeps the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = "model_provider = 'cliproxyapi'\n[model_providers.cliproxyapi]\nbase_url = 'http://proxy/v1'\n[model_providers.mine]\nbase_url = 'http://mine'\n[mcp_servers.executor]\nurl = 'https://old/mcp'\n[mcp_servers.local]\ncommand = 'tool'\n";
    const next = try configure(a, current, .codex, .{}, .{ .mcp_servers = &.{"executor"}, .provider = "cliproxyapi" });
    var parser = toml.Parser(toml.Table).init(a);
    const p = try parser.parseString(next);
    try std.testing.expect(p.value.get("model_provider") == null);
    try std.testing.expect(p.value.get("model_providers").?.table.get("cliproxyapi") == null);
    try std.testing.expect(p.value.get("model_providers").?.table.get("mine") != null);
    try std.testing.expect(p.value.get("mcp_servers").?.table.get("executor") == null);
    try std.testing.expect(p.value.get("mcp_servers").?.table.get("local") != null);
}
test "disabling the provider removes the Grok models ec added and keeps customized ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = "[models]\ndefault = 'grok-4.7'\n[model.\"grok-4.7\"]\nmodel = 'grok-4.7'\nbase_url = 'http://proxy/v1'\napi_key = 'k'\n[model.\"grok-4.6\"]\nmodel = 'grok-4.6'\napi_key = 'k'\ntemperature = 0.3\n";
    const next = try configure(a, current, .grok, .{}, .{ .provider = "cliproxyapi", .models = &.{ "grok-4.7", "grok-4.6" } });
    var parser = toml.Parser(toml.Table).init(a);
    const p = try parser.parseString(next);
    const catalog = p.value.get("model").?.table;
    try std.testing.expect(catalog.get("grok-4.7") == null);
    try std.testing.expect(catalog.get("grok-4.6").?.table.get("api_key") == null);
    try std.testing.expectEqual(@as(f64, 0.3), catalog.get("grok-4.6").?.table.get("temperature").?.float);
    try std.testing.expect(p.value.get("models").?.table.get("default") == null);
    try std.testing.expect(std.mem.indexOf(u8, next, "http://proxy") == null);
}
