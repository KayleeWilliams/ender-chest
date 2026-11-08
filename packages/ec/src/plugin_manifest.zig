// The plugin.toml format: what a plugin declares about its settings, commands, and agent
// contributions. ec validates calls against it, and built-in plugins read it back at run time.
const std = @import("std");
const toml_doc = @import("toml_doc.zig");
const core = @import("core.zig");
const contribution = @import("contributions.zig");
const eq = core.eql;

pub const Option = struct {
    name: []const u8,
    kind: enum { boolean, string } = .boolean,
    description: []const u8 = "",
    values: []const []const u8 = &.{},
    default: ?[]const u8 = null,
    // Help's JSON command definitions use plugin.toml's key names.
    pub fn jsonStringify(o: Option, jws: anytype) !void {
        try jws.write(.{ .name = o.name, .type = @tagName(o.kind), .description = o.description, .values = o.values, .default = o.default });
    }
};
pub const Command = struct {
    name: []const u8,
    description: []const u8 = "",
    usage: []const u8 = "",
    effects: []const []const u8 = &.{},
    examples: []const []const u8 = &.{},
    options: []const Option = &.{},
    // Settings this command cannot run without, beyond the plugin's required ones.
    needs: []const []const u8 = &.{},
    // Arguments after the command go to the plugin untouched, including --json and --help.
    passthrough: bool = false,
    pub fn option(cmd: Command, name: []const u8) ?Option {
        for (cmd.options) |o| if (eq(u8, o.name, name)) return o;
        return null;
    }
    pub fn needsSetting(cmd: Command, name: []const u8) bool {
        for (cmd.needs) |n| if (eq(u8, n, name)) return true;
        return false;
    }
};
// A `url` setting is a string with trailing slashes removed, so templates can append paths.
pub const Setting = struct {
    name: []const u8,
    kind: enum { string, secret, boolean, integer, url } = .string,
    required: bool = false,
    default: ?toml_doc.Value = null,
    description: []const u8 = "",
    // Whether `cmd` cannot run without this setting. Hooks have no command, so only required
    // settings count for them.
    pub fn neededBy(s: Setting, cmd: ?Command) bool {
        return s.required or (cmd != null and cmd.?.needsSetting(s.name));
    }
};
pub const Plugin = struct {
    name: []const u8,
    description: []const u8 = "",
    // Absolute path of the plugin directory; empty for built-ins.
    dir: []const u8 = "",
    // The executable, relative to `dir`. Built-ins have none; ec runs them itself.
    run: []const u8 = "",
    // The command `ec NAME` runs when no command is given.
    default: ?[]const u8 = null,
    builtin: bool = false,
    source: []const u8 = "",
    commit: ?[]const u8 = null,
    settings: []const Setting = &.{},
    commands: []const Command = &.{},
    mcp_servers: []const contribution.Mcp = &.{},
    provider: ?contribution.Provider = null,
    hook_sync: []const []const u8 = &.{},
    hook_verify: []const []const u8 = &.{},
    pub fn command(p: Plugin, name: []const u8) ?Command {
        for (p.commands) |cmd| if (eq(u8, cmd.name, name)) return cmd;
        return null;
    }
    pub fn setting(p: Plugin, name: []const u8) ?Setting {
        for (p.settings) |s| if (eq(u8, s.name, name)) return s;
        return null;
    }
};

// Plugin, command, option, and MCP server names.
pub fn pluginName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isLower(name[0])) return false;
    for (name) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-' and ch != '_') return false;
    return true;
}

pub const Arg = struct { name: []const u8, value: ?[]const u8 = null };
pub const ArgError = error{ OutOfMemory, Positional, UnknownOption, TakesNoValue, NeedsValue, NotAllowed };
// Reads `--name`, `--name=value`, and `--name value` against `cmd`'s options: ec checks a call
// with it, and a built-in plugin reads its options with it. On error, `at` is the argument, or
// the option name, at fault.
pub fn readArgs(a: std.mem.Allocator, cmd: Command, args: []const []const u8, at: *[]const u8) ArgError![]const Arg {
    var out: std.ArrayList(Arg) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        at.* = args[i];
        if (!std.mem.startsWith(u8, args[i], "--")) return error.Positional;
        const eqpos = std.mem.indexOfScalar(u8, args[i], '=');
        at.* = args[i][2 .. eqpos orelse args[i].len];
        const opt = cmd.option(at.*) orelse return error.UnknownOption;
        if (opt.kind == .boolean) {
            if (eqpos != null) return error.TakesNoValue;
            try out.append(a, .{ .name = opt.name });
            continue;
        }
        const value = if (eqpos) |pos| args[i][pos + 1 ..] else blk: {
            i += 1;
            if (i == args.len or std.mem.startsWith(u8, args[i], "--")) return error.NeedsValue;
            break :blk args[i];
        };
        if (value.len == 0) return error.NeedsValue;
        if (opt.values.len > 0 and !core.contains(opt.values, value)) return error.NotAllowed;
        try out.append(a, .{ .name = opt.name, .value = value });
    }
    return out.items;
}

pub fn parse(a: std.mem.Allocator, text: []const u8) !Plugin {
    const root = toml_doc.parse(a, text) catch |err| return if (err == error.OutOfMemory) err else error.InvalidManifest;
    var p: Plugin = .{ .name = toml_doc.str(root, "name") orelse return error.InvalidManifest };
    if (!pluginName(p.name)) return error.InvalidManifest;
    p.description = toml_doc.str(root, "description") orelse "";
    p.run = toml_doc.str(root, "run") orelse "";
    p.default = toml_doc.str(root, "default");
    if (root.get("settings")) |v| {
        if (v != .table) return error.InvalidManifest;
        var list: std.ArrayList(Setting) = .empty;
        for (try toml_doc.sortedKeys(a, v.table)) |name| {
            const t = v.table.get(name).?;
            // [plugins.NAME] keeps `source` beside the settings.
            if (t != .table or eq(u8, name, "source")) return error.InvalidManifest;
            var s: Setting = .{ .name = name, .description = toml_doc.str(t.table, "description") orelse "", .default = t.table.get("default") };
            if (toml_doc.str(t.table, "type")) |kind| s.kind = std.meta.stringToEnum(@TypeOf(s.kind), kind) orelse return error.InvalidManifest;
            if (t.table.get("required")) |r| s.required = if (r == .boolean) r.boolean else return error.InvalidManifest;
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
                .name = toml_doc.str(t, "name") orelse return error.InvalidManifest,
                .description = toml_doc.str(t, "description") orelse "",
                .effects = (toml_doc.strings(a, t, "effects") catch return error.InvalidManifest) orelse &.{},
                .examples = (toml_doc.strings(a, t, "examples") catch return error.InvalidManifest) orelse &.{},
                .needs = (toml_doc.strings(a, t, "needs") catch return error.InvalidManifest) orelse &.{},
            };
            if (!pluginName(cmd.name)) return error.InvalidManifest;
            for (cmd.needs) |n| if (p.setting(n) == null) return error.InvalidManifest;
            cmd.usage = toml_doc.str(t, "usage") orelse "";
            if (t.get("passthrough")) |pt| cmd.passthrough = if (pt == .boolean) pt.boolean else return error.InvalidManifest;
            if (t.get("options")) |opts| {
                if (opts != .array) return error.InvalidManifest;
                var options: std.ArrayList(Option) = .empty;
                for (opts.array.items) |o| {
                    if (o != .table) return error.InvalidManifest;
                    var opt: Option = .{ .name = toml_doc.str(o.table, "name") orelse return error.InvalidManifest, .description = toml_doc.str(o.table, "description") orelse "", .default = toml_doc.str(o.table, "default") };
                    if (!pluginName(opt.name) or eq(u8, opt.name, "json") or eq(u8, opt.name, "help")) return error.InvalidManifest;
                    if (toml_doc.str(o.table, "type")) |kind| opt.kind = std.meta.stringToEnum(@TypeOf(opt.kind), kind) orelse return error.InvalidManifest;
                    opt.values = (toml_doc.strings(a, o.table, "values") catch return error.InvalidManifest) orelse &.{};
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
        var list: std.ArrayList(contribution.Mcp) = .empty;
        for (v.array.items) |item| {
            if (item != .table) return error.InvalidManifest;
            var m: contribution.Mcp = .{ .name = toml_doc.str(item.table, "name") orelse return error.InvalidManifest, .url = toml_doc.str(item.table, "url") orelse return error.InvalidManifest };
            if (!pluginName(m.name) or !templateUses(p, m.url)) return error.InvalidManifest;
            if (item.table.get("headers")) |h| {
                if (h != .table) return error.InvalidManifest;
                var headers: std.ArrayList(contribution.Header) = .empty;
                for (try toml_doc.sortedKeys(a, h.table)) |k| {
                    const hv = h.table.get(k).?;
                    if (hv != .string or !templateUses(p, hv.string)) return error.InvalidManifest;
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
            .name = toml_doc.str(v.table, "name") orelse p.name,
            .base_url = toml_doc.str(v.table, "base_url") orelse return error.InvalidManifest,
            .api_key = toml_doc.str(v.table, "api_key") orelse return error.InvalidManifest,
            .models = (toml_doc.strings(a, v.table, "models") catch return error.InvalidManifest) orelse &.{},
        };
        if (!templateUses(p, p.provider.?.base_url) or !templateUses(p, p.provider.?.api_key)) return error.InvalidManifest;
    }
    if (root.get("hooks")) |v| {
        if (v != .table) return error.InvalidManifest;
        p.hook_sync = (toml_doc.strings(a, v.table, "sync") catch return error.InvalidManifest) orelse &.{};
        p.hook_verify = (toml_doc.strings(a, v.table, "verify") catch return error.InvalidManifest) orelse &.{};
    }
    return p;
}
// Whether every {key} in a contribution template is closed and names one of p's settings.
fn templateUses(p: Plugin, template: []const u8) bool {
    var rest = template;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse return false;
        if (p.setting(rest[open + 1 .. close]) == null) return false;
        rest = rest[close + 1 ..];
    }
    return true;
}

test "plugin manifests reject reserved option names, bad plugin names, and unknown needs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidManifest, parse(a, "name = \"x\"\n[[commands]]\nname = \"a\"\noptions = [{ name = \"json\" }]\n"));
    try std.testing.expectError(error.InvalidManifest, parse(a, "name = \"../x\"\n"));
    try std.testing.expectError(error.InvalidManifest, parse(a, "name = \"x\"\n[[commands]]\nname = \"a\"\nneeds = [\"token\"]\n"));
    try std.testing.expectError(error.InvalidManifest, parse(a, "name = \"x\"\ndefault = \"missing\"\n"));
}
test "plugin manifests reject non-boolean flags and templates that use undeclared settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidManifest, parse(a, "name = \"x\"\n[settings.url]\nrequired = \"true\"\n"));
    try std.testing.expectError(error.InvalidManifest, parse(a, "name = \"x\"\n[[commands]]\nname = \"a\"\npassthrough = 1\n"));
    const server = "name = \"x\"\n[settings.url]\n[settings.key]\n[[mcp_servers]]\nname = \"m\"\n";
    try std.testing.expectError(error.InvalidManifest, parse(a, server ++ "url = \"{urll}/mcp\"\n"));
    try std.testing.expectError(error.InvalidManifest, parse(a, server ++ "url = \"{url\"\n"));
    try std.testing.expectError(error.InvalidManifest, parse(a, server ++ "url = \"{url}\"\nheaders = { Authorization = \"Bearer {token}\" }\n"));
    try std.testing.expectError(error.InvalidManifest, parse(a, "name = \"x\"\n[settings.url]\n[provider]\nbase_url = \"{url}\"\napi_key = \"{key}\"\n"));
    _ = try parse(a, server ++ "url = \"{url}/mcp\"\nheaders = { Authorization = \"Bearer {key}\" }\n");
}
