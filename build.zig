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

    // const pq_c = b.addTranslateC(.{
    //     .root_source_file = b.path("src/pq.h"),
    //     .target = target,
    //     .optimize = optimize,
    //     .link_libc = true,
    // });

    // const pq_inc = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=includedir", "libpq" }), " \n\r\t");

    ssh_c.addSystemIncludePath(.{ .cwd_relative = ssh_inc });
    // pq_c.addSystemIncludePath(.{ .cwd_relative = pq_inc });

    const libssh_mod = ssh_c.createModule();
    // const libpq_mod = pq_c.createModule();

    const pg_mod = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    }).module("pg");

    const toml_mod = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    }).module("toml");

    const exe = b.addExecutable(.{
        .name = "ssh_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("ssh", libssh_mod);
    // exe.root_module.addImport("pq", libpq_mod);

    exe.root_module.linkSystemLibrary("ssh", .{});
    // exe.root_module.linkSystemLibrary("pq", .{});

    exe.root_module.addImport("pg", pg_mod);
    exe.root_module.addImport("toml", toml_mod);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
