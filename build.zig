const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ssh_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ssh.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const ssh_inc = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=includedir", "libssh" }), " \n\r\t");

    ssh_c.addSystemIncludePath(.{ .cwd_relative = ssh_inc });

    const libssh_mod = ssh_c.createModule();

    const pg_mod = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    }).module("pg");

    const lua_mod = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
    }).module("zlua");

    const exe = b.addExecutable(.{
        .name = "ssh_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.linkSystemLibrary("ssh", .{});
    exe.root_module.addImport("ssh", libssh_mod);
    exe.root_module.addImport("pg", pg_mod);
    exe.root_module.addImport("lua", lua_mod);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
