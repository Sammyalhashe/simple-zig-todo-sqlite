const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- C interop ---
    // Translate the C header to a Zig module, linking sqlite3, mysqlclient, and ncurses.
    // This produces the `c` module used by db.zig, tui.zig, and the main executable.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("sqlite3", .{});
    translate_c.linkSystemLibrary("mysqlclient", .{});
    translate_c.linkSystemLibrary("ncurses", .{});

    const c_module = translate_c.createModule();

    // --- Application modules ---
    // Module dependency graph:
    //   c (leaf)    json (leaf)
    //     \           |
    //      \----+-----+
    //           |
    //          db
    //        / | \
    //   server sync tui
    //       \   |   /
    //        main (+ ssh_tunnel, yazap)

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

    // ssh_tunnel has no deps beyond std — it only uses std.Io and std.process
    const ssh_tunnel_module = b.createModule(.{
        .root_source_file = b.path("src/ssh_tunnel.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "db", .module = db_module },
                .{ .name = "json", .module = json_module },
                .{ .name = "server", .module = server_module },
                .{ .name = "ssh_tunnel", .module = ssh_tunnel_module },
                .{ .name = "sync", .module = sync_module },
                .{ .name = "tui", .module = tui_module },
            },
        }),
    });

    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.linkSystemLibrary("mysqlclient", .{});
    exe.root_module.linkSystemLibrary("ncurses", .{});

    // yazap CLI arg parser (external dependency from build.zig.zon)
    const yazap = b.dependency("yazap", .{});
    exe.root_module.addImport("yazap", yazap.module("yazap"));

    b.installArtifact(exe);

    // --- Unit tests (`zig build test`) ---
    // Fast tests with no external dependencies. Covers json parsing and sync classification logic.
    const test_step = b.step("test", "Run unit tests");

    // json.zig: pure string parsing/serialization, no C deps
    const json_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/json.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(json_tests).step);

    // sync.zig: classifyTask unit tests (needs db module for SyncTask type)
    const sync_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sync.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "db", .module = db_module },
            },
        }),
    });
    sync_tests.root_module.linkSystemLibrary("sqlite3", .{});
    sync_tests.root_module.linkSystemLibrary("mysqlclient", .{});
    test_step.dependOn(&b.addRunArtifact(sync_tests).step);

    // --- Integration tests (`zig build integration-test`) ---
    // Requires a running MariaDB instance. Run via the test harness:
    //   ./test/test-mariadb.sh zig build integration-test
    // The harness starts an ephemeral MariaDB, loads the schema, and exports
    // TEST_MARIADB_HOST / TEST_MARIADB_PORT env vars for the test binary.
    const integration_test_step = b.step("integration-test", "Run MariaDB integration tests (use test/test-mariadb.sh)");

    const integration_exe = b.addExecutable(.{
        .name = "integration-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c", .module = c_module },
                .{ .name = "db", .module = db_module },
                .{ .name = "sync", .module = sync_module },
            },
        }),
    });
    integration_exe.root_module.linkSystemLibrary("sqlite3", .{});
    integration_exe.root_module.linkSystemLibrary("mysqlclient", .{});
    integration_test_step.dependOn(&b.addRunArtifact(integration_exe).step);

    // --- Convenience run step (`zig build run`) ---
    // Runs against local SQLite by default. Pass -Dr and -Dp for remote:
    //   zig build run -Dr=<host> -Dp=<password> -- <subcommand> [args]
    const run_exe = b.addRunArtifact(exe);

    if (b.option([]const u8, "r", "remote MariaDB host (omit to use local SQLite)")) |remote| {
        run_exe.addArgs(&.{ "-r", remote });
    }

    if (b.option([]const u8, "p", "password to the remote")) |password| {
        run_exe.addArgs(&.{ "-p", password });
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);

    if (b.args) |args| {
        run_exe.addArgs(args);
    }
}
