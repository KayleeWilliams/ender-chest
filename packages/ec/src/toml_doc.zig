// TOML documents: parsing that survives edits, typed reads, and writing back.
const std = @import("std");
const toml = @import("toml");
const core = @import("core.zig");

pub const Table = toml.Table;
pub const Value = toml.Value;

// zig-toml builds each table with an allocator that points at an arena in parseString's stack
// frame, then returns a copy of that arena. Adding a key to such a table can allocate through the
// dead pointer and crash, so parse points every table at a, which must be an arena.
pub fn parse(a: std.mem.Allocator, text: []const u8) !*toml.Table {
    var parser = toml.Parser(toml.Table).init(a);
    defer parser.deinit();
    const root = try a.create(toml.Table);
    root.* = (try parser.parseString(text)).value;
    rebind(.{ .table = root }, a);
    return root;
}
fn rebind(v: toml.Value, a: std.mem.Allocator) void {
    switch (v) {
        .table => |t| {
            t.allocator = a;
            var it = t.valueIterator();
            while (it.next()) |child| rebind(child.*, a);
        },
        .array => |list| for (list.items) |item| rebind(item, a),
        else => {},
    }
}
pub fn table(a: std.mem.Allocator, parent: *toml.Table, key: []const u8) !*toml.Table {
    if (parent.get(key)) |v| {
        if (v != .table) return error.ExpectedTable;
        return v.table;
    }
    const t = try a.create(toml.Table);
    t.* = toml.Table.init(a);
    try parent.put(key, .{ .table = t });
    return t;
}
fn quote(w: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, w);
}
// Orca finds Codex project and hook entries by matching bare [projects. and [hooks.state. headers.
// A quoted ["projects"] header hides an existing entry, so Orca appends a duplicate table.
fn writeKey(w: *std.Io.Writer, text: []const u8) !void {
    if (text.len == 0) return quote(w, text);
    for (text) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return quote(w, text);
    }
    try w.writeAll(text);
}
fn value(w: *std.Io.Writer, v: toml.Value, a: std.mem.Allocator) anyerror!void {
    switch (v) {
        .string => |s| try quote(w, s),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |n| {
            if (std.math.isNan(n)) try w.writeAll("nan") else if (std.math.isInf(n)) try w.writeAll(if (n < 0) "-inf" else "inf") else {
                const s = try std.fmt.allocPrint(a, "{d}", .{n});
                try w.writeAll(s);
                if (std.mem.indexOfAny(u8, s, ".eE") == null) try w.writeAll(".0");
            }
        },
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |v2, i| {
                if (i > 0) try w.writeAll(", ");
                try value(w, v2, a);
            }
            try w.writeByte(']');
        },
        .table => |t| {
            try w.writeAll("{ ");
            const keys = try sortedKeys(a, t);
            for (keys, 0..) |k, i| {
                if (i > 0) try w.writeAll(", ");
                try writeKey(w, k);
                try w.writeAll(" = ");
                try value(w, t.get(k).?, a);
            }
            try w.writeAll(" }");
        },
        .date => |d| try date(w, d),
        .time => |t| try time(w, t),
        .datetime => |d| {
            try date(w, d.date);
            try w.writeByte('T');
            try time(w, d.time);
            if (d.offset_minutes) |offset| {
                if (offset == 0) try w.writeByte('Z') else {
                    const abs = @abs(offset);
                    try w.print("{s}{d:0>2}:{d:0>2}", .{ if (offset < 0) "-" else "+", abs / 60, abs % 60 });
                }
            }
        },
    }
}
fn date(w: *std.Io.Writer, d: toml.Date) !void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
}
fn time(w: *std.Io.Writer, t: toml.Time) !void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    if (t.nanosecond != 0) try w.print(".{d:0>9}", .{t.nanosecond});
}
// Codex and Grok append [section] headers when they save settings. TOML forbids extending an
// inline table, so writing nested tables inline would let their next save corrupt the file.
fn section(out: *std.Io.Writer.Allocating, a: std.mem.Allocator, path: []const u8, t: *const toml.Table) !void {
    const keys = try sortedKeys(a, t);
    var leaves: usize = 0;
    for (keys) |k| {
        if (t.get(k).? != .table) leaves += 1;
    }
    if (path.len > 0 and (leaves > 0 or keys.len == 0)) {
        if (out.written().len > 0) try out.writer.writeByte('\n');
        try out.writer.print("[{s}]\n", .{path});
    }
    for (keys) |k| {
        const v = t.get(k).?;
        if (v == .table) continue;
        try writeKey(&out.writer, k);
        try out.writer.writeAll(" = ");
        try value(&out.writer, v, a);
        try out.writer.writeByte('\n');
    }
    for (keys) |k| {
        const v = t.get(k).?;
        if (v != .table) continue;
        var name: std.Io.Writer.Allocating = .init(a);
        if (path.len > 0) try name.writer.print("{s}.", .{path});
        try writeKey(&name.writer, k);
        try section(out, a, name.written(), v.table);
    }
}
pub fn serialize(a: std.mem.Allocator, t: *const toml.Table) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try section(&out, a, "", t);
    return out.toOwnedSlice();
}

pub fn str(t: *const toml.Table, key: []const u8) ?[]const u8 {
    const v = t.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
// A list of strings, or null when the key is absent. Callers report WrongType in their own terms.
pub fn strings(a: std.mem.Allocator, t: *const toml.Table, key: []const u8) error{ WrongType, OutOfMemory }!?[]const []const u8 {
    const v = t.get(key) orelse return null;
    if (v != .array) return error.WrongType;
    const out = try a.alloc([]const u8, v.array.items.len);
    for (v.array.items, 0..) |item, i| {
        if (item != .string) return error.WrongType;
        out[i] = item.string;
    }
    return out;
}
pub fn sortedKeys(a: std.mem.Allocator, t: *const toml.Table) ![][]const u8 {
    const keys = try a.alloc([]const u8, t.count());
    var it = t.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) keys[i] = k.*;
    core.sortStrings(keys);
    return keys;
}

fn clobberStack() void {
    var junk: [64 * 1024]u8 = undefined;
    @memset(&junk, 0xaa);
    std.mem.doNotOptimizeAway(&junk);
}
test "parsed tables can grow after the parser's stack frame is reused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), "[mcp_servers.local]\nurl = 'https://example.test'\n[[list]]\nname = 'x'\n");
    clobberStack();
    const nested = root.get("list").?.array.items[0].table;
    for (0..64) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "k{d}", .{i});
        try root.put(key, .{ .integer = @intCast(i) });
        try root.get("mcp_servers").?.table.put(key, .{ .integer = 1 });
        try nested.put(key, .{ .integer = 1 });
    }
    try std.testing.expectEqual(@as(u32, 66), root.count());
}
