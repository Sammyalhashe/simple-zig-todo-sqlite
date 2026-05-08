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
}
