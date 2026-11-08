// The coding agents ec configures. Each entry says where an agent keeps its instructions, settings,
// skills, and MCP servers, and how plugin contributions reach them. docs/config.md lists the same.
const std = @import("std");
const core = @import("core.zig");
const paths = @import("paths.zig");
const toml_doc = @import("toml_doc.zig");
const json_merge = @import("json_merge.zig");
const contribution = @import("contributions.zig");
const files = @import("files.zig");
const C = core.Context;
const Value = std.json.Value;
const Table = toml_doc.Table;
const Place = paths.Place;
const Contributions = contribution.Contributions;
const Provider = contribution.Provider;
const Added = json_merge.Added;
const eq = core.eql;

pub const Agent = struct {
    // Names agents/<name>/ in the checkout and the agent's entry in state.json.
    name: []const u8,
    // Sync writes an agent's files only when this directory exists, so agents a machine
    // doesn't have installed stay off it.
    dir: Place,
    // Null for Cursor, whose global rules live only in its app.
    instructions: ?Place,
    // The checkout's copy is agents/<name>/ plus this file's name.
    settings: Place,
    // Agents that read only ~/.agents/skills have no directory of their own to link.
    skills: ?Place = null,
    // Codex and Grok save their own TOML, so the checkout's copy only seeds a missing file.
    // Merging it on every sync would undo the user's edits.
    seed_once: bool = false,
    format: Format,
};
const Format = union(enum) { json: Json, toml: Schema };
// How a JSON settings file takes the checkout's settings and MCP servers.
const Json = struct {
    mcp: ?JsonMcp = null,
    // A top-level key the agent requires, set to 1 when missing.
    version: ?[]const u8 = null,
    // A shape that means ec must leave the file alone.
    conflict: ?Conflict = null,
    // Claude Code reaches a model provider through ANTHROPIC_* variables in env.
    anthropic_env: bool = false,
    legacy_hooks: bool = false,
};
const JsonMcp = struct {
    // Null when the servers live in the settings file.
    file: ?Place = null,
    // The key path of the object that holds one entry per server.
    key: []const []const u8 = &.{"mcpServers"},
    url: []const u8 = "url",
    type: ?[]const u8 = null,
    // Keys each entry sets to false.
    off: []const []const u8 = &.{},
};
// The value at `path` conflicts when present, or, with `except`, when it holds any other key.
const Conflict = struct { path: []const []const u8, except: ?[]const u8 = null };

// Claude Code also installs skills into its own directory; sync moves them to the shared one.
pub const claude: Agent = .{
    .name = "claude",
    .dir = .{ .home = ".claude" },
    .instructions = .{ .home = ".claude/CLAUDE.md" },
    .settings = .{ .home = ".claude/settings.json" },
    .skills = .{ .home = ".claude/skills" },
    .format = .{ .json = .{ .mcp = .{ .file = .{ .home = ".claude.json" }, .type = "http" }, .anthropic_env = true, .legacy_hooks = true } },
};
pub const all = [_]Agent{
    claude,
    .{ .name = "codex", .dir = .{ .home = ".codex" }, .instructions = .{ .home = ".codex/AGENTS.md" }, .settings = .{ .home = ".codex/config.toml" }, .skills = .{ .home = ".codex/skills" }, .seed_once = true, .format = .{ .toml = codex } },
    .{ .name = "grok", .dir = .{ .home = ".grok" }, .instructions = .{ .home = ".grok/AGENTS.md" }, .settings = .{ .home = ".grok/config.toml" }, .skills = .{ .home = ".grok/skills" }, .seed_once = true, .format = .{ .toml = grok } },
    .{
        .name = "cursor",
        .dir = .{ .home = ".cursor" },
        .instructions = null,
        .settings = .{ .home = ".cursor/cli-config.json", .xdg = "cursor/cli-config.json" },
        .format = .{ .json = .{ .mcp = .{ .file = .{ .home = ".cursor/mcp.json" } }, .version = "version" } },
    },
    .{
        .name = "muse",
        .dir = .{ .home = ".config/muse", .xdg = "muse" },
        .instructions = .{ .home = ".config/muse/AGENTS.md", .xdg = "muse/AGENTS.md" },
        .settings = .{ .home = ".config/muse/settings.json", .xdg = "muse/settings.json" },
        // Muse turns MCP off when a file has both its legacy mcp_servers key and mcpServers.
        .format = .{ .json = .{ .mcp = .{ .type = "streamable-http" }, .version = "schema_version", .conflict = .{ .path = &.{"mcp_servers"} } } },
    },
    .{
        .name = "gemini",
        .dir = .{ .home = ".gemini" },
        .instructions = .{ .home = ".gemini/GEMINI.md" },
        .settings = .{ .home = ".gemini/settings.json" },
        .format = .{ .json = .{ .mcp = .{ .url = "httpUrl" } } },
    },
    .{
        .name = "opencode",
        .dir = .{ .home = ".config/opencode", .xdg = "opencode" },
        .instructions = .{ .home = ".config/opencode/AGENTS.md", .xdg = "opencode/AGENTS.md" },
        .settings = .{ .home = ".config/opencode/opencode.json", .xdg = "opencode/opencode.json" },
        // OpenCode 2's shape. Servers directly under mcp are OpenCode 1's; ec leaves such a file
        // alone. oauth = false stops OpenCode from trying OAuth before the header.
        .format = .{ .json = .{
            .mcp = .{ .key = &.{ "mcp", "servers" }, .type = "remote", .off = &.{"oauth"} },
            .conflict = .{ .path = &.{"mcp"}, .except = "servers" },
        } },
    },
};

pub fn active(c: *C, agent: Agent) !bool {
    return c.exists(try agent.dir.resolve(c));
}
// The skill directories of agents that keep their own: those in use, or every one for removal.
pub fn skillDirs(c: *C, only_active: bool) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (all) |agent| if (agent.skills) |place| {
        if (only_active and !try active(c, agent)) continue;
        try out.append(c.a, try place.resolve(c));
    };
    return out.items;
}

pub fn apply(c: *C, contrib: Contributions) !void {
    const previous = try loadState(c);
    const instructions = try c.read(try paths.inRepo(c, paths.instructions));
    const text = try c.fmt("{s}\n", .{core.trim(instructions)});
    var next: State = .{ .provider = if (contrib.provider) |pr| pr.id else null, .models = if (contrib.provider) |pr| pr.models else null };
    var servers: std.ArrayList([]const u8) = .empty;
    for (contrib.mcp_servers) |m| try servers.append(c.a, m.name);
    next.mcp_servers = servers.items;
    var merged: std.json.ArrayHashMap([]const Added) = .{};
    for (all) |agent| {
        if (!try active(c, agent)) continue;
        if (agent.instructions) |place| try files.writeAt(c, try place.resolve(c), text, 0o644);
        const s = try settings(c, agent, previous);
        const added = switch (agent.format) {
            .json => |spec| try writeJson(c, s, spec, contrib, previous),
            .toml => |schema| try writeToml(c, s, schema, contrib, previous),
        };
        if (added.len > 0) try merged.map.put(c.a, agent.name, added);
    }
    if (merged.map.count() > 0) next.settings = merged;
    const json = try std.json.Stringify.valueAlloc(c.a, next, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    try c.write(try paths.inHome(c, paths.state_file), try c.fmt("{s}\n", .{json}), 0o600);
}
const Settings = struct { file: []const u8, local: ?[]const u8, portable_file: []const u8, portable: ?[]const u8, previous: []const Added };
fn settings(c: *C, agent: Agent, previous: State) !Settings {
    const file = try agent.settings.resolve(c);
    const local = try c.optional(file);
    const portable_file = try portablePath(c, agent);
    const portable = if (agent.seed_once and local != null) null else try c.optional(portable_file);
    return .{ .file = file, .local = local, .portable_file = portable_file, .portable = portable, .previous = previous.addedFor(agent.name) };
}
fn portablePath(c: *C, agent: Agent) ![]const u8 {
    return c.path(&.{ c.repo, paths.agents_dir, agent.name, std.fs.path.basename(agent.settings.home) });
}

pub fn verify(c: *C, contrib: Contributions, checks: *core.Checks) !void {
    for (all) |agent| {
        if (!try active(c, agent)) continue;
        if (agent.instructions) |place| try checks.file(c, try place.resolve(c));
        if (c.exists(try portablePath(c, agent))) try checks.file(c, try agent.settings.resolve(c));
        for (contrib.mcp_servers) |server| {
            const found = mcpUrl(c, agent, server.name) catch |err| switch (err) {
                error.Unmanaged => break,
                else => null,
            };
            if (found == null or !eq(u8, found.?.url orelse "", server.url)) try checks.fail(c, "MCP server {s} is missing or stale in {s}. Run ec sync.", .{ server.name, if (found) |f| f.file else try agent.settings.resolve(c) });
        }
    }
}
const Found = struct { file: []const u8, url: ?[]const u8 };
// error.Unmanaged: ec adds no servers to this agent, or left its file alone.
fn mcpUrl(c: *C, agent: Agent, server: []const u8) !Found {
    switch (agent.format) {
        .toml => {
            const file = try agent.settings.resolve(c);
            return .{ .file = file, .url = try tomlMcpUrl(c, file, server) };
        },
        .json => |spec| {
            const mcp = spec.mcp orelse return error.Unmanaged;
            const file = if (mcp.file) |place| try place.resolve(c) else try agent.settings.resolve(c);
            const doc = try readLocal(c, file, try c.optional(file), spec, false) orelse return error.Unmanaged;
            const servers = lookup(doc, mcp.key) orelse return .{ .file = file, .url = null };
            if (servers != .object) return .{ .file = file, .url = null };
            return .{ .file = file, .url = core.string(servers.object.get(server) orelse .null, mcp.url) };
        },
    }
}

// Paths under HOME that hold agent sessions or the credentials ec writes. Push never uploads them.
pub fn privatePaths(c: *C) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (all) |agent| {
        const dir = try c.fmt("{s}/", .{agent.dir.home});
        try out.append(c.a, dir);
        const mcp = switch (agent.format) {
            .json => |spec| if (spec.mcp) |m| m.file else null,
            .toml => null,
        };
        for ([_]?Place{ agent.settings, mcp }) |place| if (place) |p| if (!std.mem.startsWith(u8, p.home, dir)) try out.append(c.a, p.home);
    }
    return out.items;
}

fn writeJson(c: *C, s: Settings, spec: Json, contrib: Contributions, previous: State) ![]const Added {
    const separate = if (spec.mcp) |m| m.file else null;
    if (separate) |place| try writeMcpFile(c, try place.resolve(c), spec.mcp.?, contrib, previous);
    const same_file_mcp = spec.mcp != null and separate == null and contrib.mcp_servers.len > 0;
    const wanted = s.local != null or s.portable != null or same_file_mcp or (spec.anthropic_env and contrib.provider != null);
    if (!wanted) return &.{};
    const local = try readLocal(c, s.file, s.local, spec, true) orelse return &.{};
    const portable = try jsonObject(c, s.portable_file, s.portable);
    const legacy = if (spec.legacy_hooks) previous.claude_hooks orelse &.{} else &.{};
    const before = if (legacy.len > 0) try legacyHooks(c, local, s.previous, legacy) else s.previous;
    const merged = try json_merge.merge(c.a, local, portable, before);
    var result = merged.value;
    if (spec.version) |key| if (result.object.get(key) == null) try result.object.put(c.a, key, .{ .integer = 1 });
    if (spec.anthropic_env) try anthropicEnv(c, &result, s.file, contrib, previous);
    if (spec.mcp != null and separate == null) _ = try putServers(c, &result, s.file, spec.mcp.?, contrib, previous);
    try c.writeJson(s.file, result, 0o600);
    return merged.added;
}
fn anthropicEnv(c: *C, result: *Value, file: []const u8, contrib: Contributions, previous: State) !void {
    var env = result.object.get("env") orelse c.object();
    if (env != .object) return c.fail("env in {s} must be a JSON object.", .{file});
    if (contrib.provider) |pr| {
        try env.object.put(c.a, "ANTHROPIC_BASE_URL", .{ .string = pr.base_url });
        try env.object.put(c.a, "ANTHROPIC_AUTH_TOKEN", .{ .string = pr.api_key });
        try env.object.put(c.a, "ANTHROPIC_API_KEY", .{ .string = "" });
    } else if (previous.provider != null) {
        for ([_][]const u8{ "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY" }) |k| _ = env.object.orderedRemove(k);
    }
    try result.object.put(c.a, "env", env);
}
fn writeMcpFile(c: *C, file: []const u8, mcp: JsonMcp, contrib: Contributions, previous: State) !void {
    const text = try c.optional(file);
    if (text == null and contrib.mcp_servers.len == 0) return;
    var doc = try readLocal(c, file, text, null, true) orelse return;
    // Rewrite only on change. Claude Code rewrites ~/.claude.json while it runs.
    if (try putServers(c, &doc, file, mcp, contrib, previous)) try c.writeJson(file, doc, 0o600);
}
// Returns whether the servers changed. Local keys such as timeout stay; url and headers are replaced.
fn putServers(c: *C, doc: *Value, file: []const u8, mcp: JsonMcp, contrib: Contributions, previous: State) !bool {
    var servers = lookup(doc.*, mcp.key) orelse c.object();
    if (servers == .null) servers = c.object();
    if (servers != .object) return c.fail("{s} in {s} must be a JSON object.", .{ try std.mem.join(c.a, ".", mcp.key), file });
    var changed = false;
    for (previous.mcp_servers) |name| if (!contrib.hasServer(name) and servers.object.orderedRemove(name)) {
        changed = true;
    };
    for (contrib.mcp_servers) |m| {
        var server = c.object();
        if (servers.object.get(m.name)) |old| if (old == .object) {
            var it = old.object.iterator();
            while (it.next()) |e| if (!eq(u8, e.key_ptr.*, "headers")) try server.object.put(c.a, e.key_ptr.*, e.value_ptr.*);
        };
        if (mcp.type) |t| try server.object.put(c.a, "type", .{ .string = t });
        for (mcp.off) |k| try server.object.put(c.a, k, .{ .bool = false });
        try server.object.put(c.a, mcp.url, .{ .string = m.url });
        if (m.headers.len > 0) {
            var headers = c.object();
            for (m.headers) |h| try headers.object.put(c.a, h.name, .{ .string = h.value });
            try server.object.put(c.a, "headers", headers);
        }
        const before = if (servers.object.get(m.name)) |old| try std.json.Stringify.valueAlloc(c.a, old, .{}) else "";
        if (!eq(u8, before, try std.json.Stringify.valueAlloc(c.a, server, .{}))) changed = true;
        try servers.object.put(c.a, m.name, server);
    }
    if (changed) try setPath(c, doc, mcp.key, servers);
    return changed;
}
fn lookup(doc: Value, path: []const []const u8) ?Value {
    var v = doc;
    for (path) |k| {
        if (v != .object) return null;
        v = v.object.get(k) orelse return null;
    }
    return v;
}
fn setPath(c: *C, doc: *Value, path: []const []const u8, v: Value) !void {
    var parent = doc;
    for (path[0 .. path.len - 1]) |k| {
        const slot = try parent.object.getOrPut(c.a, k);
        if (!slot.found_existing or slot.value_ptr.* != .object) slot.value_ptr.* = c.object();
        parent = slot.value_ptr;
    }
    try parent.object.put(c.a, path[path.len - 1], v);
}
fn conflicts(doc: Value, conflict: Conflict) bool {
    const v = lookup(doc, conflict.path) orelse return false;
    const except = conflict.except orelse return true;
    if (v != .object) return true;
    for (v.object.keys()) |k| if (!eq(u8, k, except)) return true;
    return false;
}
// A machine's JSON file, or null when ec must leave it alone: it has comments (JSONC), a .jsonc
// sibling the agent reads instead, or MCP servers in an older format. `note` prints why.
fn readLocal(c: *C, file: []const u8, text: ?[]const u8, spec: ?Json, note: bool) !?Value {
    const jsonc = try c.fmt("{s}c", .{file});
    if (c.exists(jsonc)) {
        if (note) try c.log("note: left {s} alone because {s} exists. Add settings there by hand.", .{ file, jsonc });
        return null;
    }
    const t = text orelse return c.object();
    const v = c.parse(t) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (!json_merge.isJsonc(c.a, t)) return c.fail("{s} is not valid JSON.", .{file});
            if (note) try c.log("note: left {s} alone because it has comments. Add settings there by hand.", .{file});
            return null;
        },
    };
    if (v != .object) return c.fail("Expected a JSON object in {s}", .{file});
    const json = spec orelse return v;
    const conflict = json.conflict orelse return v;
    if (conflicts(v, conflict)) {
        const old = try std.mem.join(c.a, ".", conflict.path);
        const new = try std.mem.join(c.a, ".", json.mcp.?.key);
        if (note) try c.log("note: left {s} alone because it has MCP servers in {s}, an older format. Move them to {s}, then run ec sync.", .{ file, old, new });
        return null;
    }
    return v;
}
// state.json from ec builds before the general settings merge lists the hook groups it added
// without their event, so they count as added under every event. Remove after a release or two.
fn legacyHooks(c: *C, local: Value, previous: []const Added, groups: []const []const u8) ![]const Added {
    var out: std.ArrayList(Added) = .empty;
    try out.appendSlice(c.a, previous);
    const hooks = local.object.get("hooks") orelse return out.items;
    if (hooks != .object) return out.items;
    var it = hooks.object.iterator();
    while (it.next()) |e| try out.append(c.a, .{ .path = try c.a.dupe([]const u8, &.{ "hooks", e.key_ptr.* }), .entries = groups });
    return out.items;
}
fn jsonObject(c: *C, file: []const u8, text: ?[]const u8) !Value {
    return c.parseObject(file, text orelse return c.object());
}

// Codex and Grok: TOML settings. Both read MCP servers from mcp_servers.NAME and differ in the
// header table and in how a model provider is configured.
const Schema = struct {
    headers: []const u8,
    addProvider: *const fn (a: std.mem.Allocator, root: *Table, pr: Provider, url: []const u8) anyerror!void,
    dropProvider: *const fn (root: *Table, old: []const u8, models: []const []const u8) void,
};
const codex: Schema = .{ .headers = "http_headers", .addProvider = codexAdd, .dropProvider = codexDrop };
const grok: Schema = .{ .headers = "headers", .addProvider = grokAdd, .dropProvider = grokDrop };
fn writeToml(c: *C, s: Settings, schema: Schema, contrib: Contributions, previous: State) ![]const Added {
    if (s.local == null and s.portable == null and contrib.mcp_servers.len == 0 and contrib.provider == null) return &.{};
    const next = configure(c.a, s.local orelse s.portable orelse "", schema, contrib, previous) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return c.fail("Cannot merge {s}. Check its TOML syntax and table types; the file was left intact.", .{s.file}),
    };
    try c.write(s.file, next, 0o600);
    return &.{};
}
const header_keys = [_][]const u8{ "bearer_token_env_var", "bearer_token_file", "env_http_headers", "http_headers", "headers" };
const model_auth_keys = [_][]const u8{ "api_base_url", "env_key", "auth_provider", "model_provider", "extra_headers", "env_http_headers", "query_params", "mtls_cert_dir", "base_url", "api_key", "api_backend" };
fn configure(a: std.mem.Allocator, current: []const u8, schema: Schema, contrib: Contributions, previous: State) ![]const u8 {
    const root = try toml_doc.parse(a, current);
    if (root.get("mcp_servers")) |v| if (v == .table) {
        for (previous.mcp_servers) |name| if (!contrib.hasServer(name)) {
            _ = v.table.remove(name);
        };
    };
    for (contrib.mcp_servers) |m| {
        const server = try toml_doc.table(a, try toml_doc.table(a, root, "mcp_servers"), m.name);
        for (header_keys) |old| _ = server.remove(old);
        try server.put("url", .{ .string = m.url });
        if (m.headers.len > 0) {
            const headers = try toml_doc.table(a, server, schema.headers);
            for (m.headers) |h| try headers.put(h.name, .{ .string = h.value });
        }
    }
    if (previous.provider) |old| if (contrib.provider == null or !eq(u8, contrib.provider.?.id, old)) schema.dropProvider(root, old, previous.models orelse &.{});
    if (contrib.provider) |pr| try schema.addProvider(a, root, pr, try contribution.openaiUrl(a, pr.base_url));
    // Always rewrite, so files from older ec builds lose their inline tables.
    return toml_doc.serialize(a, root);
}
fn codexAdd(a: std.mem.Allocator, root: *Table, pr: Provider, url: []const u8) !void {
    try root.put("model_provider", .{ .string = pr.id });
    const providers = try toml_doc.table(a, root, "model_providers");
    _ = providers.remove(pr.id);
    const provider = try toml_doc.table(a, providers, pr.id);
    try provider.put("name", .{ .string = pr.name });
    try provider.put("base_url", .{ .string = url });
    try provider.put("wire_api", .{ .string = "responses" });
    try provider.put("experimental_bearer_token", .{ .string = pr.api_key });
    try provider.put("requires_openai_auth", .{ .boolean = false });
}
fn codexDrop(root: *Table, old: []const u8, _: []const []const u8) void {
    if (root.get("model_provider")) |mp| if (mp == .string and eq(u8, mp.string, old)) {
        _ = root.remove("model_provider");
    };
    if (root.get("model_providers")) |mps| if (mps == .table) {
        _ = mps.table.remove(old);
    };
}
fn grokAdd(a: std.mem.Allocator, root: *Table, pr: Provider, url: []const u8) !void {
    if (pr.models.len == 0) return;
    const models = try toml_doc.table(a, root, "models");
    if (models.get("default") == null) try models.put("default", .{ .string = pr.models[0] });
    const catalog = try toml_doc.table(a, root, "model");
    for (pr.models) |id| {
        const model = try toml_doc.table(a, catalog, id);
        for (model_auth_keys) |old| _ = model.remove(old);
        try model.put("model", .{ .string = id });
        try model.put("base_url", .{ .string = url });
        try model.put("api_key", .{ .string = pr.api_key });
        try model.put("api_backend", .{ .string = "responses" });
    }
}
fn grokDrop(root: *Table, _: []const u8, added: []const []const u8) void {
    if (root.get("model")) |catalog| if (catalog == .table) {
        for (added) |id| if (catalog.table.get(id)) |model| if (model == .table) {
            for (model_auth_keys) |k| _ = model.table.remove(k);
            const only_name = model.table.count() == 0 or (model.table.count() == 1 and model.table.get("model") != null);
            if (only_name) _ = catalog.table.remove(id);
        };
    };
    if (root.get("models")) |models| if (models == .table) if (models.table.get("default")) |d| if (d == .string) {
        for (added) |id| if (eq(u8, d.string, id)) {
            if (root.get("model")) |catalog| if (catalog == .table and catalog.table.get(id) != null) break;
            _ = models.table.remove("default");
            break;
        };
    };
}
fn tomlMcpUrl(c: *C, file: []const u8, server: []const u8) !?[]const u8 {
    const root = try toml_doc.parse(c.a, try c.optional(file) orelse return null);
    const servers = root.get("mcp_servers") orelse return null;
    if (servers != .table) return null;
    const entry = servers.table.get(server) orelse return null;
    return if (entry == .table) toml_doc.str(entry.table, "url") else null;
}

// state.json records what ec added on the last sync, so it can remove what a disabled plugin or
// an edited checkout left behind.
const State = struct {
    mcp_servers: []const []const u8 = &.{},
    provider: ?[]const u8 = null,
    models: ?[]const []const u8 = null,
    // The array entries each agent's settings gained, by agent name.
    settings: ?std.json.ArrayHashMap([]const Added) = null,
    // Read once from older builds; see legacyHooks.
    claude_hooks: ?[]const []const u8 = null,
    fn addedFor(s: State, agent: []const u8) []const Added {
        return (s.settings orelse return &.{}).map.get(agent) orelse &.{};
    }
};
fn loadState(c: *C) !State {
    const text = try c.optional(try paths.inHome(c, paths.state_file)) orelse return .{};
    // A damaged file only means ec cannot clean up after the last sync.
    return std.json.parseFromSliceLeaky(State, c.a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{},
    };
}

test "Grok keeps custom models and preferences but drops stale auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = "[models]\ndefault='grok-4.5'\n[model.\"grok-4.6\"]\ntemperature=0.3\nextra_headers={Authorization='old-secret'}\n[model.custom]\nmodel='mine'\n";
    const next = try configure(a, current, grok, .{ .provider = .{ .id = "cliproxyapi", .name = "CLIProxyAPI", .base_url = "http://proxy", .api_key = "key", .models = &.{ "grok-4.7", "grok-4.6", "grok-4.5" } } }, .{});
    const p = try toml_doc.parse(a, next);
    try std.testing.expectEqualStrings("grok-4.5", p.get("models").?.table.get("default").?.string);
    try std.testing.expectEqualStrings("mine", p.get("model").?.table.get("custom").?.table.get("model").?.string);
    try std.testing.expect(std.mem.indexOf(u8, next, "old-secret") == null);
    try std.testing.expectEqual(@as(f64, 0.3), p.get("model").?.table.get("grok-4.6").?.table.get("temperature").?.float);
}
test "disabling the provider removes the Grok models ec added and keeps customized ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = "[models]\ndefault = 'grok-4.7'\n[model.\"grok-4.7\"]\nmodel = 'grok-4.7'\nbase_url = 'http://proxy/v1'\napi_key = 'k'\n[model.\"grok-4.6\"]\nmodel = 'grok-4.6'\napi_key = 'k'\ntemperature = 0.3\n";
    const next = try configure(a, current, grok, .{}, .{ .provider = "cliproxyapi", .models = &.{ "grok-4.7", "grok-4.6" } });
    const p = try toml_doc.parse(a, next);
    const catalog = p.get("model").?.table;
    try std.testing.expect(catalog.get("grok-4.7") == null);
    try std.testing.expect(catalog.get("grok-4.6").?.table.get("api_key") == null);
    try std.testing.expectEqual(@as(f64, 0.3), catalog.get("grok-4.6").?.table.get("temperature").?.float);
    try std.testing.expect(p.get("models").?.table.get("default") == null);
    try std.testing.expect(std.mem.indexOf(u8, next, "http://proxy") == null);
}
