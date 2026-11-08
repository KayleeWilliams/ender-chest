// Where ec keeps its files on a machine, and the layout of a config checkout.
const std = @import("std");
const core = @import("core.zig");
const C = core.Context;

// On the machine, relative to HOME.
pub const ec_bin = ".local/bin/ec";
pub const state_dir = ".config/ender-chest";
pub const saved_repo = state_dir ++ "/repo";
pub const state_file = state_dir ++ "/state.json";
pub const backup_dir = state_dir ++ "/backup";
pub const secrets_dir = state_dir ++ "/secrets";
pub const update_check = state_dir ++ "/update-check.json";
pub const cache_dir = ".cache/ec";
pub const plugin_store = ".local/share/ender-chest/plugins";
pub const skills_home = ".agents/skills";
// Written by the skills CLI; it records where each installed skill came from.
pub const skill_lock = ".agents/.skill-lock.json";

// The same paths for a shell command run on another machine over SSH.
pub const remote_ec = "\"$HOME/" ++ ec_bin ++ "\"";
pub const remote_saved_repo = "\"$HOME/" ++ saved_repo ++ "\"";

pub fn inHome(c: *C, rel: []const u8) ![]const u8 {
    return c.path(&.{ c.home, rel });
}
// A path under HOME, or under $XDG_CONFIG_HOME when that is set and the program honours it.
pub const Place = struct {
    home: []const u8,
    xdg: ?[]const u8 = null,
    pub fn resolve(p: Place, c: *C) ![]const u8 {
        if (p.xdg) |rel| if (c.env.get("XDG_CONFIG_HOME")) |base| if (std.fs.path.isAbsolute(base)) return c.path(&.{ base, rel });
        return inHome(c, p.home);
    }
};

// In a config checkout, relative to its root.
pub const manifest_file = "ender-chest.toml";
pub const lock_file = "ender-chest.lock";
pub const home_dir = "home";
pub const agents_dir = "agents";
pub const instructions = agents_dir ++ "/shared/AGENTS.md";
pub const skills_dir = "skills";
pub const skills_manifest = skills_dir ++ "/manifest.json";
pub const plugins_dir = "plugins";
// What ec push may stage, besides the `from` files that ender-chest.toml lists.
pub const upload = [_][]const u8{ home_dir, skills_dir, agents_dir, plugins_dir, manifest_file, lock_file };

pub fn inRepo(c: *C, rel: []const u8) ![]const u8 {
    return c.path(&.{ c.repo, rel });
}
