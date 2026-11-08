const std = @import("std");
pub const eql = std.mem.eql;
pub const Value = std.json.Value;
pub const cwd = std.Io.Dir.cwd;
// What went wrong, as JSON results report it. Arguments ec cannot use exit 2; every other failure exits 1.
pub const Code = enum {
    operation_failed,
    usage_error,
    interaction_required,
    @"unreachable",
    verification_failed,
    stop_failed,
    sync_failed,
    pub fn exitCode(code: Code) u8 {
        return if (code == .usage_error) 2 else 1;
    }
};
// A command's result. main prints it once, as text or as one JSON object.
pub const Outcome = struct {
    command: []const u8,
    message: []const u8,
    // The result's data as JSON text.
    data: []const u8 = "null",
    failure: ?Code = null,
    // An error message rather than a report. Text output sends it to stderr.
    diagnostic: bool = false,
};
pub const Context = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    home: []const u8,
    repo: []const u8 = "",
    json: bool = false,
    stdout: std.Io.File = .stdout(),
    stderr: std.Io.File = .stderr(),
    message: ?[]const u8 = null,
    error_code: Code = .operation_failed,
    pub fn fmt(c: *Context, comptime f: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(c.a, f, args);
    }
    pub fn path(c: *Context, parts: []const []const u8) ![]const u8 {
        return std.fs.path.join(c.a, parts);
    }
    pub fn fail(c: *Context, comptime f: []const u8, args: anytype) error{ Reported, OutOfMemory } {
        c.message = try c.fmt(f, args);
        return error.Reported;
    }
    pub fn failCode(c: *Context, code: Code, comptime f: []const u8, args: anytype) error{ Reported, OutOfMemory } {
        c.error_code = code;
        return c.fail(f, args);
    }
    // Takes back a failure that the caller only warns about: returns what `fail` recorded and
    // clears it, so a later failure reports its own code. Other errors pass through.
    pub fn recover(c: *Context, err: anyerror) anyerror![]const u8 {
        if (err != error.Reported) return err;
        const message = c.message orelse "";
        c.message = null;
        c.error_code = .operation_failed;
        return message;
    }
    pub fn log(c: *Context, comptime f: []const u8, args: anytype) !void {
        try c.stderr.writeStreamingAll(c.io, try c.fmt(f ++ "\n", args));
    }
    pub fn out(c: *Context, s: []const u8) !void {
        try c.stdout.writeStreamingAll(c.io, s);
    }
    pub fn result(_: *Context, command_name: []const u8, message: []const u8) !Outcome {
        return .{ .command = command_name, .message = message };
    }
    pub fn resultData(c: *Context, command_name: []const u8, message: []const u8, data: anytype) !Outcome {
        return .{ .command = command_name, .message = message, .data = try std.json.Stringify.valueAlloc(c.a, data, .{}) };
    }
    // A result that reports a failure and still carries data, such as machines that did not sync.
    pub fn failedData(c: *Context, command_name: []const u8, code: Code, message: []const u8, data: anytype) !Outcome {
        return .{ .command = command_name, .message = message, .data = try std.json.Stringify.valueAlloc(c.a, data, .{}), .failure = code };
    }
    pub fn reported(c: *Context, command_name: []const u8, err: anyerror) Outcome {
        const message = if (err == error.Reported and c.message != null) c.message.? else c.fmt("{s} failed: {s}", .{ command_name, @errorName(err) }) catch "Operation failed.";
        return .{ .command = command_name, .message = message, .failure = c.error_code, .diagnostic = true };
    }
    pub fn print(c: *Context, o: Outcome) !void {
        if (!c.json) return if (o.diagnostic) c.log("{s}", .{o.message}) else c.out(try c.fmt("{s}\n", .{o.message}));
        const s = std.json.Stringify.valueAlloc;
        const failure = if (o.failure) |code| try s(c.a, .{ .code = code, .message = o.message }, .{}) else "null";
        try c.out(try c.fmt("{{\"schema_version\":1,\"command\":{s},\"ok\":{},\"message\":{s},\"data\":{s},\"error\":{s}}}\n", .{ try s(c.a, o.command, .{}), o.failure == null, try s(c.a, o.message, .{}), o.data, failure }));
    }
    pub fn exists(c: *Context, p: []const u8) bool {
        _ = cwd().statFile(c.io, p, .{}) catch return false;
        return true;
    }
    pub fn isLink(c: *Context, p: []const u8) bool {
        const st = cwd().statFile(c.io, p, .{ .follow_symlinks = false }) catch return false;
        return st.kind == .sym_link;
    }
    pub fn read(c: *Context, p: []const u8) ![]const u8 {
        return try c.optional(p) orelse c.fail("Missing {s}.", .{p});
    }
    pub fn optional(c: *Context, p: []const u8) !?[]const u8 {
        return cwd().readFileAlloc(c.io, p, c.a, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            error.OutOfMemory => error.OutOfMemory,
            else => c.fail("Cannot read {s}: {s}.", .{ p, @errorName(err) }),
        };
    }
    pub fn mkdir(c: *Context, p: []const u8) !void {
        try cwd().createDirPath(c.io, p);
    }
    pub fn chmod(c: *Context, p: []const u8, mode: u32) !void {
        const file = try cwd().openFile(c.io, p, .{});
        defer file.close(c.io);
        try file.setPermissions(c.io, .fromMode(@intCast(mode)));
    }
    // Write alongside the destination and rename, so readers never see partial config or executables.
    pub fn write(c: *Context, p: []const u8, data: []const u8, mode: u32) !void {
        try c.mkdir(std.fs.path.dirname(p) orelse ".");
        if (try c.optional(p)) |old| {
            if (eql(u8, old, data)) {
                try c.chmod(p, mode);
                return;
            }
        }
        const tmp = try c.tempNear(p);
        defer cwd().deleteFile(c.io, tmp) catch {};
        const file = try cwd().createFile(c.io, tmp, .{ .exclusive = true, .permissions = .fromMode(@intCast(mode)) });
        {
            defer file.close(c.io);
            try file.writeStreamingAll(c.io, data);
            try file.setPermissions(c.io, .fromMode(@intCast(mode)));
        }
        try cwd().rename(tmp, cwd(), p, c.io);
    }
    // A unique path beside `p` for staging a write that is then renamed over it.
    pub fn tempNear(c: *Context, p: []const u8) ![]const u8 {
        var random: [8]u8 = undefined;
        std.Io.random(c.io, &random);
        return c.fmt("{s}.ec-{x}", .{ p, random });
    }
    pub fn copy(c: *Context, from: []const u8, to: []const u8, mode: u32) !void {
        try c.write(to, try c.read(from), mode);
    }
    pub fn remove(c: *Context, p: []const u8) !void {
        try cwd().deleteTree(c.io, p);
    }
    pub fn link(c: *Context, target: []const u8, dest: []const u8) !void {
        try c.mkdir(std.fs.path.dirname(dest) orelse ".");
        if (c.exists(dest) or c.isLink(dest)) try c.remove(dest);
        try cwd().symLink(c.io, target, dest, .{ .is_directory = true });
    }
    pub fn copyTree(c: *Context, from: []const u8, to: []const u8) anyerror!void {
        try c.mkdir(to);
        var dir = try cwd().openDir(c.io, from, .{ .iterate = true });
        defer dir.close(c.io);
        var it = dir.iterate();
        while (try it.next(c.io)) |entry| {
            if (eql(u8, entry.name, ".DS_Store") or eql(u8, entry.name, ".git")) continue;
            const src = try c.path(&.{ from, entry.name });
            const dest = try c.path(&.{ to, entry.name });
            switch (entry.kind) {
                .directory => try c.copyTree(src, dest),
                .file => {
                    const st = try cwd().statFile(c.io, src, .{});
                    try c.copy(src, dest, @intCast(st.permissions.toMode() & 0o777));
                },
                .sym_link => {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    const n = try cwd().readLink(c.io, src, &buf);
                    try c.link(buf[0..n], dest);
                },
                else => {},
            }
        }
    }
    pub fn commandExists(c: *Context, name: []const u8) bool {
        _ = c.resolveCommand(name) catch return false;
        return true;
    }
    pub fn resolveCommand(c: *Context, name: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
        var it = std.mem.splitScalar(u8, c.env.get("PATH") orelse "", ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const full = try c.path(&.{ dir, name });
            const st = cwd().statFile(c.io, full, .{}) catch continue;
            if (st.kind == .file and st.permissions.toMode() & 0o111 != 0) return full;
        }
        return error.FileNotFound;
    }
    pub fn capture(c: *Context, args: []const []const u8, dir: ?[]const u8, seconds: i64) !std.process.RunResult {
        return bounded(c, captureInner, .{ c, args, dir }, seconds);
    }
    fn captureInner(c: *Context, args: []const []const u8, dir: ?[]const u8) anyerror!std.process.RunResult {
        const argv = try c.a.dupe([]const u8, args);
        argv[0] = try c.resolveCommand(args[0]);
        return std.process.run(c.a, c.io, .{ .argv = argv, .cwd = if (dir) |p| .{ .path = p } else .inherit, .environ_map = c.env, .stdout_limit = .limited(8 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    }
    pub fn command(c: *Context, args: []const []const u8, dir: ?[]const u8) !void {
        const r = try c.capture(args, dir, 600);
        try c.forward(r);
        if (!success(r.term)) return c.fail("{s} failed. Check the output above.", .{args[0]});
    }
    // Shows a captured command's output on stderr, so --json keeps stdout to one result.
    pub fn forward(c: *Context, r: std.process.RunResult) !void {
        if (r.stdout.len > 0) try c.stderr.writeStreamingAll(c.io, r.stdout);
        if (r.stderr.len > 0) try c.stderr.writeStreamingAll(c.io, r.stderr);
    }
    pub fn object(_: *Context) Value {
        return .{ .object = .empty };
    }
    pub fn parse(c: *Context, data: []const u8) !Value {
        return (try std.json.parseFromSlice(Value, c.a, data, .{ .allocate = .alloc_always })).value;
    }
    pub fn readJson(c: *Context, p: []const u8) !Value {
        return c.parseObject(p, try c.read(p));
    }
    // `text` is the contents of `p`, which error messages name.
    pub fn parseObject(c: *Context, p: []const u8, text: []const u8) !Value {
        const v = c.parse(text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return c.fail("{s} is not valid JSON.", .{p}),
        };
        if (v != .object) return c.fail("Expected a JSON object in {s}", .{p});
        return v;
    }
    pub fn writeJson(c: *Context, p: []const u8, v: Value, mode: u32) !void {
        try c.write(p, try c.fmt("{s}\n", .{try std.json.Stringify.valueAlloc(c.a, v, .{ .whitespace = .indent_2 })}), mode);
    }
};
pub const Checks = struct {
    failed: usize = 0,
    pub fn fail(checks: *Checks, c: *Context, comptime f: []const u8, args: anytype) !void {
        checks.failed += 1;
        try c.log("fail: " ++ f, args);
    }
    pub fn file(checks: *Checks, c: *Context, p: []const u8) !void {
        const st = cwd().statFile(c.io, p, .{}) catch return checks.fail(c, "missing {s}", .{p});
        if (st.kind != .file) try checks.fail(c, "expected a file at {s}", .{p});
    }
};
pub fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
}
pub fn truthy(value: ?[]const u8) bool {
    const v = value orelse return false;
    return v.len > 0 and !eql(u8, v, "0") and !eql(u8, v, "false");
}
pub fn unixSeconds(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
}
pub fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (eql(u8, x, item)) return true;
    return false;
}
pub fn isCommit(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}
pub fn success(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}
pub fn string(v: Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const field = v.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}
pub fn array(v: Value, key: []const u8) []Value {
    if (v != .object) return &.{};
    const field = v.object.get(key) orelse return &.{};
    return if (field == .array) field.array.items else &.{};
}
// An SSH host, or USER@HOST when `user` is set. Rejects leading dashes and shell syntax, since
// hosts reach ssh's argv.
pub fn validHost(s: []const u8, user: bool) bool {
    var parts = std.mem.splitScalar(u8, s, '@');
    const first = parts.next().?;
    if (parts.next()) |host| {
        if (!user or parts.next() != null or first.len == 0 or (!std.ascii.isAlphanumeric(first[0]) and first[0] != '_')) return false;
        for (first) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.' and ch != '-') return false;
        return validHost(host, false);
    }
    if (s.len == 0 or !std.ascii.isAlphanumeric(s[0])) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.' and ch != '-') return false;
    return true;
}
pub fn safeName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.' or name[0] == '-') return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    return true;
}

// Bound the whole child lifetime, including wait after both output pipes close.
// The caller's arena owns output buffers; cancellation closes process handles.
pub fn bounded(c: *Context, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function)), seconds: i64) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Event = union(enum) { done: Result, timeout: std.Io.Cancelable!void };
    var buffer: [2]Event = undefined;
    var select = std.Io.Select(Event).init(c.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.done, function, args);
    try select.concurrent(.timeout, std.Io.sleep, .{ c.io, std.Io.Duration.fromSeconds(seconds), .awake });
    switch (try select.await()) {
        .done => |result| return result,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    }
}
