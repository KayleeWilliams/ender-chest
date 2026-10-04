const std = @import("std");
const core = @import("core.zig");
const Options = @import("options.zig").Options;

const Option = struct {
    name: []const u8,
    type: enum { boolean, string } = .boolean,
    description: []const u8,
    values: []const []const u8 = &.{},
    default: ?[]const u8 = null,
    required: bool = false,
};
const Definition = struct {
    command: []const u8,
    action: []const u8 = "",
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
    .{ .name = "profile", .type = .string, .description = "Override the detected machine profile.", .values = &.{ "mac", "cloud" }, .default = "detected" },
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
        .effects = &.{ "Writes managed home files, installs ec, and updates skill links. Preserves local credentials and settings.", "Pulls a clean checkout, using the primary worktree from a linked checkout. A dirty checkout or failed pull uses local files.", "When Zig sources change, installs the matching GitHub release, or rebuilds with Zig if that download fails. EC_NO_UPDATE=1 skips the release check. Desktop commands do not check.", "Installs packages unless --skip-packages is set." },
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
        .command = "desktop",
        .action = "start",
        .usage = "ec desktop start [--local | --via USER@HOST] [--no-wait] [--no-auth] [options]",
        .description = "Wake the desktop, wait for it, and unlock its wallet.",
        .options = &([_]Option{
            .{ .name = "local", .description = "Send a wake packet directly on the home LAN. Cannot combine with --via." },
            .{ .name = "via", .type = .string, .description = "SSH relay hostname or USER@HOST. Cannot combine with --local.", .default = "direct on the home LAN, else DESKTOP_RELAY, then configured relay" },
            .{ .name = "no-wait", .description = "Send the wake packet and exit without waiting or unlocking." },
            .{ .name = "no-auth", .description = "Wait for the desktop but leave its wallet locked." },
        } ++ common),
        .effects = &.{ "Skips the wake packet when the desktop already responds. On the home LAN, sends it directly; elsewhere, through the SSH relay.", "Waits up to waitSeconds (default 180) for the desktop, then runs ec desktop auth on macOS.", "Settings: ~/.config/desktop/config.json. Override with DESKTOP_CONFIG.", "The relay needs Remote Login and a current ec. Unreachable after the wait returns exit code 1." },
        .examples = &.{ "ec desktop start", "ec desktop start --no-auth", "ec desktop start --local --no-wait", "ec desktop start --via user@mac --json" },
    },
    .{
        .command = "desktop",
        .action = "stop",
        .usage = "ec desktop stop [--no-wait] [options]",
        .description = "Shut the desktop down through KDE.",
        .options = &([_]Option{
            .{ .name = "no-wait", .description = "Request shutdown and exit without waiting for the desktop to go offline." },
        } ++ common),
        .effects = &.{ "Asks KDE over SSH to log out and shut down, as the Plasma menu does. Apps can still block logout.", "Waits up to waitSeconds (default 180) for the desktop to stop responding.", "Settings: ~/.config/desktop/config.json. Override with DESKTOP_CONFIG." },
        .examples = &.{ "ec desktop stop", "ec desktop stop --no-wait --json" },
    },
    .{
        .command = "desktop",
        .action = "status",
        .usage = "ec desktop status [options]",
        .description = "Check desktop reachability over Tailscale.",
        .options = &common,
        .effects = &.{ "Pings the configured host. Reports reachability, not power state. Unreachable returns exit code 1.", "Settings: ~/.config/desktop/config.json. Override with DESKTOP_CONFIG." },
        .examples = &.{ "ec desktop status", "ec desktop status --json" },
    },
    .{
        .command = "desktop",
        .action = "auth",
        .usage = "ec desktop auth [--setup | --forget | --local] [options]",
        .description = "Unlock the desktop wallet using macOS Keychain.",
        .options = &([_]Option{
            .{ .name = "setup", .description = "Confirm SSH access and save the wallet password in this Mac's Keychain." },
            .{ .name = "forget", .description = "Remove the wallet password saved on this Mac." },
            .{ .name = "local", .description = "Prompt for the wallet password on Linux." },
        } ++ common),
        .effects = &.{ "Unlocks KWallet over SSH using the saved password. macOS may show a Keychain access dialog.", "Use only one of --setup, --forget, or --local. Setup and local unlock require an interactive terminal and refuse --json.", "Settings: ~/.config/desktop/config.json. Override with DESKTOP_CONFIG." },
        .examples = &.{ "ec desktop auth --setup", "ec desktop auth --json", "ec desktop auth --forget", "ec desktop auth --local" },
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
        .command = "cliproxy",
        .action = "setup",
        .usage = "ec cliproxy setup [--url URL] [--key-stdin] [options]",
        .description = "Save a proxy token on this device, outside the config checkout.",
        .options = &([_]Option{
            .{ .name = "url", .type = .string, .description = "Proxy endpoint without /v1.", .default = "local client.json baseURL" },
            .{ .name = "key-stdin", .description = "Read the token from stdin instead of a hidden terminal prompt." },
        } ++ common),
        .effects = &.{ "Writes the endpoint to ~/.config/cliproxyapi/client.json and the token to ~/.config/ender-chest/secrets/cliproxyapi.json with mode 0600.", "Never writes to the config checkout or contacts the proxy. Run ec sync afterwards to update agent settings.", "JSON mode requires --key-stdin. Tokens are never accepted as command-line arguments." },
        .examples = &.{ "ec cliproxy setup --url https://proxy.example.test:8317", "ec cliproxy setup" },
    },
    .{
        .command = "cliproxy",
        .action = "url",
        .usage = "ec cliproxy url [options]",
        .description = "Print the OpenAI-compatible base URL.",
        .options = &common,
        .effects = &.{ "Reads ~/.config/cliproxyapi/client.json. CLIPROXY_BASE_URL overrides the host for ec cliproxy only.", "Makes no network requests." },
        .examples = &.{ "ec cliproxy url", "ec cliproxy url --json" },
    },
    .{
        .command = "cliproxy",
        .action = "models",
        .usage = "ec cliproxy models [options]",
        .description = "List the models CLIProxyAPI serves.",
        .options = &common,
        .effects = &.{ "Requests /v1/models with the local client key, sent to curl on stdin.", "An unreachable host, a rejected key, or another HTTP error returns exit code 1." },
        .examples = &.{ "ec cliproxy models", "ec cliproxy models --json" },
    },
    .{
        .command = "cliproxy",
        .action = "restart",
        .usage = "ec cliproxy restart [options]",
        .description = "Restart CLIProxyAPI on its host and wait until it answers.",
        .options = &common,
        .effects = &.{ "On the host, restarts the io.cliproxyapi launch agent, loading it if needed. A restart clears the proxy's in-memory state, such as usage statistics and cooldowns.", "Elsewhere, runs ec cliproxy restart on the host over SSH in batch mode, then checks the proxy over Tailscale.", "Waits up to 30 seconds, or CLIPROXY_RESTART_TIMEOUT. No answer returns exit code 1." },
        .examples = &.{ "ec cliproxy restart", "ec cliproxy restart --json" },
    },
    .{
        .command = "cliproxy",
        .action = "run",
        .usage = "ec cliproxy run <command> [args...]",
        .description = "Run a command with OPENAI_BASE_URL and OPENAI_API_KEY set.",
        .options = &.{},
        .effects = &.{ "Replaces ec with the command. Every argument after run, including --json and --help, goes to the command.", "The variables apply only to that process." },
        .examples = &.{ "ec cliproxy run codex", "ec cliproxy run python3 script.py" },
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
    return o.command == .desktop or o.command == .fleet or o.command == .cliproxy;
}
pub fn show(c: *core.Context, o: Options) !void {
    var entries: std.ArrayList(Definition) = .empty;
    for (definitions) |entry| {
        if (o.command != .help and !core.eql(u8, entry.command, @tagName(o.command))) continue;
        if (grouped(o) and o.action != .help and !core.eql(u8, entry.action, @tagName(o.action))) continue;
        try entries.append(c.a, entry);
    }
    var text: std.ArrayList(u8) = .empty;
    try append(c, &text, "ec {s} - ender chest\n\n", .{@import("main.zig").version});
    if (entries.items.len == 1) {
        const entry = entries.items[0];
        try append(c, &text, "{s}\n\nUsage: {s}\n\nOptions:\n", .{ entry.description, entry.usage });
        try optionRows(c, &text, entry.options);
        try append(c, &text, "\nEffects:\n", .{});
        for (entry.effects) |effect| try append(c, &text, "  {s}\n", .{effect});
        try append(c, &text, "\nExamples:\n", .{});
        for (entry.examples) |example| try append(c, &text, "  {s}\n", .{example});
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
            try append(c, &text, "  desktop      Wake or shut down the desktop, check reachability, or unlock its wallet.\n", .{});
            try append(c, &text, "  fleet        Show or update ec on every machine in the tailnet.\n", .{});
            try append(c, &text, "  cliproxy     Configure or query CLIProxyAPI, restart it, or run a command through it.\n", .{});
        }
        try append(c, &text, "\nOptions:\n", .{});
        try optionRows(c, &text, &common);
        if (!grouped(o)) try append(c, &text, "  --version               Show the CLI version.\n", .{});
        try append(c, &text, "\nUse {s} <command> --help for options, effects, and examples.\nAdd --json for structured command definitions.\n", .{scope});
        if (o.command == .desktop) try append(c, &text, "\nExamples:\n  ec desktop start\n  ec desktop stop\n  ec desktop status --json\n  ec desktop auth --setup\n", .{});
        if (o.command == .fleet) try append(c, &text, "\nExamples:\n  ec fleet\n  ec fleet sync\n", .{});
        if (o.command == .cliproxy) try append(c, &text, "\nExamples:\n  ec cliproxy restart\n  ec cliproxy models\n  ec cliproxy run codex\n", .{});
    }
    try append(c, &text, "\nExit codes: 0 success, 1 operation failed or unreachable, 2 invalid arguments.\n", .{});
    try c.resultData("help", true, text.items, .{ .command_definitions = entries.items });
}
