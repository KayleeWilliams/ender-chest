const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = if (@import("builtin").os.tag == .macos) .{ .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } } } else .{} });
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .strip = optimize != .Debug });
    const toml = b.dependency("toml", .{ .target = target, .optimize = optimize });
    module.addImport("toml", toml.module("toml"));
    const source_hash = @import("src/source_hash.zig").fingerprint(b.allocator, b.graph.io, b.pathFromRoot(".")) catch @panic("cannot hash ec sources");
    std.Io.Dir.cwd().createDirPath(b.graph.io, "zig-out") catch @panic("cannot create zig-out");
    var hash_text: [65]u8 = undefined;
    @memcpy(hash_text[0..64], &source_hash);
    hash_text[64] = '\n';
    std.Io.Dir.cwd().writeFile(b.graph.io, .{ .sub_path = "zig-out/source_hash.txt", .data = &hash_text }) catch @panic("cannot write source hash");
    const version = b.option([]const u8, "version", "ec release version") orelse "dev";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "source_hash", &source_hash);
    module.addImport("build_options", options.createModule());
    const exe = b.addExecutable(.{ .name = "ec", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run ec").dependOn(&run.step);
    const unit = b.addTest(.{ .root_module = module });
    const tests = b.addRunArtifact(unit);
    b.step("test", "Run native tests").dependOn(&tests.step);
}
