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
    translate_c.linkSystemLibrary("ncurses", .{});

    const c_module = translate_c.createModule();

    const json_module = b.createModule(.{
        .root_source_file = b.path("src/json.zig"),
        .target = target,
        .optimize = optimize,
    });

    const db_module = b.createModule(.{
        .root_source_file = b.path("src/db.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c_module },
            .{ .name = "json", .module = json_module },
        },
    });

    const server_module = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "db", .module = db_module },
            .{ .name = "json", .module = json_module },
        },
    });

    const sync_module = b.createModule(.{
        .root_source_file = b.path("src/sync.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c_module },
            .{ .name = "db", .module = db_module },
        },
    });

    const tui_module = b.createModule(.{
        .root_source_file = b.path("src/tui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c_module },
            .{ .name = "db", .module = db_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c", .module = c_module },
                .{ .name = "db", .module = db_module },
                .{ .name = "json", .module = json_module },
                .{ .name = "server", .module = server_module },
                .{ .name = "sync", .module = sync_module },
                .{ .name = "tui", .module = tui_module },
            },
        }),
    });
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.linkSystemLibrary("mysqlclient", .{});
    exe.root_module.linkSystemLibrary("ncurses", .{});

    b.installArtifact(exe);

    // Test step
    const test_step = b.step("test", "Run unit tests");

    // Test the pure json module (no C deps)
    const json_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/json.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(json_tests).step);

    // Test the sync module (needs C and db for transitive imports)
    const sync_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sync.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c", .module = c_module },
                .{ .name = "db", .module = db_module },
            },
        }),
    });
    sync_tests.root_module.linkSystemLibrary("sqlite3", .{});
    sync_tests.root_module.linkSystemLibrary("mysqlclient", .{});
    test_step.dependOn(&b.addRunArtifact(sync_tests).step);

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
