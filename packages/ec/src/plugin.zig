// Plugin manifests, sources, settings, and the protocol `ec` uses to run plugin commands.
// Built-in plugins use the same manifest format and run through the same protocol, as
// `ec __plugin NAME COMMAND`, so the published protocol is the one the built-ins depend on.
const std = @import("std");
const toml = @import("toml");
const core = @import("core.zig");
const manifest = @import("manifest.zig");
const secrets = @import("secrets.zig");
const C = core.Context;
const Value = std.json.Value;
const eq = core.eql;

pub const protocol = "1";
pub const lock_file = "ender-chest.lock";

pub const Option = struct { name: []const u8, kind: enum { boolean, string } = .boolean, description: []const u8 = "", values: []const []const u8 = &.{}, default: ?[]const u8 = null };
pub const Command = struct {
    name: []const u8,
    description: []const u8 = "",
    usage: []const u8 = "",
    effects: []const []const u8 = &.{},
    examples: []const []const u8 = &.{},
    options: []const Option = &.{},
    // Arguments after the command go to the plugin untouched, including --json and --help.
    passthrough: bool = false,
};
pub const Setting = struct { name: []const u8, kind: enum { string, secret, boolean, integer } = .string, required: bool = false, default: ?toml.Value = null, description: []const u8 = "" };
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Mcp = struct { name: []const u8, url: []const u8, headers: []const Header = &.{} };
// `id` is the contributing plugin, used as the Codex provider key.
pub const Provider = struct { id: []const u8 = "", name: []const u8, base_url: []const u8, api_key: []const u8, models: []const []const u8 = &.{} };
pub const Plugin = struct {
    name: []const u8,
    description: []const u8 = "",
    // Absolute path of the plugin directory; empty for built-ins.
    dir: []const u8 = "",
    run: []const u8 = "",
    // The command `ec NAME` runs when no command is given.
    default: ?[]const u8 = null,
    builtin: bool = false,
    source: []const u8 = "",
    commit: ?[]const u8 = null,
    settings: []const Setting = &.{},
    commands: []const Command = &.{},
    mcp_servers: []const Mcp = &.{},
    provider: ?Provider = null,
    hook_sync: []const []const u8 = &.{},
    hook_verify: []const []const u8 = &.{},
    // Resolved settings: a JSON object. `missing` names settings with no value.
    values: Value = .null,
    missing: []const []const u8 = &.{},
    pub fn command(p: Plugin, name: []const u8) ?Command {
        for (p.commands) |cmd| if (eq(u8, cmd.name, name)) return cmd;
        return null;
    }
};

pub const builtins = [_]struct { name: []const u8, manifest: []const u8 }{
    .{ .name = "cliproxyapi", .manifest = @embedFile("plugins/cliproxyapi.toml") },
    .{ .name = "executor", .manifest = @embedFile("plugins/executor.toml") },
    .{ .name = "kde", .manifest = @embedFile("plugins/kde.toml") },
    .{ .name = "quiet", .manifest = @embedFile("plugins/quiet.toml") },
    .{ .name = "wol", .manifest = @embedFile("plugins/wol.toml") },
};
pub fn builtinManifest(name: []const u8) ?[]const u8 {
    for (builtins) |b| if (eq(u8, b.name, name)) return b.manifest;
    return null;
}

const ManifestError = error{ InvalidManifest, OutOfMemory };
pub fn parseManifest(a: std.mem.Allocator, text: []const u8) !Plugin {
    var parser = toml.Parser(toml.Table).init(a);
    const parsed = parser.parseString(text) catch return error.InvalidManifest;
    const root = &parsed.value;
    var p: Plugin = .{ .name = manifest.str(root, "name") orelse return error.InvalidManifest };
    if (!manifest.pluginName(p.name)) return error.InvalidManifest;
    p.description = manifest.str(root, "description") orelse "";
    p.run = manifest.str(root, "run") orelse return error.InvalidManifest;
    p.default = manifest.str(root, "default");
    if (root.get("settings")) |v| {
        if (v != .table) return error.InvalidManifest;
        var list: std.ArrayList(Setting) = .empty;
        for (try manifest.sortedKeys(a, v.table)) |name| {
            const t = v.table.get(name).?;
            if (t != .table or eq(u8, name, "source")) return error.InvalidManifest;
            var s: Setting = .{ .name = name, .description = manifest.str(t.table, "description") orelse "", .default = t.table.get("default") };
            if (manifest.str(t.table, "type")) |kind| s.kind = std.meta.stringToEnum(@TypeOf(s.kind), kind) orelse return error.InvalidManifest;
            if (t.table.get("required")) |r| s.required = r == .boolean and r.boolean;
            try list.append(a, s);
        }
        p.settings = list.items;
    }
    if (root.get("commands")) |v| {
        if (v != .array) return error.InvalidManifest;
        var list: std.ArrayList(Command) = .empty;
        for (v.array.items) |item| {
            if (item != .table) return error.InvalidManifest;
            const t = item.table;
            var cmd: Command = .{
                .name = manifest.str(t, "name") orelse return error.InvalidManifest,
                .description = manifest.str(t, "description") orelse "",
                .effects = (manifest.strings(a, t, "effects") catch return error.InvalidManifest) orelse &.{},
                .examples = (manifest.strings(a, t, "examples") catch return error.InvalidManifest) orelse &.{},
            };
            if (!manifest.pluginName(cmd.name)) return error.InvalidManifest;
            cmd.usage = manifest.str(t, "usage") orelse "";
            if (t.get("passthrough")) |pt| cmd.passthrough = pt == .boolean and pt.boolean;
            if (t.get("options")) |opts| {
                if (opts != .array) return error.InvalidManifest;
                var options: std.ArrayList(Option) = .empty;
                for (opts.array.items) |o| {
                    if (o != .table) return error.InvalidManifest;
                    var opt: Option = .{ .name = manifest.str(o.table, "name") orelse return error.InvalidManifest, .description = manifest.str(o.table, "description") orelse "", .default = manifest.str(o.table, "default") };
                    if (!manifest.pluginName(opt.name) or eq(u8, opt.name, "json") or eq(u8, opt.name, "help")) return error.InvalidManifest;
                    if (manifest.str(o.table, "type")) |kind| opt.kind = std.meta.stringToEnum(@TypeOf(opt.kind), kind) orelse return error.InvalidManifest;
                    opt.values = (manifest.strings(a, o.table, "values") catch return error.InvalidManifest) orelse &.{};
                    try options.append(a, opt);
                }
                cmd.options = options.items;
            }
            try list.append(a, cmd);
        }
        p.commands = list.items;
    }
    if (p.default) |d| if (p.command(d) == null) return error.InvalidManifest;
    if (root.get("mcp_servers")) |v| {
        if (v != .array) return error.InvalidManifest;
        var list: std.ArrayList(Mcp) = .empty;
        for (v.array.items) |item| {
            if (item != .table) return error.InvalidManifest;
            var m: Mcp = .{ .name = manifest.str(item.table, "name") orelse return error.InvalidManifest, .url = manifest.str(item.table, "url") orelse return error.InvalidManifest };
            if (!manifest.pluginName(m.name)) return error.InvalidManifest;
            if (item.table.get("headers")) |h| {
                if (h != .table) return error.InvalidManifest;
                var headers: std.ArrayList(Header) = .empty;
                for (try manifest.sortedKeys(a, h.table)) |k| {
                    const hv = h.table.get(k).?;
                    if (hv != .string) return error.InvalidManifest;
                    try headers.append(a, .{ .name = k, .value = hv.string });
                }
                m.headers = headers.items;
            }
            try list.append(a, m);
        }
        p.mcp_servers = list.items;
    }
    if (root.get("provider")) |v| {
        if (v != .table) return error.InvalidManifest;
        p.provider = .{
            .name = manifest.str(v.table, "name") orelse p.name,
            .base_url = manifest.str(v.table, "base_url") orelse return error.InvalidManifest,
            .api_key = manifest.str(v.table, "api_key") orelse return error.InvalidManifest,
            .models = (manifest.strings(a, v.table, "models") catch return error.InvalidManifest) orelse &.{},
        };
    }
    if (root.get("hooks")) |v| {
        if (v != .table) return error.InvalidManifest;
        p.hook_sync = (manifest.strings(a, v.table, "sync") catch return error.InvalidManifest) orelse &.{};
        p.hook_verify = (manifest.strings(a, v.table, "verify") catch return error.InvalidManifest) orelse &.{};
    }
    return p;
}

// Loads every plugin enabled in ender-chest.toml. With `fetch`, clones missing GitHub plugins
// and records new commits in the lock file; without it, a missing clone is an error.
pub fn loadAll(c: *C, m: manifest.Manifest, fetch: bool) ![]Plugin {
    var list: std.ArrayList(Plugin) = .empty;
    for (m.plugins) |entry| try list.append(c.a, try load(c, entry, fetch));
    return list.items;
}
pub fn load(c: *C, entry: manifest.PluginEntry, fetch: bool) !Plugin {
    var p: Plugin = undefined;
    if (entry.source) |source| {
        if (std.mem.indexOfScalar(u8, source, '#') != null) {
            const dir = try github(c, entry.name, source, fetch);
            p = try fromDir(c, entry.name, dir.path);
            p.commit = dir.commit;
        } else {
            const rel = if (std.mem.startsWith(u8, source, "./")) source[2..] else source;
            if (!manifest.safeRel(rel)) return c.fail("Plugin {s}: source must be a path inside the config repo or owner/repo#ref.", .{entry.name});
            p = try fromDir(c, entry.name, try c.path(&.{ c.repo, rel }));
        }
        p.source = source;
    } else {
        const text = builtinManifest(entry.name) orelse return c.fail("No built-in plugin named {s}. Set source = \"owner/repo#ref\" or a path in the config repo.", .{entry.name});
        p = parseManifest(c.a, text) catch unreachable;
        p.builtin = true;
        p.source = "built-in";
    }
    try resolve(c, &p, entry.settings);
    return p;
}
fn fromDir(c: *C, name: []const u8, dir: []const u8) !Plugin {
    const file = try c.path(&.{ dir, "plugin.toml" });
    const text = try c.optional(file) orelse return c.fail("Plugin {s} has no plugin.toml at {s}.", .{ name, dir });
    var p = parseManifest(c.a, text) catch return c.fail("Invalid plugin manifest at {s}. See docs/plugins.md.", .{file});
    if (!eq(u8, p.name, name)) return c.fail("Plugin at {s} is named {s}, but ender-chest.toml enables it as {s}.", .{ dir, p.name, name });
    if (!manifest.safeRel(p.run)) return c.fail("Plugin {s}: run must be a path inside the plugin directory.", .{name});
    p.dir = dir;
    return p;
}

// Applies settings from [plugins.NAME], defaults, and secrets. Unknown keys are errors, so a
// typo cannot silently leave a setting unset.
pub fn resolve(c: *C, p: *Plugin, settings: *const toml.Table) !void {
    var values = c.object();
    var missing: std.ArrayList([]const u8) = .empty;
    for (try manifest.sortedKeys(c.a, settings)) |key| {
        if (eq(u8, key, "source")) continue;
        const known = for (p.settings) |s| {
            if (eq(u8, s.name, key)) break true;
        } else false;
        if (!known) return c.fail("Plugin {s} has no setting named {s}. Run ec {s} --help for its settings.", .{ p.name, key, p.name });
    }
    for (p.settings) |s| {
        const raw = settings.get(s.name) orelse s.default;
        const v: ?Value = if (raw) |r| try convert(c, p.name, s, r) else null;
        if (v) |value| try values.object.put(c.a, s.name, value) else if (s.required or s.kind == .secret) try missing.append(c.a, s.name);
    }
    p.values = values;
    p.missing = missing.items;
}
fn convert(c: *C, plugin: []const u8, s: Setting, raw: toml.Value) !?Value {
    switch (raw) {
        .string => |text| {
            if (s.kind != .string and s.kind != .secret) return c.fail("Plugin {s}: {s} must be a {s}.", .{ plugin, s.name, @tagName(s.kind) });
            return .{ .string = text };
        },
        .boolean => |b| return if (s.kind == .boolean) .{ .bool = b } else c.fail("Plugin {s}: {s} must be a {s}.", .{ plugin, s.name, @tagName(s.kind) }),
        .integer => |n| return if (s.kind == .integer) .{ .integer = n } else c.fail("Plugin {s}: {s} must be a {s}.", .{ plugin, s.name, @tagName(s.kind) }),
        .table => |t| {
            if (s.kind != .string and s.kind != .secret) return c.fail("Plugin {s}: {s} must be a {s}.", .{ plugin, s.name, @tagName(s.kind) });
            if (manifest.str(t, "secret")) |name| {
                const value = try secrets.get(c, name) orelse return null;
                return .{ .string = value };
            }
            if (manifest.str(t, "env")) |name| {
                const value = c.env.get(name) orelse return null;
                return if (value.len == 0) null else .{ .string = value };
            }
            return c.fail("Plugin {s}: {s} must be a value, {{ secret = \"NAME\" }}, or {{ env = \"VAR\" }}.", .{ plugin, s.name });
        },
        else => return c.fail("Plugin {s}: unsupported value for {s}.", .{ plugin, s.name }),
    }
}

// Replaces {setting} with its resolved value. Returns null when a used setting has no value.
pub fn render(c: *C, p: Plugin, template: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, template, i, '}') orelse return error.InvalidTemplate;
            const key = template[i + 1 .. end];
            const v = p.values.object.get(key) orelse return null;
            switch (v) {
                .string => |s| try out.appendSlice(c.a, std.mem.trimEnd(u8, s, "/")),
                .integer => |n| try out.appendSlice(c.a, try c.fmt("{d}", .{n})),
                .bool => |b| try out.appendSlice(c.a, if (b) "true" else "false"),
                else => return null,
            }
            i = end + 1;
        } else {
            try out.append(c.a, template[i]);
            i += 1;
        }
    }
    return out.items;
}
// The MCP servers and provider that enabled plugins contribute, with settings filled in.
pub const Contributions = struct { mcp_servers: []const Mcp = &.{}, provider: ?Provider = null };
pub fn contributions(c: *C, plugins: []const Plugin) !Contributions {
    var servers: std.ArrayList(Mcp) = .empty;
    var provider: ?Provider = null;
    for (plugins) |p| {
        for (p.mcp_servers) |m| {
            const url = try render(c, p, m.url) orelse {
                try c.log("{s}: skipping MCP server {s}; a setting it uses is not set.", .{ p.name, m.name });
                continue;
            };
            var headers: std.ArrayList(Header) = .empty;
            const complete = for (m.headers) |h| {
                try headers.append(c.a, .{ .name = h.name, .value = try render(c, p, h.value) orelse break false });
            } else true;
            if (!complete) {
                try c.log("{s}: skipping MCP server {s}; a setting it uses is not set. Run ec secret set if it needs a secret.", .{ p.name, m.name });
                continue;
            }
            for (servers.items) |existing| if (eq(u8, existing.name, m.name)) return c.fail("Two plugins add an MCP server named {s}.", .{m.name});
            try servers.append(c.a, .{ .name = m.name, .url = url, .headers = headers.items });
        }
        if (p.provider) |pr| {
            if (provider != null) return c.fail("Only one plugin may set the model provider; {s} and {s} both do.", .{ provider.?.name, pr.name });
            const base = try render(c, p, pr.base_url);
            const key = try render(c, p, pr.api_key);
            if (base == null or key == null) {
                try c.log("{s}: leaving agent authentication unchanged; a setting the provider uses is not set.", .{p.name});
                continue;
            }
            provider = .{ .id = p.name, .name = pr.name, .base_url = base.?, .api_key = key.?, .models = pr.models };
        }
    }
    return .{ .mcp_servers = servers.items, .provider = provider };
}

// Validates arguments against the manifest, then replaces this process with the plugin.
pub fn invoke(c: *C, p: Plugin, args: []const []const u8) !void {
    const name = args[0];
    const cmd = p.command(name) orelse {
        c.error_code = "usage_error";
        return usage(c, "Unknown {s} command {s}. Run ec {s} --help.", .{ p.name, name, p.name });
    };
    var forwarded: std.ArrayList([]const u8) = .empty;
    if (cmd.passthrough) {
        try forwarded.appendSlice(c.a, args[1..]);
    } else {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (eq(u8, arg, "--json")) continue;
            if (!std.mem.startsWith(u8, arg, "--")) return usage(c, "ec {s} {s} takes no arguments other than options. Run ec {s} {s} --help.", .{ p.name, cmd.name, p.name, cmd.name });
            const eqpos = std.mem.indexOfScalar(u8, arg, '=');
            const key = arg[2 .. eqpos orelse arg.len];
            const opt = for (cmd.options) |o| {
                if (eq(u8, o.name, key)) break o;
            } else return usage(c, "Unknown option --{s} for ec {s} {s}. Run ec {s} {s} --help.", .{ key, p.name, cmd.name, p.name, cmd.name });
            try forwarded.append(c.a, arg);
            if (opt.kind == .boolean) {
                if (eqpos != null) return usage(c, "--{s} takes no value.", .{key});
                continue;
            }
            const value = if (eqpos) |pos| arg[pos + 1 ..] else blk: {
                i += 1;
                if (i == args.len or std.mem.startsWith(u8, args[i], "--")) return usage(c, "--{s} needs a value.", .{key});
                try forwarded.append(c.a, args[i]);
                break :blk args[i];
            };
            if (value.len == 0) return usage(c, "--{s} needs a value.", .{key});
            if (opt.values.len > 0) {
                const allowed = for (opt.values) |v| {
                    if (eq(u8, v, value)) break true;
                } else false;
                if (!allowed) return usage(c, "--{s} must be one of: {s}.", .{ key, try std.mem.join(c.a, ", ", opt.values) });
            }
        }
    }
    // Optional secrets reach the plugin as absent keys; it decides which commands need them.
    for (p.missing) |m| {
        const s = for (p.settings) |s| {
            if (eq(u8, s.name, m)) break s;
        } else unreachable;
        if (!s.required) continue;
        if (s.kind == .secret) return c.failCode("interaction_required", "Plugin {s} needs its {s} secret. Set {s} = {{ secret = \"NAME\" }} under [plugins.{s}], then run ec secret set NAME.", .{ p.name, m, m, p.name });
        return c.fail("Plugin {s} needs {s}. Add it under [plugins.{s}] in ender-chest.toml.", .{ p.name, m, p.name });
    }
    const env = try environment(c, p);
    var argv: std.ArrayList([]const u8) = .empty;
    if (p.builtin) {
        try argv.appendSlice(c.a, &.{ try std.process.executablePathAlloc(c.io, c.a), "__plugin", p.name });
    } else {
        const exe = try c.path(&.{ p.dir, p.run });
        if (!c.exists(exe)) return c.fail("Plugin {s}: {s} does not exist.", .{ p.name, exe });
        try argv.append(c.a, exe);
    }
    try argv.append(c.a, cmd.name);
    try argv.appendSlice(c.a, forwarded.items);
    const err = std.process.replace(c.io, .{ .argv = argv.items, .environ_map = env });
    return c.fail("Cannot run plugin {s}: {s}.", .{ p.name, @errorName(err) });
}
fn usage(c: *C, comptime f: []const u8, args: anytype) error{ Reported, OutOfMemory } {
    c.error_code = "usage_error";
    c.message = try c.fmt(f, args);
    return error.Reported;
}
pub fn environment(c: *C, p: Plugin) !*std.process.Environ.Map {
    const env = try c.a.create(std.process.Environ.Map);
    env.* = try c.env.clone(c.a);
    try env.put("EC_PROTOCOL", protocol);
    try env.put("EC_PLUGIN", p.name);
    try env.put("EC_PLUGIN_DIR", p.dir);
    try env.put("EC_PLUGIN_SETTINGS", try std.json.Stringify.valueAlloc(c.a, p.values, .{}));
    try env.put("EC_BIN", try std.process.executablePathAlloc(c.io, c.a));
    try env.put("EC_REPO", c.repo);
    if (c.json) try env.put("EC_JSON", "1") else _ = env.swapRemove("EC_JSON");
    return env;
}
// Runs a hook command and waits. Output goes to stderr so --json stays one result.
pub fn hook(c: *C, p: Plugin, args: []const []const u8) !bool {
    if (args.len == 0) return true;
    for (p.missing) |m| for (p.settings) |s| if (eq(u8, s.name, m) and s.required) {
        try c.log("{s}: skipping its hook until {s} is set.", .{ p.name, m });
        return true;
    };
    const env = try environment(c, p);
    _ = env.swapRemove("EC_JSON");
    var argv: std.ArrayList([]const u8) = .empty;
    if (p.builtin) try argv.appendSlice(c.a, &.{ try std.process.executablePathAlloc(c.io, c.a), "__plugin", p.name }) else try argv.append(c.a, try c.path(&.{ p.dir, p.run }));
    try argv.appendSlice(c.a, args);
    var child = try std.process.spawn(c.io, .{ .argv = argv.items, .environ_map = env, .stdin = .ignore, .stdout = .{ .file = c.stderr }, .stderr = .{ .file = c.stderr } });
    return core.success(try child.wait(c.io));
}

// GitHub sources, pinned by commit in ender-chest.lock.
const Fetched = struct { path: []const u8, commit: []const u8 };
fn github(c: *C, name: []const u8, source: []const u8, fetch: bool) !Fetched {
    const hash = std.mem.indexOfScalar(u8, source, '#').?;
    const slug = source[0..hash];
    const ref = source[hash + 1 ..];
    if (!validSlug(slug) or ref.len == 0 or !validRef(ref)) return c.fail("Plugin {s}: source must look like owner/repo#ref.", .{name});
    var lock = try readLock(c);
    const locked = lockedCommit(lock, name, source);
    const commit = locked orelse blk: {
        if (!fetch) return c.fail("Plugin {s} is not installed. Run ec sync.", .{name});
        const resolved = try resolveRef(c, slug, ref) orelse return c.fail("Plugin {s}: {s} has no ref {s}.", .{ name, slug, ref });
        try setLock(c, &lock, name, source, resolved);
        break :blk resolved;
    };
    const dir = try c.path(&.{ c.home, ".local/share/ender-chest/plugins", slug, commit });
    if (!c.exists(try c.path(&.{ dir, "plugin.toml" }))) {
        if (!fetch) return c.fail("Plugin {s} is not installed. Run ec sync.", .{name});
        try clone(c, slug, commit, dir);
    }
    return .{ .path = dir, .commit = commit };
}
pub fn update(c: *C, m: manifest.Manifest, name: []const u8) !void {
    const entry = m.plugin(name) orelse return c.fail("{s} is not enabled in ender-chest.toml.", .{name});
    const source = entry.source orelse return c.fail("{s} is built in; it updates with ec.", .{name});
    const hash = std.mem.indexOfScalar(u8, source, '#') orelse return c.fail("{s} comes from the config repo; it updates with ec sync.", .{name});
    const slug = source[0..hash];
    var lock = try readLock(c);
    const old = lockedCommit(lock, name, source);
    const commit = try resolveRef(c, slug, source[hash + 1 ..]) orelse return c.fail("{s} has no ref {s}.", .{ slug, source[hash + 1 ..] });
    const dir = try c.path(&.{ c.home, ".local/share/ender-chest/plugins", slug, commit });
    if (!c.exists(try c.path(&.{ dir, "plugin.toml" }))) try clone(c, slug, commit, dir);
    try setLock(c, &lock, name, source, commit);
    if (old != null and eq(u8, old.?, commit)) return c.result("plugin update", true, try c.fmt("{s} is already at {s}.", .{ name, commit[0..12] }));
    const compare = if (old) |o| try c.fmt("https://github.com/{s}/compare/{s}...{s}", .{ slug, o, commit }) else try c.fmt("https://github.com/{s}/commit/{s}", .{ slug, commit });
    try c.resultData("plugin update", true, try c.fmt("Updated {s} to {s}. Review the changes before you commit {s}: {s}", .{ name, commit[0..12], lock_file, compare }), .{ .plugin = name, .old = old, .new = commit, .compare = compare });
}
fn validSlug(slug: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, slug, '/') orelse return false;
    return core.safeName(slug[0..slash]) and core.safeName(slug[slash + 1 ..]) and std.mem.indexOfScalar(u8, slug[slash + 1 ..], '/') == null;
}
fn validRef(ref: []const u8) bool {
    if (ref[0] == '-') return false;
    for (ref) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '_' and ch != '/') return false;
    return std.mem.indexOf(u8, ref, "..") == null;
}
fn isCommit(ref: []const u8) bool {
    if (ref.len != 40) return false;
    for (ref) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}
fn resolveRef(c: *C, slug: []const u8, ref: []const u8) !?[]const u8 {
    if (isCommit(ref)) return ref;
    const url = try c.fmt("https://github.com/{s}.git", .{slug});
    const r = c.capture(&.{ "git", "ls-remote", url, ref, try c.fmt("{s}^{{}}", .{ref}) }, null, 60) catch return c.fail("Cannot reach {s}.", .{url});
    if (!core.success(r.term)) return c.fail("git ls-remote {s} failed. Check the source and your GitHub access.", .{url});
    // Prefer the commit a tag points at over the tag object itself.
    var best: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 41) continue;
        const sha = line[0..40];
        if (std.mem.endsWith(u8, line, "^{}")) return try c.a.dupe(u8, sha);
        if (best == null) best = try c.a.dupe(u8, sha);
    }
    return best;
}
fn clone(c: *C, slug: []const u8, commit: []const u8, dir: []const u8) !void {
    const parent = std.fs.path.dirname(dir).?;
    try c.mkdir(parent);
    const stage = try c.fmt("{s}.partial", .{dir});
    try c.remove(stage);
    try c.mkdir(stage);
    const url = try c.fmt("https://github.com/{s}.git", .{slug});
    try c.command(&.{ "git", "init", "-q", stage }, null);
    try c.command(&.{ "git", "-C", stage, "fetch", "-q", "--depth", "1", url, commit }, null);
    try c.command(&.{ "git", "-C", stage, "checkout", "-q", "FETCH_HEAD" }, null);
    try std.Io.Dir.renameAbsolute(stage, dir, c.io);
}
fn readLock(c: *C) !Value {
    const file = try c.path(&.{ c.repo, lock_file });
    const text = try c.optional(file) orelse return c.object();
    const v = c.parse(text) catch return c.fail("Invalid {s}. Delete it and run ec sync to recreate it.", .{lock_file});
    if (v != .object) return c.fail("Invalid {s}. Delete it and run ec sync to recreate it.", .{lock_file});
    return v;
}
fn lockedCommit(lock: Value, name: []const u8, source: []const u8) ?[]const u8 {
    const plugins = lock.object.get("plugins") orelse return null;
    if (plugins != .object) return null;
    const entry = plugins.object.get(name) orelse return null;
    if (!eq(u8, core.string(entry, "source") orelse "", source)) return null;
    const commit = core.string(entry, "commit") orelse return null;
    return if (isCommit(commit)) commit else null;
}
fn setLock(c: *C, lock: *Value, name: []const u8, source: []const u8, commit: []const u8) !void {
    var plugins = lock.object.get("plugins") orelse c.object();
    if (plugins != .object) plugins = c.object();
    var entry = c.object();
    try entry.object.put(c.a, "source", .{ .string = source });
    try entry.object.put(c.a, "commit", .{ .string = commit });
    try plugins.object.put(c.a, name, entry);
    try lock.object.put(c.a, "plugins", plugins);
    try c.writeJson(try c.path(&.{ c.repo, lock_file }), lock.*, 0o644);
}

test "plugin manifest parses commands, settings, and contributions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try parseManifest(arena.allocator(),
        \\name = "hello"
        \\description = "Say hello."
        \\run = "bin/hello"
        \\[settings.url]
        \\required = true
        \\[settings.token]
        \\type = "secret"
        \\[[commands]]
        \\name = "say"
        \\options = [{ name = "loud" }, { name = "lang", type = "string", values = ["en", "fr"] }]
        \\[[commands]]
        \\name = "run"
        \\passthrough = true
        \\[[mcp_servers]]
        \\name = "hello"
        \\url = "{url}/mcp"
        \\headers = { Authorization = "Bearer {token}" }
        \\[provider]
        \\base_url = "{url}"
        \\api_key = "{token}"
        \\[hooks]
        \\sync = ["hook-sync"]
    );
    try std.testing.expectEqualStrings("hello", p.name);
    try std.testing.expectEqual(@as(usize, 2), p.settings.len);
    try std.testing.expect(p.command("say").?.options[1].kind == .string);
    try std.testing.expect(p.command("run").?.passthrough);
    try std.testing.expectEqualStrings("Bearer {token}", p.mcp_servers[0].headers[0].value);
    try std.testing.expectEqualStrings("hook-sync", p.hook_sync[0]);
}
test "plugin manifests reject reserved option names and bad plugin names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidManifest, parseManifest(arena.allocator(), "name = \"x\"\nrun = \"x\"\n[[commands]]\nname = \"a\"\noptions = [{ name = \"json\" }]\n"));
    try std.testing.expectError(error.InvalidManifest, parseManifest(arena.allocator(), "name = \"../x\"\nrun = \"x\"\n"));
}
test "built-in manifests parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (builtins) |b| {
        const p = try parseManifest(arena.allocator(), b.manifest);
        try std.testing.expectEqualStrings(b.name, p.name);
    }
}
test "GitHub sources and refs reject unsafe text" {
    try std.testing.expect(validSlug("someone/ec-backup"));
    try std.testing.expect(!validSlug("someone/ec/backup") and !validSlug("../x") and !validSlug("x"));
    try std.testing.expect(validRef("v1.2.0") and validRef("main") and !validRef("--upload-pack=x") and !validRef("a..b"));
    try std.testing.expect(isCommit("0123456789abcdef0123456789abcdef01234567"));
}
