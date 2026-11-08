// Merges portable JSON settings from the checkout into a machine's copy. Objects merge key by key
// and portable scalars win. An array keeps the machine's entries and gains the portable ones, such
// as hook groups other tools installed beside the config's. Entries an earlier sync added are
// taken out first, so editing or removing one in the checkout carries over instead of leaving a
// stale copy.
const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

// The array entries a sync added at one key path, as JSON text.
pub const Added = struct { path: []const []const u8, entries: []const []const u8 };
const Result = struct { value: Value, added: []const Added };

pub fn merge(a: Allocator, local: ?Value, portable: Value, previous: []const Added) !Result {
    var m: Merger = .{ .a = a, .previous = previous };
    var value = try m.value(local, portable, &.{}) orelse Value{ .object = .empty };
    for (previous) |p| if (!m.visited(p.path)) try remove(a, &value, p.path, p.entries);
    return .{ .value = value, .added = m.added.items };
}

const Merger = struct {
    a: Allocator,
    previous: []const Added,
    added: std.ArrayList(Added) = .empty,
    seen: std.ArrayList([]const []const u8) = .empty,

    // Null means the key should go: the config's entries were all it held.
    fn value(m: *Merger, local: ?Value, portable: Value, path: []const []const u8) anyerror!?Value {
        switch (portable) {
            .object => |po| {
                var out: std.json.ObjectMap = .empty;
                if (local) |l| if (l == .object) {
                    var it = l.object.iterator();
                    while (it.next()) |e| try out.put(m.a, e.key_ptr.*, e.value_ptr.*);
                };
                var it = po.iterator();
                while (it.next()) |e| {
                    const child = try m.a.alloc([]const u8, path.len + 1);
                    @memcpy(child[0..path.len], path);
                    child[path.len] = e.key_ptr.*;
                    if (try m.value(out.get(e.key_ptr.*), e.value_ptr.*, child)) |v| try out.put(m.a, e.key_ptr.*, v) else _ = out.orderedRemove(e.key_ptr.*);
                }
                return .{ .object = out };
            },
            .array => |pa| {
                try m.seen.append(m.a, path);
                const entries = try texts(m.a, pa.items);
                if (entries.len > 0) try m.added.append(m.a, .{ .path = path, .entries = entries });
                const before = if (local) |l| if (l == .array) l.array.items else &.{} else &.{};
                var out = std.json.Array.init(m.a);
                for (before) |item| {
                    const text = try std.json.Stringify.valueAlloc(m.a, item, .{});
                    if (!contains(m.previousAt(path), text) and !contains(entries, text)) try out.append(item);
                }
                try out.appendSlice(pa.items);
                if (out.items.len == 0 and before.len > 0) return null;
                return .{ .array = out };
            },
            else => return portable,
        }
    }
    fn previousAt(m: *Merger, path: []const []const u8) []const []const u8 {
        for (m.previous) |p| if (samePath(p.path, path)) return p.entries;
        return &.{};
    }
    fn visited(m: *Merger, path: []const []const u8) bool {
        for (m.seen.items) |p| if (samePath(p, path)) return true;
        return false;
    }
};

// For keys the checkout no longer sets.
fn remove(a: Allocator, root: *Value, path: []const []const u8, entries: []const []const u8) !void {
    if (path.len == 0) return;
    var parent = root;
    for (path[0 .. path.len - 1]) |key| {
        if (parent.* != .object) return;
        parent = parent.object.getPtr(key) orelse return;
    }
    if (parent.* != .object) return;
    const key = path[path.len - 1];
    const current = parent.object.getPtr(key) orelse return;
    if (current.* != .array) return;
    var kept = std.json.Array.init(a);
    for (current.array.items) |item| {
        if (!contains(entries, try std.json.Stringify.valueAlloc(a, item, .{}))) try kept.append(item);
    }
    if (kept.items.len == 0 and current.array.items.len > 0) {
        _ = parent.object.orderedRemove(key);
    } else current.* = .{ .array = kept };
}
// True when text is JSON with comments or trailing commas (JSONC): it parses once those are gone.
pub fn isJsonc(a: Allocator, text: []const u8) bool {
    const plain = stripJsonc(a, text) catch return false;
    _ = std.json.parseFromSliceLeaky(Value, a, plain, .{}) catch return false;
    return true;
}
fn stripJsonc(a: Allocator, text: []const u8) ![]const u8 {
    var bare: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_string = false;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (!in_string and ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            continue;
        }
        if (!in_string and ch == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i = (std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return error.Unclosed) + 1;
            continue;
        }
        try bare.append(a, ch);
        if (in_string and ch == '\\' and i + 1 < text.len) {
            i += 1;
            try bare.append(a, text[i]);
        } else if (ch == '"') in_string = !in_string;
    }
    var out: std.ArrayList(u8) = .empty;
    in_string = false;
    i = 0;
    while (i < bare.items.len) : (i += 1) {
        const ch = bare.items[i];
        if (!in_string and ch == ',') {
            const rest = std.mem.trimStart(u8, bare.items[i + 1 ..], " \t\r\n");
            if (rest.len > 0 and (rest[0] == '}' or rest[0] == ']')) continue;
        }
        try out.append(a, ch);
        if (in_string and ch == '\\' and i + 1 < bare.items.len) {
            i += 1;
            try out.append(a, bare.items[i]);
        } else if (ch == '"') in_string = !in_string;
    }
    return out.items;
}
fn texts(a: Allocator, items: []const Value) ![]const []const u8 {
    const out = try a.alloc([]const u8, items.len);
    for (items, 0..) |item, i| out[i] = try std.json.Stringify.valueAlloc(a, item, .{});
    return out;
}
fn contains(list: []const []const u8, text: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, text)) return true;
    return false;
}
fn samePath(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

fn parse(a: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{});
}
fn render(a: Allocator, v: Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}
test "nested local keys survive and array entries the config added are replaced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local = try parse(a, "{\"permissions\":{\"allow\":[\"Bash(ls)\",\"Read\"],\"defaultMode\":\"default\"},\"theme\":\"dark\"}");
    const portable = try parse(a, "{\"permissions\":{\"allow\":[\"Edit\"],\"defaultMode\":\"acceptEdits\"}}");
    const previous = [_]Added{.{ .path = &.{ "permissions", "allow" }, .entries = &.{"\"Read\""} }};
    const r = try merge(a, local, portable, &previous);
    try std.testing.expectEqualStrings("{\"permissions\":{\"allow\":[\"Bash(ls)\",\"Edit\"],\"defaultMode\":\"acceptEdits\"},\"theme\":\"dark\"}", try render(a, r.value));
    try std.testing.expectEqual(@as(usize, 1), r.added.len);
    try std.testing.expectEqualStrings("\"Edit\"", r.added[0].entries[0]);
}
test "a key the checkout stopped setting loses only the entries ec added" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local = try parse(a, "{\"hooks\":{\"Stop\":[1,2],\"Start\":[3]}}");
    const previous = [_]Added{ .{ .path = &.{ "hooks", "Stop" }, .entries = &.{"2"} }, .{ .path = &.{ "hooks", "Start" }, .entries = &.{"3"} } };
    const r = try merge(a, local, try parse(a, "{}"), &previous);
    try std.testing.expectEqualStrings("{\"hooks\":{\"Stop\":[1]}}", try render(a, r.value));
}
test "JSONC is comments and trailing commas around valid JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(isJsonc(a, "{\n  // a note\n  \"url\": \"https://x.test/a//b\", /* more */\n}"));
    try std.testing.expect(!isJsonc(a, "{\"url\": "));
}
