const std = @import("std");
const core = @import("core.zig");
const eq = core.eql;

pub const Command = enum { help, version, sync, push, verify, status, plugin, secret, update, builtin, call };
pub const Options = struct {
    command: Command = .help,
    // Subcommand of plugin or secret.
    action: []const u8 = "",
    // NAME for plugin update, secret set, and secret remove.
    target: ?[]const u8 = null,
    json: bool = false,
    show_help: bool = false,
    profile: []const u8 = "",
    repo: ?[]const u8 = null,
    skip_packages: bool = false,
    update_skills: bool = false,
    dry_run: bool = false,
    // ec sync --all syncs every machine in the tailnet.
    all: bool = false,
    // ec update --check reports without installing.
    check: bool = false,
    // For .call, the plugin name; its arguments follow in rest, unparsed. For .builtin, rest
    // holds everything after __plugin.
    name: []const u8 = "",
    rest: []const []const u8 = &.{},
};
const actions = [_]struct { command: Command, names: []const []const u8, target: enum { none, optional, required } }{
    .{ .command = .plugin, .names = &.{"list"}, .target = .none },
    .{ .command = .plugin, .names = &.{"update"}, .target = .required },
    .{ .command = .secret, .names = &.{"list"}, .target = .none },
    .{ .command = .secret, .names = &.{ "set", "remove" }, .target = .required },
};
pub fn parse(args: []const []const u8) !Options {
    var diagnostic: []const u8 = "";
    return parseDetailed(args, &diagnostic);
}
pub fn parseDetailed(args: []const []const u8, diagnostic: *[]const u8) !Options {
    diagnostic.* = "Invalid arguments. Use ec --help for commands and options.";
    var o: Options = .{};
    if (args.len > 0 and eq(u8, args[0], "__plugin")) {
        o.command = .builtin;
        o.rest = args[1..];
        return o;
    }
    var i: usize = 0;
    var command = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(u8, arg, "--json")) {
            o.json = true;
            continue;
        }
        if (eq(u8, arg, "--help") or eq(u8, arg, "-h") or eq(u8, arg, "help")) {
            o.show_help = true;
            continue;
        }
        if (eq(u8, arg, "--version")) {
            if (command) {
                diagnostic.* = "Use --version on its own.";
                return error.InvalidArguments;
            }
            o.command = .version;
            command = true;
            continue;
        }
        if (eq(u8, arg, "--repo") or eq(u8, arg, "--profile")) {
            i += 1;
            if (i == args.len or args[i].len == 0 or std.mem.startsWith(u8, args[i], "-")) {
                diagnostic.* = if (eq(u8, arg, "--repo")) "--repo needs a checkout path." else "--profile needs a profile name, such as mac or cloud.";
                return error.MissingValue;
            }
            if (eq(u8, arg, "--repo")) o.repo = args[i] else o.profile = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--profile=")) {
            o.profile = arg[10..];
            if (o.profile.len == 0) {
                diagnostic.* = "--profile needs a profile name, such as mac or cloud.";
                return error.InvalidProfile;
            }
            continue;
        }
        if (eq(u8, arg, "--skip-packages")) {
            o.skip_packages = true;
            continue;
        }
        if (eq(u8, arg, "--update-skills")) {
            o.update_skills = true;
            continue;
        }
        if (eq(u8, arg, "--dry-run")) {
            o.dry_run = true;
            continue;
        }
        if (eq(u8, arg, "--check")) {
            o.check = true;
            continue;
        }
        if (eq(u8, arg, "--all")) {
            o.all = true;
            continue;
        }
        if (!command) {
            if (std.mem.startsWith(u8, arg, "-")) {
                diagnostic.* = "Unknown option. Run ec --help for available options.";
                return error.UnknownArgument;
            }
            command = true;
            o.command = if (eq(u8, arg, "sync")) .sync else if (eq(u8, arg, "push") or eq(u8, arg, "--push")) .push else if (eq(u8, arg, "verify")) .verify else if (eq(u8, arg, "status")) .status else if (eq(u8, arg, "plugin")) .plugin else if (eq(u8, arg, "secret")) .secret else if (eq(u8, arg, "update")) .update else if (@import("manifest.zig").pluginName(arg)) .call else {
                diagnostic.* = "Unknown command. Run ec --help for available commands.";
                return error.UnknownArgument;
            };
            if (o.command == .call) {
                // The plugin's manifest decides what its arguments mean.
                o.name = arg;
                o.rest = args[i + 1 ..];
                break;
            }
            continue;
        }
        if ((o.command == .plugin or o.command == .secret) and o.action.len == 0) {
            const known = outer: for (actions) |entry| {
                if (entry.command != o.command) continue;
                for (entry.names) |n| if (eq(u8, n, arg)) break :outer true;
            } else false;
            if (!known) {
                diagnostic.* = switch (o.command) {
                    .plugin => "Unknown plugin command. Use list or update. Run ec plugin --help.",
                    else => "Unknown secret command. Use set, list, or remove. Run ec secret --help.",
                };
                return error.UnknownArgument;
            }
            o.action = arg;
            continue;
        }
        if ((o.command == .plugin or o.command == .secret) and o.action.len > 0 and o.target == null and !std.mem.startsWith(u8, arg, "-")) {
            o.target = arg;
            continue;
        }
        diagnostic.* = "Unknown command or option. Run ec --help for available commands.";
        return error.UnknownArgument;
    }
    if (!command and (o.skip_packages or o.update_skills)) o.command = .sync;
    if (o.show_help) return o;
    if (o.dry_run and o.command != .push) {
        diagnostic.* = "--dry-run is only available with ec push. It still captures files into the checkout.";
        return error.InvalidArguments;
    }
    if (o.all and o.command != .sync) {
        diagnostic.* = "--all is only available with ec sync.";
        return error.InvalidArguments;
    }
    if (o.all and (o.repo != null or o.profile.len > 0 or o.skip_packages or o.update_skills)) {
        diagnostic.* = "ec sync --all runs ec sync --skip-packages on each machine and takes no other options except --json.";
        return error.InvalidArguments;
    }
    if (o.check and o.command != .update) {
        diagnostic.* = "--check is only available with ec update.";
        return error.InvalidArguments;
    }
    if ((o.skip_packages or o.update_skills) and o.command != .sync) {
        diagnostic.* = "--skip-packages and --update-skills are only available with ec sync.";
        return error.InvalidArguments;
    }
    if (o.profile.len > 0 and o.command != .sync and o.command != .push and o.command != .verify) {
        diagnostic.* = "--profile applies to sync, push, and verify.";
        return error.InvalidArguments;
    }
    if (o.command == .update and o.repo != null) {
        diagnostic.* = "--repo does not apply to ec update. It updates the ec binary you ran.";
        return error.InvalidArguments;
    }
    if (o.command == .status and o.repo != null) {
        diagnostic.* = "--repo applies to sync, push, verify, and plugins. ec status reads machines from Tailscale.";
        return error.InvalidArguments;
    }
    if (o.command == .plugin and o.action.len == 0) o.action = "list";
    if (o.command == .secret and o.action.len == 0) {
        diagnostic.* = "ec secret needs set, list, or remove. Run ec secret --help.";
        return error.InvalidArguments;
    }
    for (actions) |entry| {
        if (entry.command != o.command) continue;
        for (entry.names) |n| if (eq(u8, n, o.action) and entry.target == .required and o.target == null) {
            diagnostic.* = "This command needs a NAME, as in ec secret set executor or ec plugin update backup.";
            return error.InvalidArguments;
        };
    }
    return o;
}
test "core commands, plugin calls, and bad arguments" {
    try std.testing.expectError(error.MissingValue, parse(&.{ "sync", "--profile" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "verify", "--dry-run" }));
    try std.testing.expectError(error.UnknownArgument, parse(&.{ "status", "--no-wait" }));
    try std.testing.expectError(error.UnknownArgument, parse(&.{ "status", "sync" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "verify", "--all" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "sync", "--all", "--skip-packages" }));
    try std.testing.expect((try parse(&.{ "sync", "--all" })).all);
    try std.testing.expect((try parse(&.{"status"})).command == .status);
    try std.testing.expectError(error.UnknownArgument, parse(&.{"Desktop"}));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "secret", "set" }));
    try std.testing.expect(eq(u8, (try parse(&.{ "secret", "set", "executor" })).target.?, "executor"));
    const call = try parse(&.{ "--json", "wol", "wake", "--via", "user@relay", "--help" });
    try std.testing.expect(call.command == .call and call.json and !call.show_help and eq(u8, call.name, "wol") and call.rest.len == 4);
    const passed = try parse(&.{ "cliproxyapi", "run", "tool", "--json", "-x" });
    try std.testing.expect(!passed.json and passed.rest.len == 4);
    try std.testing.expect((try parse(&.{ "update", "--check" })).command == .update);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "verify", "--check" }));
    const builtin = try parse(&.{ "__plugin", "wol", "status" });
    try std.testing.expect(builtin.command == .builtin and builtin.rest.len == 2);
}
