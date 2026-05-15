const std = @import("std");
const db = @import("db");
const server = @import("server");
const tui = @import("tui");

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

fn writeJsonEscaped(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.print("{c}", .{ch});
                }
            },
        }
    }
}

fn stdoutWrite(io: std.Io, data: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, data) catch {};
}

fn printHelp(io: std.Io) void {
    const help =
        \\Usage: todo [flags] <command> [args]
        \\
        \\Commands:
        \\  add <description>     Add a new task
        \\  list [--all] [--json] [-i]  List tasks (default: incomplete only)
        \\  complete <id>         Mark task as completed
        \\  incomplete <id>       Mark task as incomplete
        \\  serve                 Start JSON-RPC daemon on Unix socket
        \\  interactive           Interactive TUI mode (alias for list -i)
        \\
        \\Flags:
        \\  -r, --remote <host>   Remote MariaDB host (via SSH tunnel)
        \\  -p, --password <pw>   Password for remote connection
        \\  -h, --help            Show this help
        \\
    ;
    stdoutWrite(io, help);
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

    if (std.mem.eql(u8, firstArg, "--help") or std.mem.eql(u8, firstArg, "-h")) {
        printHelp(io);
        return;
    }

    var commandAndArgs: std.ArrayList(CmdPair) = std.ArrayList(CmdPair).empty;
    if (std.mem.eql(u8, firstArg, "add")) {
        var parts: std.ArrayList([]const u8) = .empty;
        while (argsIter.next()) |word| {
            try parts.append(init.arena.allocator(), word);
        }
        if (parts.items.len == 0) {
            std.debug.print("Missing description for '{s}'.\n", .{firstArg});
            return;
        }
        // Join all parts with spaces
        var totalLen: usize = 0;
        for (parts.items, 0..) |part, i| {
            totalLen += part.len;
            if (i < parts.items.len - 1) totalLen += 1;
        }
        const joined = try init.arena.allocator().alloc(u8, totalLen);
        var pos: usize = 0;
        for (parts.items, 0..) |part, i| {
            @memcpy(joined[pos..][0..part.len], part);
            pos += part.len;
            if (i < parts.items.len - 1) {
                joined[pos] = ' ';
                pos += 1;
            }
        }
        var cmdPair: CmdPair = .{
            .d_args = Args.empty,
            .d_cmd = firstArg,
        };
        try cmdPair.d_args.?.append(init.arena.allocator(), joined);
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
        // Check for --all, --json, -i flags
        while (argsIter.next()) |nextArg| {
            if (std.mem.eql(u8, nextArg, "--all") or std.mem.eql(u8, nextArg, "--json") or std.mem.eql(u8, nextArg, "-i")) {
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
                } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    printHelp(io);
                    return;
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
        database = .{ .mariadb = db.initMariaDb("127.0.0.1", 3307, remote.d_password) catch {
            std.debug.print("Failed to connect to remote database.\n", .{});
            return;
        } };
    } else {
        database = .{ .sqlite = db.initDb(dbPath) catch {
            std.debug.print("Failed to open local database.\n", .{});
            return;
        } };
    }

    defer if (tunnel_child) |*child| {
        child.kill(io);
    };

    defer db.close(database);

    for (commandAndArgs.items) |cmdPair| {
        const cmd = cmdPair.d_cmd;
        if (std.mem.eql(u8, cmd, "add")) {
            const desc = cmdPair.d_args orelse unreachable;
            db.addTask(database, desc.items[0]) catch {
                std.debug.print("Error: failed to add task.\n", .{});
                continue;
            };
            std.debug.print("Task added.\n", .{});
        } else if (std.mem.eql(u8, cmd, "list")) {
            var showAll = false;
            var jsonOutput = false;
            var interactive = false;
            if (cmdPair.d_args) |a| {
                for (a.items) |flag| {
                    if (std.mem.eql(u8, flag, "--all")) showAll = true;
                    if (std.mem.eql(u8, flag, "--json")) jsonOutput = true;
                    if (std.mem.eql(u8, flag, "-i")) interactive = true;
                }
            }
            if (interactive) {
                tui.run(io, database, showAll) catch {
                    std.debug.print("Error: interactive mode failed.\n", .{});
                };
            } else if (jsonOutput) {
                const tasks = db.queryTasks(database, showAll, init.arena.allocator()) catch {
                    std.debug.print("Error: failed to query tasks.\n", .{});
                    continue;
                };
                var stdout_buf: [8192]u8 = undefined;
                var w = std.Io.File.stdout().writer(io, &stdout_buf);
                w.interface.writeAll("[") catch {};
                for (tasks.items, 0..) |task, i| {
                    if (i > 0) w.interface.writeAll(",") catch {};
                    w.interface.writeAll("{\"id\":\"") catch {};
                    writeJsonEscaped(&w.interface, task.id) catch {};
                    w.interface.writeAll("\",\"title\":\"") catch {};
                    writeJsonEscaped(&w.interface, task.title) catch {};
                    w.interface.writeAll("\",\"status\":\"") catch {};
                    writeJsonEscaped(&w.interface, task.status) catch {};
                    w.interface.writeAll("\"}") catch {};
                }
                w.interface.writeAll("]\n") catch {};
                w.interface.flush() catch {};
            } else {
                db.listTasks(io, database, showAll) catch {
                    std.debug.print("Error: failed to list tasks.\n", .{});
                    continue;
                };
            }
        } else if (std.mem.eql(u8, cmd, "complete")) {
            const idStr = cmdPair.d_args orelse unreachable;
            db.changeCompletionStatus(io, database, idStr.items[0], true) catch {
                std.debug.print("Error: failed to complete task {s}.\n", .{idStr.items[0]});
                continue;
            };
            std.debug.print("Task {s} marked as completed.\n", .{idStr.items[0]});
        } else if (std.mem.eql(u8, cmd, "incomplete")) {
            const idStr = cmdPair.d_args orelse unreachable;
            db.changeCompletionStatus(io, database, idStr.items[0], false) catch {
                std.debug.print("Error: failed to mark task {s} as incomplete.\n", .{idStr.items[0]});
                continue;
            };
            std.debug.print("Task {s} marked as incomplete.\n", .{idStr.items[0]});
        } else if (std.mem.eql(u8, cmd, "serve")) {
            const socket_path = "/tmp/todo.sock";
            server.serve(io, database, socket_path) catch {
                std.debug.print("Error: server failed.\n", .{});
            };
        } else {
            std.debug.print("Unknown command: {s}\n", .{cmd});
        }
    }
}
