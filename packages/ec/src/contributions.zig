// What enabled plugins add to every agent's settings. Plugins declare these with {setting}
// templates; plugin.contributions fills them in.
const std = @import("std");

pub const Header = struct { name: []const u8, value: []const u8 };
pub const Mcp = struct { name: []const u8, url: []const u8, headers: []const Header = &.{} };
// `id` is the contributing plugin, used as the Codex provider key. `base_url` is the server's
// origin, which Claude Code uses as is; OpenAI-compatible clients use `openaiUrl`. `models` lists
// the models agents that keep a model catalog, such as Grok, should route through the provider.
pub const Provider = struct { id: []const u8 = "", name: []const u8, base_url: []const u8, api_key: []const u8, models: []const []const u8 = &.{} };
pub fn openaiUrl(a: std.mem.Allocator, origin: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/v1", .{origin});
}
pub const Contributions = struct {
    mcp_servers: []const Mcp = &.{},
    provider: ?Provider = null,
    pub fn hasServer(contrib: Contributions, name: []const u8) bool {
        for (contrib.mcp_servers) |m| if (std.mem.eql(u8, m.name, name)) return true;
        return false;
    }
};
