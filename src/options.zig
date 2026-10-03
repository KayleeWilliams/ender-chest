const std = @import("std");
const core = @import("core.zig");
const eq = core.eql;
pub const Options = struct {
    command: enum { help, version, sync, push, verify, desktop, fleet, cliproxy } = .help,
    action: enum { help, start, stop, status, auth, sync, url, models, restart, run, setup } = .help,
    json: bool = false,
    show_help: bool = false,
    profile: []const u8 = "",
    repo: ?[]const u8 = null,
    skip_packages: bool = false,
    update_skills: bool = false,
    dry_run: bool = false,
    local: bool = false,
    setup: bool = false,
    forget: bool = false,
    no_wait: bool = false,
    no_auth: bool = false,
    via: ?[]const u8 = null,
    url: ?[]const u8 = null,
    key_stdin: bool = false,
    // The command and arguments after ec cliproxy run, passed through untouched.
    rest: []const []const u8 = &.{},
};
pub fn parse(args: []const []const u8) !Options {
    var diagnostic: []const u8 = "";
    return parseDetailed(args, &diagnostic);
}
pub fn parseDetailed(args: []const []const u8, diagnostic: *[]const u8) !Options {
    diagnostic.* = "Invalid arguments. Use ec --help for commands and options.";
    var o: Options = .{};
    var i: usize = 0;
    var command = false;
    var action = false;

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
        if (eq(u8, arg, "--key-stdin")) {
            o.key_stdin = true;
            continue;
        }
        if (eq(u8, arg, "--url")) {
            i += 1;
            if (i == args.len or args[i].len == 0 or args[i][0] == '-') {
                diagnostic.* = "--url needs a proxy endpoint without /v1.";
                return error.MissingValue;
            }
            o.url = args[i];
            continue;
        }
        if (eq(u8, arg, "--repo") or eq(u8, arg, "--profile") or eq(u8, arg, "--via")) {
            i += 1;
            if (i == args.len or args[i].len == 0 or std.mem.startsWith(u8, args[i], "-")) {
                diagnostic.* = if (eq(u8, arg, "--repo")) "--repo needs a checkout path." else if (eq(u8, arg, "--profile")) "--profile needs mac or cloud." else "--via needs an SSH hostname or USER@HOST.";
                return error.MissingValue;
            }
            if (eq(u8, arg, "--repo")) o.repo = args[i] else if (eq(u8, arg, "--profile")) o.profile = args[i] else o.via = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--profile=")) {
            o.profile = arg[10..];
            if (o.profile.len == 0) {
                diagnostic.* = "--profile needs mac or cloud.";
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
        if (eq(u8, arg, "--local")) {
            o.local = true;
            continue;
        }
        if (eq(u8, arg, "--setup")) {
            o.setup = true;
            continue;
        }
        if (eq(u8, arg, "--forget")) {
            o.forget = true;
            continue;
        }
        if (eq(u8, arg, "--no-wait")) {
            o.no_wait = true;
            continue;
        }
        if (eq(u8, arg, "--no-auth")) {
            o.no_auth = true;
            continue;
        }
        diagnostic.* = "Unknown command or option. Run ec --help for available commands.";
        if (!command) {
            o.command = if (eq(u8, arg, "sync")) .sync else if (eq(u8, arg, "push") or eq(u8, arg, "--push")) .push else if (eq(u8, arg, "verify") or eq(u8, arg, "--verify")) .verify else if (eq(u8, arg, "desktop")) .desktop else if (eq(u8, arg, "fleet")) .fleet else if (eq(u8, arg, "cliproxy")) .cliproxy else return error.UnknownArgument;
            command = true;
            continue;
        }
        if (o.command == .desktop and !action) {
            o.action = if (eq(u8, arg, "start")) .start else if (eq(u8, arg, "stop")) .stop else if (eq(u8, arg, "status")) .status else if (eq(u8, arg, "auth")) .auth else {
                diagnostic.* = "Unknown desktop command. Use start, stop, status, or auth. Run ec desktop --help.";
                return error.UnknownArgument;
            };
            action = true;
            continue;
        }
        if (o.command == .fleet and !action) {
            o.action = if (eq(u8, arg, "status")) .status else if (eq(u8, arg, "sync")) .sync else {
                diagnostic.* = "Unknown fleet command. Use status or sync. Run ec fleet --help.";
                return error.UnknownArgument;
            };
            action = true;
            continue;
        }
        if (o.command == .cliproxy and !action) {
            o.action = if (eq(u8, arg, "setup")) .setup else if (eq(u8, arg, "url")) .url else if (eq(u8, arg, "models")) .models else if (eq(u8, arg, "restart")) .restart else if (eq(u8, arg, "run")) .run else {
                diagnostic.* = "Unknown cliproxy command. Use setup, url, models, restart, or run. Run ec cliproxy --help.";
                return error.UnknownArgument;
            };
            action = true;
            if (o.action == .run) {
                o.rest = args[i + 1 ..];
                break;
            }
            continue;
        }
        return error.UnknownArgument;
    }
    if (o.profile.len > 0 and !eq(u8, o.profile, "mac") and !eq(u8, o.profile, "cloud")) {
        diagnostic.* = "Invalid --profile. Choose mac or cloud.";
        return error.InvalidProfile;
    }
    if (!command and (o.skip_packages or o.update_skills)) o.command = .sync;
    if (o.show_help) return o;
    if ((o.url != null or o.key_stdin) and !(o.command == .cliproxy and o.action == .setup)) {
        diagnostic.* = "--url and --key-stdin require ec cliproxy setup.";
        return error.InvalidArguments;
    }
    if (o.dry_run and o.command != .push) {
        diagnostic.* = "--dry-run is only available with ec push. It still captures files into the checkout.";
        return error.InvalidArguments;
    }
    if ((o.skip_packages or o.update_skills) and o.command != .sync) {
        diagnostic.* = "--skip-packages and --update-skills are only available with ec sync.";
        return error.InvalidArguments;
    }
    if (o.command == .fleet and o.action == .help) o.action = .status;
    const desktop_flags = o.local or o.setup or o.forget or o.no_wait or o.no_auth or o.via != null;
    if (o.command == .desktop) {
        if (o.profile.len > 0 or o.repo != null) {
            diagnostic.* = "--profile and --repo apply to sync, push, and verify. Desktop commands use DESKTOP_CONFIG.";
            return error.InvalidArguments;
        }
        switch (o.action) {
            .start => {
                if (o.setup or o.forget or (o.local and o.via != null)) {
                    diagnostic.* = "Use ec desktop start with either --local or --via USER@HOST. --setup and --forget belong to desktop auth.";
                    return error.InvalidArguments;
                }
            },
            .stop => {
                if (o.local or o.setup or o.forget or o.no_auth or o.via != null) {
                    diagnostic.* = "ec desktop stop only accepts --no-wait. Run ec desktop stop --help.";
                    return error.InvalidArguments;
                }
            },
            .auth => {
                if (o.no_wait or o.no_auth or o.via != null or @as(u8, @intFromBool(o.local)) + @as(u8, @intFromBool(o.setup)) + @as(u8, @intFromBool(o.forget)) > 1) {
                    diagnostic.* = "Use only one of --local, --setup, or --forget with ec desktop auth. --via belongs to desktop start.";
                    return error.InvalidArguments;
                }
            },
            else => if (desktop_flags) {
                diagnostic.* = "Use ec desktop start --help or ec desktop auth --help for desktop options.";
                return error.InvalidArguments;
            },
        }
    } else if (desktop_flags) {
        diagnostic.* = "--local, --via, --setup, --forget, --no-wait, and --no-auth require a desktop command. Run ec desktop --help.";
        return error.InvalidArguments;
    } else if (o.command == .fleet and (o.profile.len > 0 or o.repo != null)) {
        diagnostic.* = "--profile and --repo apply to sync, push, and verify. Fleet reads machines from Tailscale.";
        return error.InvalidArguments;
    } else if (o.command == .cliproxy and (o.profile.len > 0 or o.repo != null)) {
        diagnostic.* = "--profile and --repo apply to sync, push, and verify. cliproxy reads ~/.config/cliproxyapi/client.json.";
        return error.InvalidArguments;
    } else if (o.command == .cliproxy and o.action == .run and o.rest.len == 0) {
        diagnostic.* = "ec cliproxy run needs a command, as in ec cliproxy run codex.";
        return error.InvalidArguments;
    }
    return o;
}
test "reject ambiguous commands and missing option values" {
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "desktop", "start", "--local", "--via", "relay" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "sync", "--profile" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "verify", "--dry-run" }));
    try std.testing.expectError(error.UnknownArgument, parse(&.{ "desktop", "halt" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "desktop", "stop", "--local" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "fleet", "--no-wait" }));
    try std.testing.expect((try parse(&.{"fleet"})).action == .status);
    try std.testing.expect((try parse(&.{ "fleet", "sync" })).action == .sync);
    try std.testing.expect((try parse(&.{ "desktop", "stop", "--no-wait" })).no_wait);
    try std.testing.expectError(error.UnknownArgument, parse(&.{ "cliproxy", "reload" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "cliproxy", "run" }));
    const proxied = try parse(&.{ "cliproxy", "run", "tool", "--json", "--help", "-x" });
    try std.testing.expect(proxied.action == .run and !proxied.json and !proxied.show_help and proxied.rest.len == 4);
    const o = try parse(&.{ "--json", "desktop", "start", "--via", "user@relay" });
    try std.testing.expect(o.json and o.command == .desktop and eq(u8, o.via.?, "user@relay"));
}
