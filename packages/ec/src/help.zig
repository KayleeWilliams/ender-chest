const std = @import("std");
const core = @import("core.zig");
const Options = @import("options.zig").Options;
const plugin = @import("plugin.zig");

pub const Option = struct {
    name: []const u8,
    type: enum { boolean, string } = .boolean,
    description: []const u8,
    values: []const []const u8 = &.{},
    default: ?[]const u8 = null,
    required: bool = false,
};
pub const Definition = struct {
    command: []const u8,
    action: []const u8 = "",
    // Set for plugin commands: "built-in", a config repo path, or owner/repo#ref.
    plugin: ?[]const u8 = null,
    usage: []const u8,
    description: []const u8,
    options: []const Option,
    effects: []const []const u8,
    examples: []const []const u8,
};
const common = [_]Option{
    .{ .name = "json", .description = "One JSON result on stdout; diagnostics on stderr." },
    .{ .name = "help", .description = "Show help for this command. Alias: -h." },
};
const config = [_]Option{
    .{ .name = "repo", .type = .string, .description = "Config checkout path.", .default = "EC_REPO, current or saved checkout; linked worktrees use the primary checkout" },
    .{ .name = "profile", .type = .string, .description = "Override the detected machine profile. ender-chest.toml filters files and steps by profile name.", .default = "mac on macOS, cloud in CI, containers, and Linux" },
};
const definitions = [_]Definition{
    .{
        .command = "sync",
        .usage = "ec sync [options]",
        .description = "Pull the config repo and apply it to this machine.",
        .options = &(config ++ [_]Option{
            .{ .name = "skip-packages", .description = "Skip package installs and shell setup." },
            .{ .name = "update-skills", .description = "Refresh third-party skills from their Git repositories." },
        } ++ common),
        .effects = &.{ "Applies the files, packages, setup steps, and plugins listed in ender-chest.toml, installs ec, and updates skill links. Preserves local credentials and settings.", "Pulls a clean checkout, using the primary worktree from a linked checkout. A dirty checkout or failed pull uses local files.", "When Zig sources change, installs the matching GitHub release, or rebuilds with Zig if that download fails. EC_NO_UPDATE=1 skips the release check. Plugin commands do not check.", "Installs packages unless --skip-packages is set." },
        .examples = &.{ "ec sync", "ec sync --skip-packages", "ec sync --repo ~/dev/ender-chest --profile cloud --json" },
    },
    .{
        .command = "push",
        .usage = "ec push [options]",
        .description = "Capture managed files, commit, and push.",
        .options = &(config ++ [_]Option{.{ .name = "dry-run", .description = "Capture files into the checkout without staging, committing, or pushing." }} ++ common),
        .effects = &.{ "Writes captured files into the checkout, including with --dry-run.", "Commits and uploads managed changes unless --dry-run is set. Refuses unrelated staged files.", "Other machines update when you run ec sync there." },
        .examples = &.{ "ec push --dry-run", "ec push --json" },
    },
    .{
        .command = "verify",
        .usage = "ec verify [options]",
        .description = "Check installed files and skill links without changing them.",
        .options = &(config ++ common),
        .effects = &.{"Reads local files only. Missing files or broken links return exit code 1."},
        .examples = &.{ "ec verify", "ec verify --json" },
    },
    .{
        .command = "fleet",
        .action = "status",
        .usage = "ec fleet status [options]",
        .description = "Show each machine's ec version and config commit.",
        .options = &common,
        .effects = &.{ "ec fleet alone runs status. Lists your macOS and Linux machines from tailscale status, then reads ec --version over SSH.", "Compares each machine with the latest GitHub release and the config repo's main branch. Makes no changes.", "Machines need SSH access: Remote Login on Macs, SSH or Tailscale SSH on Linux." },
        .examples = &.{ "ec fleet", "ec fleet status --json" },
    },
    .{
        .command = "fleet",
        .action = "sync",
        .usage = "ec fleet sync [options]",
        .description = "Run ec sync --skip-packages on every machine that is behind.",
        .options = &common,
        .effects = &.{ "Syncs this machine locally and other reachable machines over SSH, one at a time. Each sync overwrites that machine's managed home files.", "Skips machines that are current, offline, or unreachable. Any failed sync returns exit code 1." },
        .examples = &.{ "ec fleet sync", "ec fleet sync --json" },
    },
    .{
        .command = "plugin",
        .action = "list",
        .usage = "ec plugin list [options]",
        .description = "Show enabled plugins, their sources, and their commands.",
        .options = &([_]Option{config[0]} ++ common),
        .effects = &.{ "Reads ender-chest.toml and installed plugins. Makes no changes.", "Notes settings and secrets that a plugin still needs." },
        .examples = &.{ "ec plugin list", "ec plugin list --json" },
    },
    .{
        .command = "plugin",
        .action = "update",
        .usage = "ec plugin update NAME [options]",
        .description = "Move a GitHub plugin to the newest commit of its ref.",
        .options = &([_]Option{config[0]} ++ common),
        .effects = &.{ "Fetches the plugin, records the commit in ender-chest.lock, and prints a GitHub compare link.", "Review the changes, then commit the lock file. Other machines use the new commit after ec sync." },
        .examples = &.{ "ec plugin update backup", "ec plugin update backup --json" },
    },
    .{
        .command = "secret",
        .action = "set",
        .usage = "ec secret set NAME [options]",
        .description = "Save a secret on this machine for plugin settings to use.",
        .options = &common,
        .effects = &.{ "Reads the value from a hidden prompt, or from stdin when piped. Never from arguments.", "Writes ~/.config/ender-chest/secrets/NAME with mode 0600. Reference it as { secret = \"NAME\" }. Run ec sync afterwards to update agent settings." },
        .examples = &.{ "ec secret set executor", "printf %s \"$TOKEN\" | ec secret set executor --json" },
    },
    .{
        .command = "secret",
        .action = "list",
        .usage = "ec secret list [options]",
        .description = "List the names of secrets saved on this machine.",
        .options = &common,
        .effects = &.{"Prints names only, never values."},
        .examples = &.{ "ec secret list", "ec secret list --json" },
    },
    .{
        .command = "secret",
        .action = "remove",
        .usage = "ec secret remove NAME [options]",
        .description = "Delete a secret saved on this machine.",
        .options = &common,
        .effects = &.{"Deletes ~/.config/ender-chest/secrets/NAME. Settings that use it are skipped on the next sync."},
        .examples = &.{"ec secret remove executor"},
    },
    .{
        .command = "version",
        .usage = "ec --version",
        .description = "Show the CLI version.",
        .options = &common,
        .effects = &.{"Reads no config and makes no changes."},
        .examples = &.{ "ec --version", "ec --version --json" },
    },
};

fn append(c: *core.Context, text: *std.ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    try text.appendSlice(c.a, try c.fmt(format, args));
}
fn optionRows(c: *core.Context, text: *std.ArrayList(u8), entries: []const Option) !void {
    for (entries) |entry| {
        const label = try c.fmt("--{s}{s}", .{ entry.name, if (entry.type == .string) " <value>" else "" });
        try append(c, text, "  {s:<23} {s}\n", .{ label, entry.description });
        if (entry.values.len > 0) try append(c, text, "                          Values: {s}.\n", .{try std.mem.join(c.a, ", ", entry.values)});
        if (entry.default) |value| try append(c, text, "                          Default: {s}.\n", .{value});
    }
}
fn grouped(o: Options) bool {
    return o.command == .fleet or o.command == .plugin or o.command == .secret;
}
fn detail(c: *core.Context, text: *std.ArrayList(u8), entry: Definition) !void {
    try append(c, text, "{s}\n\nUsage: {s}\n\nOptions:\n", .{ entry.description, entry.usage });
    try optionRows(c, text, entry.options);
    try append(c, text, "\nEffects:\n", .{});
    for (entry.effects) |effect| try append(c, text, "  {s}\n", .{effect});
    try append(c, text, "\nExamples:\n", .{});
    for (entry.examples) |example| try append(c, text, "  {s}\n", .{example});
}
pub fn show(c: *core.Context, o: Options, plugins: []const plugin.Plugin) !void {
    var entries: std.ArrayList(Definition) = .empty;
    for (definitions) |entry| {
        if (o.command != .help and !core.eql(u8, entry.command, @tagName(o.command))) continue;
        if (grouped(o) and o.action.len > 0 and !core.eql(u8, entry.action, o.action)) continue;
        try entries.append(c.a, entry);
    }
    // Explicit actions such as `ec fleet sync --help` narrow to one entry; the default action does not.
    if (grouped(o) and entries.items.len == 1 and !explicit(o)) {
        entries.clearRetainingCapacity();
        for (definitions) |entry| if (core.eql(u8, entry.command, @tagName(o.command))) try entries.append(c.a, entry);
    }
    var text: std.ArrayList(u8) = .empty;
    try append(c, &text, "ec {s} - ender chest\n\n", .{@import("main.zig").version});
    if (entries.items.len == 1) {
        try detail(c, &text, entries.items[0]);
    } else {
        const scope = if (grouped(o)) try c.fmt("ec {s}", .{@tagName(o.command)}) else "ec";
        try append(c, &text, "Usage: {s} <command> [options]\n\nCommands:\n", .{scope});
        if (grouped(o)) {
            for (entries.items) |entry| try append(c, &text, "  {s:<12} {s}\n", .{ entry.action, entry.description });
        } else {
            for (entries.items) |entry| {
                if (entry.action.len > 0 or core.eql(u8, entry.command, "version")) continue;
                try append(c, &text, "  {s:<12} {s}\n", .{ entry.command, entry.description });
            }
            try append(c, &text, "  fleet        Show or update ec on every machine in the tailnet.\n", .{});
            try append(c, &text, "  plugin       List enabled plugins or update one from GitHub.\n", .{});
            try append(c, &text, "  secret       Save, list, or remove secrets that plugin settings use.\n", .{});
            if (plugins.len > 0) {
                try append(c, &text, "\nPlugins:\n", .{});
                for (plugins) |p| {
                    try append(c, &text, "  {s:<12} {s}\n", .{ p.name, p.description });
                    for (p.commands) |cmd| try entries.append(c.a, try definition(c, p, cmd));
                }
            }
        }
        try append(c, &text, "\nOptions:\n", .{});
        try optionRows(c, &text, &common);
        if (!grouped(o)) try append(c, &text, "  --version               Show the CLI version.\n", .{});
        try append(c, &text, "\nUse {s} <command> --help for options, effects, and examples.\nAdd --json for structured command definitions.\n", .{scope});
        if (o.command == .fleet) try append(c, &text, "\nExamples:\n  ec fleet\n  ec fleet sync\n", .{});
    }
    try append(c, &text, "\nExit codes: 0 success, 1 operation failed or unreachable, 2 invalid arguments.\n", .{});
    try c.resultData("help", true, text.items, .{ .command_definitions = entries.items });
}
// options.zig fills in a default action only after help returns, so a set action was typed.
fn explicit(o: Options) bool {
    return o.action.len > 0;
}
fn definition(c: *core.Context, p: plugin.Plugin, cmd: plugin.Command) !Definition {
    var opts: std.ArrayList(Option) = .empty;
    for (cmd.options) |o| try opts.append(c.a, .{ .name = o.name, .type = if (o.kind == .string) .string else .boolean, .description = o.description, .values = o.values, .default = o.default });
    if (!cmd.passthrough) try opts.appendSlice(c.a, &common);
    return .{ .command = p.name, .action = cmd.name, .plugin = p.source, .usage = if (cmd.usage.len > 0) cmd.usage else try c.fmt("ec {s} {s} [options]", .{ p.name, cmd.name }), .description = cmd.description, .options = opts.items, .effects = cmd.effects, .examples = cmd.examples };
}
// Help for one plugin, or for one of its commands. Reads only the manifest.
pub fn showPlugin(c: *core.Context, p: plugin.Plugin, cmd: ?plugin.Command) !void {
    var entries: std.ArrayList(Definition) = .empty;
    var text: std.ArrayList(u8) = .empty;
    try append(c, &text, "ec {s} - ender chest\n\n", .{@import("main.zig").version});
    if (cmd) |one| {
        const d = try definition(c, p, one);
        try entries.append(c.a, d);
        try detail(c, &text, d);
    } else {
        try append(c, &text, "{s}\n\nUsage: ec {s} <command> [options]\n\nCommands:\n", .{ p.description, p.name });
        for (p.commands) |one| {
            try append(c, &text, "  {s:<12} {s}{s}\n", .{ one.name, one.description, if (p.default != null and core.eql(u8, p.default.?, one.name)) " (default)" else "" });
            try entries.append(c.a, try definition(c, p, one));
        }
        if (p.settings.len > 0) {
            try append(c, &text, "\nSettings, under [plugins.{s}] in ender-chest.toml:\n", .{p.name});
            for (p.settings) |s| try append(c, &text, "  {s:<23} {s}{s}{s}\n", .{ s.name, s.description, if (s.required) " Required." else "", if (s.kind == .secret) " Use { secret = \"NAME\" }." else "" });
        }
        try append(c, &text, "\nSource: {s}{s}\n", .{ p.source, if (p.commit) |cm| try c.fmt(" @ {s}", .{cm}) else "" });
        try append(c, &text, "\nUse ec {s} <command> --help for options, effects, and examples.\n", .{p.name});
    }
    try append(c, &text, "\nExit codes: 0 success, 1 operation failed or unreachable, 2 invalid arguments.\n", .{});
    try c.resultData("help", true, text.items, .{ .command_definitions = entries.items });
}
