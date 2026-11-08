// The commands and options ec accepts. The parser, help, result labels, and the argv sync uses
// to resume itself all read these tables.
const std = @import("std");
const core = @import("core.zig");
const plugin_manifest = @import("plugin_manifest.zig");
const checkout = @import("checkout.zig");
const Option = plugin_manifest.Option;
const eq = core.eql;

pub const Flag = enum { repo, profile, skip_packages, update_skills, all, dry_run, check, json, help };
const FlagInfo = struct {
    option: Option,
    // Shown when a string option has no value.
    missing: []const u8 = "",
    // This option takes no others except --json; `alone` explains why.
    alone: ?[]const u8 = null,
};
pub const flags = std.enums.EnumArray(Flag, FlagInfo).init(.{
    .repo = .{ .option = .{ .name = "repo", .kind = .string, .description = "Config checkout path.", .default = checkout.resolve_rule }, .missing = "--repo needs a checkout path." },
    .profile = .{ .option = .{ .name = "profile", .kind = .string, .description = "Override the detected machine profile. ender-chest.toml filters files and steps by profile name.", .default = checkout.profile_rule }, .missing = "--profile needs a profile name, such as mac or cloud." },
    .skip_packages = .{ .option = .{ .name = "skip-packages", .description = "Skip package installs and shell setup." } },
    .update_skills = .{ .option = .{ .name = "update-skills", .description = "Refresh third-party skills from their Git repositories." } },
    .all = .{ .option = .{ .name = "all", .description = "Sync every machine in the tailnet that is behind. Takes no other options except --json." }, .alone = "ec sync --all runs ec sync --skip-packages on each machine and takes no other options except --json." },
    .dry_run = .{ .option = .{ .name = "dry-run", .description = "Capture files into the checkout without staging, committing, or pushing." } },
    .check = .{ .option = .{ .name = "check", .description = "Report the latest release without installing it." } },
    .json = .{ .option = .{ .name = "json", .description = "One JSON result on stdout; diagnostics on stderr." } },
    .help = .{ .option = .{ .name = "help", .description = "Show help for this command. Alias: -h." } },
});
pub const common = [_]Flag{ .json, .help };

pub const Command = enum { help, version, sync, push, verify, status, update, plugin_list, plugin_update, secret_set, secret_list, secret_remove, call, builtin };
pub const Spec = struct {
    command: Command,
    // What the user types after ec, such as "plugin update".
    words: []const u8,
    usage: []const u8,
    description: []const u8,
    flags: []const Flag = &.{},
    // Takes a NAME after its words.
    target: bool = false,
    effects: []const []const u8,
    examples: []const []const u8,
    // Interactive runs say once a day when a newer ec exists.
    notice: bool = false,
    pub fn group(s: Spec) []const u8 {
        return std.mem.sliceTo(s.words, ' ');
    }
    pub fn action(s: Spec) []const u8 {
        const i = std.mem.indexOfScalar(u8, s.words, ' ') orelse return "";
        return s.words[i + 1 ..];
    }
    pub fn takes(s: Spec, f: Flag) bool {
        return std.mem.indexOfScalar(Flag, &common, f) != null or std.mem.indexOfScalar(Flag, s.flags, f) != null;
    }
};
// Commands that share a first word, such as `ec plugin list`.
const Group = struct { name: []const u8, description: []const u8, default: ?[]const u8 = null };
pub const groups = [_]Group{
    .{ .name = "plugin", .description = "List enabled plugins or update one from GitHub.", .default = "list" },
    .{ .name = "secret", .description = "Save, list, or remove secrets that plugin settings use." },
};
pub const specs = [_]Spec{
    .{
        .command = .sync,
        .words = "sync",
        .usage = "ec sync [options]",
        .description = "Pull the config repo and apply it to this machine.",
        .flags = &.{ .repo, .profile, .skip_packages, .update_skills, .all },
        .effects = &.{ "Applies the files, packages, setup steps, and plugins listed in ender-chest.toml, installs ec, and updates skill links. Preserves local credentials and settings.", "Pulls a clean checkout, using the primary worktree from a linked checkout. A dirty checkout or failed pull uses local files.", "Installs a newer ec release first, then resumes with it. Development builds are never replaced by a release. EC_NO_UPDATE=1 skips the release check.", "Installs packages unless --skip-packages is set.", "With --all, syncs this machine and every other reachable machine that is behind, one at a time over SSH, with ec sync --skip-packages. Skips machines that are current, offline, or unreachable. Any failed sync returns exit code 1." },
        .examples = &.{ "ec sync", "ec sync --skip-packages", "ec sync --all", "ec sync --repo ~/my-machine-config --profile cloud --json" },
    },
    .{
        .command = .push,
        .words = "push",
        .usage = "ec push [options]",
        .description = "Capture managed files, commit, and push.",
        .flags = &.{ .repo, .profile, .dry_run },
        .effects = &.{ "Writes captured files into the checkout, including with --dry-run.", "Commits and uploads managed changes unless --dry-run is set. Refuses unrelated staged files.", "Other machines update when you run ec sync there." },
        .examples = &.{ "ec push --dry-run", "ec push --json" },
        .notice = true,
    },
    .{
        .command = .verify,
        .words = "verify",
        .usage = "ec verify [options]",
        .description = "Check installed files and skill links without changing them.",
        .flags = &.{ .repo, .profile },
        .effects = &.{"Reads local files only. Missing files or broken links return exit code 1."},
        .examples = &.{ "ec verify", "ec verify --json" },
        .notice = true,
    },
    .{
        .command = .status,
        .words = "status",
        .usage = "ec status [options]",
        .description = "Show each machine's ec version and config commit.",
        .effects = &.{ "Lists your macOS and Linux machines from tailscale status, then reads ec --version over SSH.", "Compares each machine with the latest GitHub release and the config repo's main branch. Makes no changes. EC_NO_UPDATE=1 skips the release.", "Machines need SSH access: Remote Login on Macs, SSH or Tailscale SSH on Linux." },
        .examples = &.{ "ec status", "ec status --json" },
        .notice = true,
    },
    .{
        .command = .plugin_list,
        .words = "plugin list",
        .usage = "ec plugin list [options]",
        .description = "Show enabled plugins, their sources, and their commands.",
        .flags = &.{.repo},
        .effects = &.{ "Reads ender-chest.toml and installed plugins. Makes no changes.", "Notes settings and secrets that a plugin still needs." },
        .examples = &.{ "ec plugin list", "ec plugin list --json" },
        .notice = true,
    },
    .{
        .command = .plugin_update,
        .words = "plugin update",
        .usage = "ec plugin update NAME [options]",
        .description = "Move a GitHub plugin to the newest commit of its ref.",
        .flags = &.{.repo},
        .target = true,
        .effects = &.{ "Fetches the plugin, records the commit in ender-chest.lock, and prints a GitHub compare link.", "Review the changes, then commit the lock file. Other machines use the new commit after ec sync." },
        .examples = &.{ "ec plugin update backup", "ec plugin update backup --json" },
        .notice = true,
    },
    .{
        .command = .secret_set,
        .words = "secret set",
        .usage = "ec secret set NAME [options]",
        .description = "Save a secret on this machine for plugin settings to use.",
        .target = true,
        .effects = &.{ "Reads the value from a hidden prompt, or from stdin when piped. Never from arguments.", "Writes ~/.config/ender-chest/secrets/NAME with mode 0600. Reference it as { secret = \"NAME\" }. Run ec sync afterwards to update agent settings." },
        .examples = &.{ "ec secret set executor", "printf %s \"$TOKEN\" | ec secret set executor --json" },
        .notice = true,
    },
    .{
        .command = .secret_list,
        .words = "secret list",
        .usage = "ec secret list [options]",
        .description = "List the names of secrets saved on this machine.",
        .effects = &.{"Prints names only, never values."},
        .examples = &.{ "ec secret list", "ec secret list --json" },
        .notice = true,
    },
    .{
        .command = .secret_remove,
        .words = "secret remove",
        .usage = "ec secret remove NAME [options]",
        .description = "Delete a secret saved on this machine.",
        .target = true,
        .effects = &.{"Deletes ~/.config/ender-chest/secrets/NAME. Settings that use it are skipped on the next sync."},
        .examples = &.{"ec secret remove executor"},
        .notice = true,
    },
    .{
        .command = .update,
        .words = "update",
        .usage = "ec update [options]",
        .description = "Install the latest ec release.",
        .flags = &.{.check},
        .effects = &.{ "Replaces the ec you ran after checking the download's sha256 and running it once. A failed step leaves the old binary in place.", "For an npm tarball installation or a project dependency, prints the command to run instead. A development build prints the installer command.", "Interactive commands also say once a day when a newer release exists. EC_NO_UPDATE=1 or NO_UPDATE_NOTIFIER=1 turns that off, as do CI, --json, and output that is not a terminal." },
        .examples = &.{ "ec update", "ec update --check", "ec update --check --json" },
    },
    // Run as the option --version, so help lists it with the options.
    .{
        .command = .version,
        .words = "version",
        .usage = "ec --version",
        .description = "Show the CLI version.",
        .effects = &.{"Reads no config and makes no changes."},
        .examples = &.{ "ec --version", "ec --version --json" },
    },
};
// Options a plugin call takes before the plugin's name; the plugin reads everything after it.
const call_flags = [_]Flag{.repo};
// Said after "--FLAG is only available with..." when a command does not take FLAG, or, with a
// command, only for that command.
const Hint = struct { flag: Flag, command: ?Command = null, text: []const u8 };
const hints = [_]Hint{
    .{ .flag = .dry_run, .text = "It still captures files into the checkout." },
    .{ .flag = .repo, .command = .update, .text = "It updates the ec binary you ran." },
    .{ .flag = .repo, .command = .status, .text = "ec status reads machines from Tailscale." },
};

pub fn spec(command: Command) ?Spec {
    for (specs) |s| if (s.command == command) return s;
    return null;
}
pub fn isHelp(arg: []const u8) bool {
    return eq(u8, arg, "--help") or eq(u8, arg, "-h") or eq(u8, arg, "help");
}

pub const Options = struct {
    command: Command = .help,
    // The words typed before any NAME, such as "plugin" or "plugin update". Help reads them.
    words: []const u8 = "",
    target: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    skip_packages: bool = false,
    update_skills: bool = false,
    all: bool = false,
    dry_run: bool = false,
    check: bool = false,
    json: bool = false,
    help: bool = false,
    // A plugin call's plugin name and its unparsed arguments. For `ec __plugin`, `rest` holds
    // everything after __plugin.
    name: []const u8 = "",
    rest: []const []const u8 = &.{},
    // Each Flag has a field of the same name: a bool for a boolean option, an optional string
    // for a string option.
    fn set(o: Options, f: Flag) bool {
        return switch (f) {
            inline else => |tag| {
                const v = @field(o, @tagName(tag));
                return if (@TypeOf(v) == bool) v else v != null;
            },
        };
    }
    fn value(o: Options, f: Flag) ?[]const u8 {
        return switch (f) {
            inline else => |tag| {
                const v = @field(o, @tagName(tag));
                return if (@TypeOf(v) == bool) null else v;
            },
        };
    }
};
comptime {
    for (std.meta.tags(Flag)) |f| {
        if ((@FieldType(Options, @tagName(f)) == bool) != (flags.get(f).option.kind == .boolean)) @compileError("Options." ++ @tagName(f) ++ " does not match its option kind");
    }
}
// Why parsing failed, and whether the user asked for JSON, so the error can be reported as JSON.
pub const Diagnostic = struct { message: []const u8 = "", json: bool = false };

pub fn parse(a: std.mem.Allocator, args: []const []const u8, diagnostic: *Diagnostic) !Options {
    for (args) |arg| if (eq(u8, arg, "--json")) {
        diagnostic.json = true;
    };
    var o: Options = .{};
    if (args.len > 0 and eq(u8, args[0], "__plugin")) {
        o.command = .builtin;
        o.rest = args[1..];
        return o;
    }
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelp(arg)) {
            o.help = true;
            continue;
        }
        if (eq(u8, arg, "--version")) {
            if (words.items.len > 0 or o.command == .version) return usage(diagnostic, "Use --version on its own.");
            o.command = .version;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            const body = arg[2..];
            const eqpos = std.mem.indexOfScalar(u8, body, '=');
            const f = flagNamed(body[0 .. eqpos orelse body.len]) orelse return usage(diagnostic, try std.fmt.allocPrint(a, "Unknown option {s}. Run ec --help for available options.", .{arg}));
            const info = flags.get(f);
            if (info.option.kind == .boolean) {
                if (eqpos != null) return usage(diagnostic, try std.fmt.allocPrint(a, "--{s} takes no value.", .{info.option.name}));
                setFlag(&o, f, null);
                continue;
            }
            const value = if (eqpos) |pos| body[pos + 1 ..] else blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else "";
            };
            if (value.len == 0 or value[0] == '-') return usage(diagnostic, info.missing);
            setFlag(&o, f, value);
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return usage(diagnostic, try std.fmt.allocPrint(a, "Unknown option {s}. Run ec --help for available options.", .{arg}));
        if (o.command == .call or o.command == .version) return usage(diagnostic, "Unknown command or option. Run ec --help for available commands.");
        if (words.items.len == 0) {
            if (findGroup(arg) == null and find(arg) == null) {
                if (!plugin_manifest.pluginName(arg)) return usage(diagnostic, "Unknown command. Run ec --help for available commands.");
                o.command = .call;
                o.name = arg;
                o.rest = args[i + 1 ..];
                break;
            }
            try words.append(a, arg);
            continue;
        }
        const group = findGroup(words.items[0]);
        if (group != null and words.items.len == 1) {
            const g = group.?;
            try words.append(a, arg);
            if (find(try std.mem.join(a, " ", words.items)) == null) return usage(diagnostic, try std.fmt.allocPrint(a, "Unknown {s} command. Use {s}. Run ec {s} --help.", .{ g.name, try actionList(a, g.name), g.name }));
            continue;
        }
        const s = find(try std.mem.join(a, " ", words.items));
        if (s != null and s.?.target and o.target == null) {
            o.target = arg;
            continue;
        }
        return usage(diagnostic, "Unknown command or option. Run ec --help for available commands.");
    }
    o.words = try std.mem.join(a, " ", words.items);
    if (o.command == .call) return check(a, o, &call_flags, diagnostic);
    if (o.command != .version and words.items.len > 0) {
        if (findGroup(o.words)) |g| {
            if (o.help) return o;
            const default = g.default orelse return usage(diagnostic, try std.fmt.allocPrint(a, "ec {s} needs {s}. Run ec {s} --help.", .{ g.name, try actionList(a, g.name), g.name }));
            o.words = try std.fmt.allocPrint(a, "{s} {s}", .{ g.name, default });
        }
        o.command = find(o.words).?.command;
    }
    if (o.help) return o;
    if (o.command == .help) return check(a, o, &call_flags, diagnostic);
    const s = spec(o.command).?;
    if (s.target and o.target == null) return usage(diagnostic, try std.fmt.allocPrint(a, "ec {s} needs a NAME, as in {s}.", .{ s.words, s.examples[0] }));
    return check(a, o, s.flags, diagnostic);
}
fn check(a: std.mem.Allocator, o: Options, allowed: []const Flag, diagnostic: *Diagnostic) !Options {
    for (std.meta.tags(Flag)) |f| if (o.set(f) and std.mem.indexOfScalar(Flag, &common, f) == null) {
        if (std.mem.indexOfScalar(Flag, allowed, f) == null) return usage(diagnostic, try scope(a, f, o.command));
        if (flags.get(f).alone) |why| for (std.meta.tags(Flag)) |other| {
            if (other != f and o.set(other) and std.mem.indexOfScalar(Flag, &common, other) == null) return usage(diagnostic, why);
        };
    };
    return o;
}
fn scope(a: std.mem.Allocator, f: Flag, command: Command) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (specs) |s| if (std.mem.indexOfScalar(Flag, s.flags, f) != null) try names.append(a, try std.fmt.allocPrint(a, "ec {s}", .{s.words}));
    const name = flags.get(f).option.name;
    const message = if (names.items.len == 1)
        try std.fmt.allocPrint(a, "--{s} is only available with {s}.", .{ name, names.items[0] })
    else
        try std.fmt.allocPrint(a, "--{s} applies to {s}.", .{ name, try series(a, names.items, "and") });
    for (hints) |h| if (h.flag == f and (h.command == null or h.command.? == command)) return std.fmt.allocPrint(a, "{s} {s}", .{ message, h.text });
    return message;
}
fn actionList(a: std.mem.Allocator, group: []const u8) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (specs) |s| if (eq(u8, s.group(), group) and s.action().len > 0) try names.append(a, s.action());
    return series(a, names.items, "or");
}
// "a or b", "a, b, or c".
fn series(a: std.mem.Allocator, items: []const []const u8, last: []const u8) ![]const u8 {
    if (items.len == 2) return std.fmt.allocPrint(a, "{s} {s} {s}", .{ items[0], last, items[1] });
    if (items.len < 2) return std.mem.join(a, "", items);
    return std.fmt.allocPrint(a, "{s}, {s} {s}", .{ try std.mem.join(a, ", ", items[0 .. items.len - 1]), last, items[items.len - 1] });
}
fn usage(diagnostic: *Diagnostic, message: []const u8) error{InvalidArguments} {
    diagnostic.message = message;
    return error.InvalidArguments;
}
fn flagNamed(name: []const u8) ?Flag {
    for (std.meta.tags(Flag)) |f| if (eq(u8, flags.get(f).option.name, name)) return f;
    return null;
}
fn setFlag(o: *Options, f: Flag, text: ?[]const u8) void {
    switch (f) {
        inline else => |tag| {
            const field = &@field(o, @tagName(tag));
            field.* = if (@TypeOf(field.*) == bool) true else text;
        },
    }
}
pub fn find(words: []const u8) ?Spec {
    for (specs) |s| if (eq(u8, s.words, words) and s.command != .version) return s;
    return null;
}
fn findGroup(word: []const u8) ?Group {
    for (groups) |g| if (eq(u8, g.name, word)) return g;
    return null;
}

// The name a result or error reports for the command, such as "secret set" or "wol wake".
pub fn label(a: std.mem.Allocator, o: Options) []const u8 {
    return switch (o.command) {
        .help => "help",
        .call => if (o.rest.len > 0 and o.rest[0].len > 0 and o.rest[0][0] != '-') std.fmt.allocPrint(a, "{s} {s}", .{ o.name, o.rest[0] }) catch o.name else o.name,
        .builtin => if (o.rest.len > 1) std.fmt.allocPrint(a, "{s} {s}", .{ o.rest[0], o.rest[1] }) catch "plugin" else "plugin",
        else => spec(o.command).?.words,
    };
}
// The argv that runs the same command again with `exe`.
pub fn argv(a: std.mem.Allocator, exe: []const u8, o: Options) ![]const []const u8 {
    const s = spec(o.command).?;
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, exe);
    var it = std.mem.splitScalar(u8, s.words, ' ');
    while (it.next()) |w| try out.append(a, w);
    if (o.target) |t| try out.append(a, t);
    for (std.meta.tags(Flag)) |f| if (f != .help and s.takes(f) and o.set(f)) {
        try out.append(a, try std.fmt.allocPrint(a, "--{s}", .{flags.get(f).option.name}));
        if (o.value(f)) |v| try out.append(a, v);
    };
    return out.items;
}

fn rejects(args: []const []const u8, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    try std.testing.expectError(error.InvalidArguments, parse(arena.allocator(), args, &d));
    if (std.mem.indexOf(u8, d.message, message) == null) {
        std.debug.print("{s}: {s}\n", .{ args[0], d.message });
        return error.TestUnexpectedResult;
    }
}
test "commands, groups, plugin calls, and the options each command takes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostic = .{};
    try rejects(&.{ "sync", "--all", "--skip-packages" }, "takes no other options");
    try rejects(&.{ "status", "--repo", "x" }, "ec status reads machines from Tailscale.");
    try rejects(&.{"Desktop"}, "Unknown command.");
    try rejects(&.{ "secret", "set" }, "ec secret set needs a NAME, as in ec secret set executor.");
    try rejects(&.{"secret"}, "ec secret needs set, list, or remove.");
    try rejects(&.{ "plugin", "remove" }, "Unknown plugin command. Use list or update.");
    try rejects(&.{ "sync", "--version" }, "Use --version on its own.");
    try std.testing.expect((try parse(a, &.{ "sync", "--all" }, &d)).all);
    try std.testing.expectEqual(Command.plugin_list, (try parse(a, &.{"plugin"}, &d)).command);
    try std.testing.expectEqualStrings("executor", (try parse(a, &.{ "secret", "set", "executor" }, &d)).target.?);
    const help = try parse(a, &.{ "plugin", "--help" }, &d);
    try std.testing.expect(help.help and eq(u8, help.words, "plugin"));
    const call = try parse(a, &.{ "--json", "wol", "wake", "--via", "user@relay", "--help" }, &d);
    try std.testing.expect(call.command == .call and call.json and !call.help and eq(u8, call.name, "wol") and call.rest.len == 4);
    const passed = try parse(a, &.{ "cliproxyapi", "run", "tool", "--json", "-x" }, &d);
    try std.testing.expect(!passed.json and passed.rest.len == 4);
    const builtin = try parse(a, &.{ "__plugin", "wol", "status" }, &d);
    try std.testing.expect(builtin.command == .builtin and builtin.rest.len == 2);
}
test "a parsed command serializes to an argv that parses back the same" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostic = .{};
    const o = try parse(a, &.{ "--json", "sync", "--update-skills", "--profile=cloud", "--repo", "/r" }, &d);
    const out = try argv(a, "ec", o);
    try std.testing.expectEqualStrings("ec", out[0]);
    const again = try parse(a, out[1..], &d);
    try std.testing.expectEqual(o.command, again.command);
    for (std.meta.tags(Flag)) |f| {
        try std.testing.expectEqual(o.set(f), again.set(f));
        try std.testing.expectEqualStrings(o.value(f) orelse "", again.value(f) orelse "");
    }
}
