const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target =  target,
        .optimize = optimize
    });
    translate_c.linkSystemLibrary("sqlite3", .{});
    translate_c.linkSystemLibrary("mysqlclient", .{});

    const exe = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{
            .root_source_file =   b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "c",
                    .module = translate_c.createModule()
                },
            }
        }),
    });
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.linkSystemLibrary("mysqlclient", .{});

    b.installArtifact(exe);

    // Convenience run step
    const run_exe = b.addRunArtifact(exe);
    run_exe.addArgs(&.{ "-r", b.option([] const u8, "r", "remote where mariadb instance is hosted") orelse "oldboy.salh.xyz" });

    if (b.option([]const u8, "p", "password to the remote")) |password| {
        run_exe.addArgs(&.{ "-p", password });
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);

    if (b.args) |args| {
        run_exe.addArgs(args);
    }

}
