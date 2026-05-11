const std = @import("std");
const db = @import("db");
const server = @import("server");

const Iterator = std.process.Args.Iterator;

const Args = std.ArrayList([]const u8);

const CmdPair = struct {
    d_cmd: []const u8,
    d_args: ?Args,
};

const RemoteOptions = struct {
    d_dbUri: []const u8,
    d_password: ?[]const u8 = null,
};

const StartupOption = struct {
    d_local: bool = true,
    d_remoteOptions: ?RemoteOptions = null,
};

fn parseFlags(startupOptions: *StartupOption, argsIter: *Iterator) bool {
    const flag = argsIter.*.next() orelse return false;
    if (flag[0] != '-') return false;

    switch (flag[1]) {
        'r' => {
            startupOptions.*.d_local = false;
            startupOptions.*.d_remoteOptions = .{
                .d_dbUri = argsIter.next() orelse {
                    std.debug.print("Usage: -r <dbUri>\n", .{});
                    return false;
                },
            };
        },
        else => return false,
    }

    return true;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = init.minimal.args;
    var argsIter = try std.process.Args.iterateAllocator(args, init.arena.allocator());
    _ = argsIter.next(); // skip program name

    var startupOptions = StartupOption{
        .d_local = true,
        .d_remoteOptions = null,
    };

    const firstArg = argsIter.next() orelse {
        std.debug.print("Usage: todo <add|list|complete> [args]\n", .{});
        return;
    };

    var commandAndArgs: std.ArrayList(CmdPair) = std.ArrayList(CmdPair).empty;
    if (std.mem.eql(u8, firstArg, "add")) {
        const other = argsIter.next() orelse {
            std.debug.print("Missing description for '{s}'.\n", .{firstArg});
            return;
        };
        var cmdPair: CmdPair = .{
            .d_args = Args.empty,
            .d_cmd = firstArg,
        };
        try cmdPair.d_args.?.append(init.arena.allocator(), other);
        try commandAndArgs.append(init.arena.allocator(), cmdPair);
    } else if (std.mem.eql(u8, firstArg, "complete")) {
        const other = argsIter.next() orelse {
            std.debug.print("Missing id for '{s}'.\n", .{firstArg});
            return;
        };
        var cmdPair: CmdPair = .{
            .d_args = Args.empty,
            .d_cmd = firstArg,
        };
        try cmdPair.d_args.?.append(init.arena.allocator(), other);
        try commandAndArgs.append(init.arena.allocator(), cmdPair);
    } else if (std.mem.eql(u8, firstArg, "incomplete")) {
        const other = argsIter.next() orelse {
            std.debug.print("Missing id for '{s}'.\n", .{firstArg});
            return;
        };
        var cmdPair: CmdPair = .{
            .d_args = Args.empty,
            .d_cmd = firstArg,
        };
        try cmdPair.d_args.?.append(init.arena.allocator(), other);
        try commandAndArgs.append(init.arena.allocator(), cmdPair);
    } else if (std.mem.eql(u8, firstArg, "list")) {
        var cmdPair: CmdPair = .{
            .d_args = Args.empty,
            .d_cmd = firstArg,
        };
        // Check for --all and --json flags
        while (argsIter.next()) |nextArg| {
            if (std.mem.eql(u8, nextArg, "--all") or std.mem.eql(u8, nextArg, "--json")) {
                try cmdPair.d_args.?.append(init.arena.allocator(), nextArg);
            }
        }
        try commandAndArgs.append(init.arena.allocator(), cmdPair);
    } else if (std.mem.eql(u8, firstArg, "serve")) {
        const cmdPair: CmdPair = .{
            .d_args = null,
            .d_cmd = firstArg,
        };
        try commandAndArgs.append(init.arena.allocator(), cmdPair);
    } else {
        // Assume firstArg might be a flag
        var currentArg: ?[]const u8 = firstArg;
        while (currentArg) |arg| {
            if (arg[0] == '-') {
                if (std.mem.eql(u8, arg, "-r")) {
                    startupOptions.d_local = false;
                    const dbUri = argsIter.next() orelse {
                        std.debug.print("Usage: -r <dbUri>\n", .{});
                        return;
                    };
                    if (startupOptions.d_remoteOptions) |*remote| {
                        remote.d_dbUri = dbUri;
                    } else {
                        startupOptions.d_remoteOptions = .{ .d_dbUri = dbUri };
                    }
                } else if (std.mem.eql(u8, arg, "-p")) {
                    const password = argsIter.next() orelse {
                        std.debug.print("Usage: -p <password>\n", .{});
                        return;
                    };
                    if (startupOptions.d_remoteOptions) |*remote| {
                        remote.d_password = password;
                    } else {
                        startupOptions.d_remoteOptions = .{ .d_dbUri = "", .d_password = password };
                    }
                }
            } else {
                const cmdPair: CmdPair = .{
                    .d_cmd = arg,
                    .d_args = Args.empty,
                };
                try commandAndArgs.append(init.arena.allocator(), cmdPair);
                break;
            }
            currentArg = argsIter.next();
        } else {
            std.debug.print("Usage: todo [-r <dbUri>] [-p <password>] <add|list|complete> [args]\n", .{});
            return;
        }
    }

    const dbPath = "todo.db\x00";

    var tunnel_child: ?std.process.Child = null;
    var database: db.Db = undefined;
    if (startupOptions.d_remoteOptions) |remote| {
        std.debug.print("Opening SSH tunnel to {s}...\n", .{remote.d_dbUri});

        var argv: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty;
        if (remote.d_password) |pw| {
            try argv.appendSlice(init.arena.allocator(), &[_][]const u8{ "sshpass", "-p", pw });
        }
        try argv.appendSlice(init.arena.allocator(), &[_][]const u8{
            "ssh", "-o", "StrictHostKeyChecking=no", "-N", "-L", "3307:127.0.0.1:3306", remote.d_dbUri,
        });

        tunnel_child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        try std.Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_s }, .real);
        database = .{ .mariadb = try db.initMariaDb("127.0.0.1", 3307, remote.d_password) };
    } else {
        database = .{ .sqlite = try db.initDb(dbPath) };
    }

    defer if (tunnel_child) |*child| {
        child.kill(io);
    };

    defer db.close(database);

    for (commandAndArgs.items) |cmdPair| {
        const cmd = cmdPair.d_cmd;
        if (std.mem.eql(u8, cmd, "add")) {
            const desc = cmdPair.d_args orelse unreachable;
            try db.addTask(database, desc.items[0]);
            std.debug.print("Task added.\n", .{});
        } else if (std.mem.eql(u8, cmd, "list")) {
            var showAll = false;
            var jsonOutput = false;
            if (cmdPair.d_args) |a| {
                for (a.items) |flag| {
                    if (std.mem.eql(u8, flag, "--all")) showAll = true;
                    if (std.mem.eql(u8, flag, "--json")) jsonOutput = true;
                }
            }
            if (jsonOutput) {
                const tasks = try db.queryTasks(database, showAll, init.arena.allocator());
                std.debug.print("[", .{});
                for (tasks.items, 0..) |task, i| {
                    if (i > 0) std.debug.print(",", .{});
                    std.debug.print("{{\"id\":\"{s}\",\"title\":\"{s}\",\"status\":\"{s}\"}}", .{ task.id, task.title, task.status });
                }
                std.debug.print("]\n", .{});
            } else {
                try db.listTasks(io, database, showAll);
            }
        } else if (std.mem.eql(u8, cmd, "complete")) {
            const idStr = cmdPair.d_args orelse unreachable;
            try db.changeCompletionStatus(io, database, idStr.items[0], true);
            std.debug.print("Task {s} marked as completed.\n", .{idStr.items[0]});
        } else if (std.mem.eql(u8, cmd, "incomplete")) {
            const idStr = cmdPair.d_args orelse unreachable;
            try db.changeCompletionStatus(io, database, idStr.items[0], false);
            std.debug.print("Task {s} marked as incomplete.\n", .{idStr.items[0]});
        } else if (std.mem.eql(u8, cmd, "serve")) {
            const socket_path = "/tmp/todo.sock";
            try server.serve(io, database, socket_path);
        } else {
            std.debug.print("Unknown command: {s}\n", .{cmd});
        }
    }
}
