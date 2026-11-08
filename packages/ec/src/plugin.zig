// Plugin manifests, sources, settings, and the protocol `ec` uses to run plugin commands.
// Built-in plugins use the same manifest format and run through the same protocol, as
// `ec __plugin NAME COMMAND`, so the published protocol is the one the built-ins depend on.
const std = @import("std");
const toml_doc = @import("toml_doc.zig");
const core = @import("core.zig");
const manifest = @import("manifest.zig");
const paths = @import("paths.zig");
const gh = @import("github.zig");
const secrets = @import("secrets.zig");
const contribution = @import("contributions.zig");
const spec = @import("plugin_manifest.zig");
const C = core.Context;
const Value = std.json.Value;
const eq = core.eql;

const protocol = "1";
const lock_file = paths.lock_file;
const Header = contribution.Header;
const Setting = spec.Setting;
const Mcp = contribution.Mcp;
const Provider = contribution.Provider;
const Contributions = contribution.Contributions;

const Plugin = spec.Plugin;
const Command = spec.Command;
const builtin = @import("plugins/builtin.zig");

// A plugin ender-chest.toml enables: its manifest and the settings the config gives it.
pub const Enabled = struct {
    plugin: Plugin,
    // Resolved settings, as a JSON object.
    values: Value,
    // Required and secret settings with no value.
    missing: []const []const u8,
    // [plugins.NAME], which also names the secret behind each secret setting.
    config: *const toml_doc.Table,
};

// Loads every plugin enabled in ender-chest.toml. With `fetch`, clones missing GitHub plugins
// and records new commits in the lock file; without it, a missing clone is an error.
pub fn loadAll(c: *C, m: manifest.Manifest, fetch: bool) ![]Enabled {
    var list: std.ArrayList(Enabled) = .empty;
    for (m.plugins) |entry| try list.append(c.a, try load(c, entry, fetch));
    return list.items;
}
pub fn load(c: *C, entry: manifest.PluginEntry, fetch: bool) !Enabled {
    var p: Plugin = undefined;
    if (entry.source) |source| {
        if (try githubSource(c, entry.name, source)) |pinned| {
            const dir = try github(c, entry.name, source, pinned, if (fetch) .fetch else .installed);
            p = try fromDir(c, entry.name, dir.path);
            p.commit = dir.commit;
        } else {
            const rel = if (std.mem.startsWith(u8, source, "./")) source[2..] else source;
            if (!manifest.safeRel(rel)) return c.fail("Plugin {s}: source must be a path inside the config repo or owner/repo#ref.", .{entry.name});
            p = try fromDir(c, entry.name, try paths.inRepo(c, rel));
        }
        p.source = source;
    } else {
        const text = builtin.manifest(entry.name) orelse return c.fail("No built-in plugin named {s}. Set source = \"owner/repo#ref\" or a path in the config repo.", .{entry.name});
        // plugins/builtin.zig tests that every built-in manifest parses.
        p = spec.parse(c.a, text) catch unreachable;
        p.builtin = true;
        p.source = "built-in";
    }
    return resolve(c, p, entry.settings);
}
fn fromDir(c: *C, name: []const u8, dir: []const u8) !Plugin {
    const file = try c.path(&.{ dir, "plugin.toml" });
    const text = try c.optional(file) orelse return c.fail("Plugin {s} has no plugin.toml at {s}.", .{ name, dir });
    var p = spec.parse(c.a, text) catch return c.fail("Invalid plugin manifest at {s}. See docs/plugins.md.", .{file});
    if (!eq(u8, p.name, name)) return c.fail("Plugin at {s} is named {s}, but ender-chest.toml enables it as {s}.", .{ dir, p.name, name });
    if (!manifest.safeRel(p.run)) return c.fail("Plugin {s}: run must be a path inside the plugin directory.", .{name});
    p.dir = dir;
    return p;
}

// Applies settings from [plugins.NAME], defaults, and secrets. Unknown keys are errors, so a
// typo cannot silently leave a setting unset.
fn resolve(c: *C, p: Plugin, settings: *const toml_doc.Table) !Enabled {
    var values = c.object();
    var missing: std.ArrayList([]const u8) = .empty;
    for (try toml_doc.sortedKeys(c.a, settings)) |key| {
        if (p.setting(key) == null) return c.fail("Plugin {s} has no setting named {s}. Run ec {s} --help for its settings.", .{ p.name, key, p.name });
    }
    for (p.settings) |s| {
        const raw = settings.get(s.name) orelse s.default;
        const v: ?Value = if (raw) |r| try convert(c, p.name, s, r) else null;
        if (v) |value| try values.object.put(c.a, s.name, value) else if (s.required or s.kind == .secret) try missing.append(c.a, s.name);
    }
    return .{ .plugin = p, .values = values, .missing = missing.items, .config = settings };
}
fn convert(c: *C, plugin: []const u8, s: Setting, raw: toml_doc.Value) !?Value {
    const fits = switch (raw) {
        .string, .table => s.kind == .string or s.kind == .secret or s.kind == .url,
        .boolean => s.kind == .boolean,
        .integer => s.kind == .integer,
        else => return c.fail("Plugin {s}: unsupported value for {s}.", .{ plugin, s.name }),
    };
    if (!fits) return c.fail("Plugin {s}: {s} must be a {s}.", .{ plugin, s.name, @tagName(s.kind) });
    switch (raw) {
        .string => |value| return textValue(s, value),
        .boolean => |b| return .{ .bool = b },
        .integer => |n| return .{ .integer = n },
        .table => |t| {
            const value = if (toml_doc.str(t, "secret")) |name|
                try secrets.get(c, name) orelse return null
            else if (toml_doc.str(t, "env")) |name|
                c.env.get(name) orelse return null
            else
                return c.fail("Plugin {s}: {s} must be a value, {{ secret = \"NAME\" }}, or {{ env = \"VAR\" }}.", .{ plugin, s.name });
            return if (value.len == 0) null else textValue(s, value);
        },
        else => unreachable,
    }
}
fn textValue(s: Setting, value: []const u8) Value {
    return .{ .string = if (s.kind == .url) std.mem.trimEnd(u8, value, "/") else value };
}

// Replaces {setting} with its resolved value. Returns null when a used setting has no value.
// plugin_manifest.parse checked that every {setting} is closed and declared.
fn render(c: *C, e: Enabled, template: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, template, i, '}') orelse unreachable;
            const key = template[i + 1 .. end];
            const v = e.values.object.get(key) orelse return null;
            switch (v) {
                .string => |s| try out.appendSlice(c.a, s),
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
pub fn contributions(c: *C, plugins: []const Enabled) !Contributions {
    var servers: std.ArrayList(Mcp) = .empty;
    var provider: ?Provider = null;
    for (plugins) |e| {
        const p = e.plugin;
        for (p.mcp_servers) |m| {
            const url = try render(c, e, m.url);
            var headers: std.ArrayList(Header) = .empty;
            const complete = for (m.headers) |h| {
                try headers.append(c.a, .{ .name = h.name, .value = try render(c, e, h.value) orelse break false });
            } else true;
            if (url == null or !complete) {
                try c.log("{s}: skipping MCP server {s}; a setting it uses is not set. Run ec secret set if it needs a secret.", .{ p.name, m.name });
                continue;
            }
            for (servers.items) |existing| if (eq(u8, existing.name, m.name)) return c.fail("Two plugins add an MCP server named {s}.", .{m.name});
            try servers.append(c.a, .{ .name = m.name, .url = url.?, .headers = headers.items });
        }
        if (p.provider) |pr| {
            if (provider != null) return c.fail("Only one plugin may set the model provider; {s} and {s} both do.", .{ provider.?.name, pr.name });
            const base = try render(c, e, pr.base_url);
            const key = try render(c, e, pr.api_key);
            if (base == null or key == null) {
                try c.log("{s}: leaving agent authentication unchanged; a setting the provider uses is not set.", .{p.name});
                continue;
            }
            provider = .{ .id = p.name, .name = pr.name, .base_url = base.?, .api_key = key.?, .models = pr.models };
        }
    }
    return .{ .mcp_servers = servers.items, .provider = provider };
}

// The first setting `cmd` cannot run without that has no value.
fn unmet(e: Enabled, cmd: ?Command) ?Setting {
    for (e.plugin.settings) |s| if (s.neededBy(cmd) and e.values.object.get(s.name) == null) return s;
    return null;
}
fn secretName(e: Enabled, setting: []const u8) ?[]const u8 {
    const v = e.config.get(setting) orelse return null;
    return if (v == .table) toml_doc.str(v.table, "secret") else null;
}

const Launch = struct { argv: []const []const u8, env: *std.process.Environ.Map };
// The process and environment for a plugin command or hook, as docs/plugins.md describes them.
fn prepare(c: *C, e: Enabled, args: []const []const u8, json: bool) !Launch {
    const p = e.plugin;
    const self = try std.process.executablePathAlloc(c.io, c.a);
    const env = try c.a.create(std.process.Environ.Map);
    env.* = try c.env.clone(c.a);
    try env.put("EC_PROTOCOL", protocol);
    try env.put("EC_PLUGIN", p.name);
    try env.put("EC_PLUGIN_DIR", p.dir);
    try env.put("EC_PLUGIN_SETTINGS", try std.json.Stringify.valueAlloc(c.a, e.values, .{}));
    try env.put("EC_BIN", self);
    try env.put("EC_REPO", c.repo);
    if (json) try env.put("EC_JSON", "1") else _ = env.swapRemove("EC_JSON");
    var argv: std.ArrayList([]const u8) = .empty;
    if (p.builtin) {
        try argv.appendSlice(c.a, &.{ self, "__plugin", p.name });
    } else {
        const exe = try c.path(&.{ p.dir, p.run });
        if (!c.exists(exe)) return c.fail("Plugin {s}: {s} does not exist.", .{ p.name, exe });
        try argv.append(c.a, exe);
    }
    try argv.appendSlice(c.a, args);
    return .{ .argv = argv.items, .env = env };
}

pub fn invoke(c: *C, e: Enabled, cmd: Command, args: []const []const u8) !noreturn {
    const p = e.plugin;
    var forwarded: std.ArrayList([]const u8) = .empty;
    try forwarded.append(c.a, cmd.name);
    if (cmd.passthrough) {
        try forwarded.appendSlice(c.a, args);
    } else {
        for (args) |arg| if (!eq(u8, arg, "--json")) try forwarded.append(c.a, arg);
        var at: []const u8 = "";
        _ = spec.readArgs(c.a, cmd, forwarded.items[1..], &at) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Positional => c.failCode(.usage_error, "ec {s} {s} takes no arguments other than options. Run ec {s} {s} --help.", .{ p.name, cmd.name, p.name, cmd.name }),
            error.UnknownOption => c.failCode(.usage_error, "Unknown option --{s} for ec {s} {s}. Run ec {s} {s} --help.", .{ at, p.name, cmd.name, p.name, cmd.name }),
            error.TakesNoValue => c.failCode(.usage_error, "--{s} takes no value.", .{at}),
            error.NeedsValue => c.failCode(.usage_error, "--{s} needs a value.", .{at}),
            error.NotAllowed => c.failCode(.usage_error, "--{s} must be one of: {s}.", .{ at, try std.mem.join(c.a, ", ", cmd.option(at).?.values) }),
        };
    }
    if (unmet(e, cmd)) |s| {
        if (s.kind != .secret) return c.fail("Plugin {s} needs {s}. Add it under [plugins.{s}] in ender-chest.toml.", .{ p.name, s.name, p.name });
        const secret = secretName(e, s.name) orelse "NAME";
        return c.failCode(.interaction_required, "Plugin {s} needs its {s} secret. Set {s} = {{ secret = \"{s}\" }} under [plugins.{s}], then run ec secret set {s}.", .{ p.name, s.name, s.name, secret, p.name, secret });
    }
    const launch = try prepare(c, e, forwarded.items, c.json);
    const err = std.process.replace(c.io, .{ .argv = launch.argv, .environ_map = launch.env });
    return c.fail("Cannot run plugin {s}: {s}.", .{ p.name, @errorName(err) });
}
// Runs a hook command and waits. Output goes to stderr so --json stays one result.
pub fn hook(c: *C, e: Enabled, args: []const []const u8) !bool {
    if (args.len == 0) return true;
    if (unmet(e, null)) |s| {
        try c.log("{s}: skipping its hook until {s} is set.", .{ e.plugin.name, s.name });
        return true;
    }
    const launch = try prepare(c, e, args, false);
    var child = try std.process.spawn(c.io, .{ .argv = launch.argv, .environ_map = launch.env, .stdin = .ignore, .stdout = .{ .file = c.stderr }, .stderr = .{ .file = c.stderr } });
    return core.success(try child.wait(c.io));
}

// A source with #ref is a GitHub repository pinned by commit in ender-chest.lock; anything
// else is a path in the config repo.
fn githubSource(c: *C, name: []const u8, source: []const u8) !?gh.Source {
    if (std.mem.indexOfScalar(u8, source, '#') == null) return null;
    const parsed = gh.Source.parse(source) catch return c.fail("Plugin {s}: source must look like owner/repo#ref.", .{name});
    if (!gh.strictRef(parsed.ref.?)) return c.fail("Plugin {s}: source must look like owner/repo#ref.", .{name});
    return parsed;
}
const Fetched = struct { path: []const u8, slug: []const u8, commit: []const u8, old: ?[]const u8 };
// What a GitHub plugin may do before it is used: nothing (`installed`), install the commit the
// lock file records or, without one, the ref's current commit (`fetch`), or move to the ref's
// current commit (`newest`).
const Want = enum { installed, fetch, newest };
fn github(c: *C, name: []const u8, source: []const u8, pinned: gh.Source, want: Want) !Fetched {
    var lock = try readLock(c);
    const old = lockedCommit(lock, name, source);
    const commit = (if (want == .newest) null else old) orelse blk: {
        if (want == .installed) return c.fail("Plugin {s} is not installed. Run ec sync.", .{name});
        break :blk try resolveRef(c, pinned.slug, pinned.ref.?) orelse return c.fail("Plugin {s}: {s} has no ref {s}.", .{ name, pinned.slug, pinned.ref.? });
    };
    const dir = try c.path(&.{ c.home, paths.plugin_store, pinned.slug, commit });
    if (!c.exists(try c.path(&.{ dir, "plugin.toml" }))) {
        if (want == .installed) return c.fail("Plugin {s} is not installed. Run ec sync.", .{name});
        try clone(c, pinned.slug, commit, dir);
    }
    if (old == null or !eq(u8, old.?, commit)) try setLock(c, &lock, name, source, commit);
    return .{ .path = dir, .slug = pinned.slug, .commit = commit, .old = old };
}
// Moves a GitHub plugin to the newest commit of its ref and records it in the lock file.
pub fn update(c: *C, m: manifest.Manifest, name: []const u8) !Fetched {
    const entry = m.plugin(name) orelse return c.fail("{s} is not enabled in ender-chest.toml.", .{name});
    const source = entry.source orelse return c.fail("{s} is built in; it updates with ec.", .{name});
    const pinned = try githubSource(c, name, source) orelse return c.fail("{s} comes from the config repo; it updates with ec sync.", .{name});
    return github(c, name, source, pinned, .newest);
}
fn resolveRef(c: *C, slug: []const u8, ref: []const u8) !?[]const u8 {
    if (core.isCommit(ref)) return ref;
    const url = try gh.cloneUrl(c.a, slug);
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
    const url = try gh.cloneUrl(c.a, slug);
    try c.command(&.{ "git", "init", "-q", stage }, null);
    try c.command(&.{ "git", "-C", stage, "fetch", "-q", "--depth", "1", url, commit }, null);
    try c.command(&.{ "git", "-C", stage, "checkout", "-q", "FETCH_HEAD" }, null);
    try std.Io.Dir.renameAbsolute(stage, dir, c.io);
}
fn readLock(c: *C) !Value {
    const file = try paths.inRepo(c, lock_file);
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
    return if (core.isCommit(commit)) commit else null;
}
fn setLock(c: *C, lock: *Value, name: []const u8, source: []const u8, commit: []const u8) !void {
    var plugins = lock.object.get("plugins") orelse c.object();
    if (plugins != .object) plugins = c.object();
    var entry = c.object();
    try entry.object.put(c.a, "source", .{ .string = source });
    try entry.object.put(c.a, "commit", .{ .string = commit });
    try plugins.object.put(c.a, name, entry);
    try lock.object.put(c.a, "plugins", plugins);
    try c.writeJson(try paths.inRepo(c, lock_file), lock.*, 0o644);
}
