const std = @import("std");
const c = @import("c");
const db = @import("db");
const json = @import("json");
const server = @import("server");
const sync = @import("sync");
const tui = @import("tui");

/// yazap
const yazap = @import("yazap");
const App = yazap.App;
const Arg = yazap.Arg;
const ArgMatches = yazap.ArgMatches;


const RemoteOptions = struct {
    d_dbUri: []const u8,
    d_password: ?[]const u8 = null,
};

const StartupOption = struct {
    d_local: bool = true,
    d_remoteOptions: ?RemoteOptions = null,
};

fn stdoutWrite(io: std.Io, data: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, data) catch {};
}

fn createDatabase(
    io: std.Io,
    remote: ?RemoteOptions,
    tunnel_child: *std.process.Child,
) db.Db {
    if (remote) |rem| {
        tunnel_child.* = std.process.spawn(io, .{
            .argv = if (rem.d_password) |pw|
                &[_][]const u8{ "sshpass", "-p", pw, "ssh", "-o", "StrictHostKeyChecking=no", "-N", "-L", "3307:127.0.0.1:3306", rem.d_dbUri }
            else
                &[_][]const u8{ "ssh", "-o", "StrictHostKeyChecking=no", "-N", "-L", "3307:127.0.0.1:3306", rem.d_dbUri },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        }) catch {
            std.debug.print("Failed to spawn SSH tunnel.\n", .{});
            return .{ .sqlite = undefined };
        };
        std.Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_s }, .real) catch {};
        const mariadb = db.initMariaDb("127.0.0.1", 3307, rem.d_password) catch {
            std.debug.print("Failed to connect to remote database.\n", .{});
            return .{ .sqlite = undefined };
        };
        return .{ .mariadb = mariadb };
    } else {
        const sqlite = db.initDb("todo.db\x00") catch {
            std.debug.print("Failed to open local database.\n", .{});
            return .{ .sqlite = undefined };
        };
        return .{ .sqlite = sqlite };
    }
}

fn addTaskCmd(database: db.Db, desc: []const u8) void {
    db.addTask(database, desc) catch {
        std.debug.print("Error: failed to add task.\n", .{});
        return;
    };
    std.debug.print("Task added.\n", .{});
}

fn listCmd(
    io: std.Io,
    database: db.Db,
    showAll: bool,
    jsonOutput: bool,
    interactive: bool,
    arena: std.mem.Allocator,
) void {
    if (interactive) {
        tui.run(io, database, showAll) catch {
            std.debug.print("Error: interactive mode failed.\n", .{});
        };
    } else if (jsonOutput) {
        const tasks = db.queryTasks(database, showAll, arena) catch {
            std.debug.print("Error: failed to query tasks.\n", .{});
            return;
        };
        const output = json.serializeTasksJson(tasks.items, arena) catch {
            std.debug.print("Error: failed to serialize tasks.\n", .{});
            return;
        };
        stdoutWrite(io, output);
    } else {
        db.listTasks(io, database, showAll) catch {
            std.debug.print("Error: failed to list tasks.\n", .{});
        };
    }
}

fn interactiveCmd(io: std.Io, database: db.Db, showAll: bool) void {
    tui.run(io, database, showAll) catch {
        std.debug.print("Error: interactive mode failed.\n", .{});
    };
}

fn completeCmd(io: std.Io, database: db.Db, idStr: []const u8) void {
    db.changeCompletionStatus(io, database, idStr, true) catch {
        std.debug.print("Error: failed to complete task {s}.\n", .{idStr});
        return;
    };
    std.debug.print("Task {s} marked as completed.\n", .{idStr});
}

fn incompleteCmd(io: std.Io, database: db.Db, idStr: []const u8) void {
    db.changeCompletionStatus(io, database, idStr, false) catch {
        std.debug.print("Error: failed to mark task {s} as incomplete.\n", .{idStr});
        return;
    };
    std.debug.print("Task {s} marked as incomplete.\n", .{idStr});
}

fn serveCmd(io: std.Io, database: db.Db) void {
    const socket_path = "/tmp/todo.sock";
    server.serve(io, database, socket_path) catch {
        std.debug.print("Error: server failed.\n", .{});
    };
}

fn runSync(
    io: std.Io,
    remote: RemoteOptions,
    sync_matches: ArgMatches,
    arena: std.mem.Allocator,
) !void {
    const local_sqlite = db.initDb("todo.db\x00") catch {
        std.debug.print("Error: failed to open local database.\n", .{});
        return;
    };
    defer _ = c.sqlite3_close(local_sqlite);

    std.debug.print("Opening SSH tunnel to {s}...\n", .{remote.d_dbUri});

    var argv: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty;
    if (remote.d_password) |pw| {
        try argv.appendSlice(arena, &[_][]const u8{ "sshpass", "-p", pw });
    }
    try argv.appendSlice(arena, &[_][]const u8{
        "ssh", "-o", "StrictHostKeyChecking=no", "-N", "-L", "3307:127.0.0.1:3306", remote.d_dbUri,
    });

    var tunnel_child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    defer tunnel_child.kill(io);
    std.Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_s }, .real) catch {};
    const mariadb = db.initMariaDb("127.0.0.1", 3307, remote.d_password) catch {
        std.debug.print("Error: failed to connect to remote database.\n", .{});
        return;
    };
    defer c.mysql_close(mariadb);

    var direction: sync.SyncDirection = .both;
    const dry_run = sync_matches.containsArg("dry-run");

    if (sync_matches.getSingleValue("direction")) |dirStr| {
        if (std.mem.eql(u8, dirStr, "push")) {
            direction = .push;
        } else if (std.mem.eql(u8, dirStr, "pull")) {
            direction = .pull;
        } else if (std.mem.eql(u8, dirStr, "both")) {
            direction = .both;
        } else {
            std.debug.print("Error: unknown sync direction '{s}'.\n", .{dirStr});
            return;
        }
    }

    _ = sync.syncTasks(io, local_sqlite, mariadb, direction, dry_run, arena) catch {
        std.debug.print("Error: sync failed.\n", .{});
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = init.minimal.args;
    // yazap init
    var app = App.init(init.arena.allocator(), "todo", "Todo app that integrates with either local Sqlite db or remote Mariadb instance");
    defer app.deinit();

    // get the root yazap subcommand
    var todo = app.rootCommand();
    todo.setProperty(.help_on_empty_args);

    // global flags/options
    try todo.addArg(Arg.singleValueOption("remote", 'r', "remote of the MariaDB"));
    try todo.addArg(Arg.singleValueOption("password", 'p', "password of the host where the MariaDB is hosted"));

    // `todo add <description>`
    var add_cmd = app.createCommand("add", "Add a task to the todo list");
    try add_cmd.addArg(Arg.positional("description", "Task description", null));
    try todo.addSubcommand(add_cmd);

    // `todo list [OPTIONS]`
    var list_cmd = app.createCommand("list", "List tasks. By default specifies all incomplete tasks. Use `-a` for all tasks.");
    try list_cmd.addArg(Arg.booleanOption("all", 'a', "If given, list all tasks in database."));
    try list_cmd.addArg(Arg.booleanOption("complete", 'c', "If given, list complete tasks in database."));
    try list_cmd.addArg(Arg.booleanOption("interactive", 'i', "Interactive tui mode."));
    try list_cmd.addArg(Arg.booleanOption("json", 'j', "Output tasks as JSON."));
    try todo.addSubcommand(list_cmd);

    // `todo interactive`
    const interactive_cmd = app.createCommand("interactive", "Interactive tui mode. Alias for `todo list -i`.");
    try todo.addSubcommand(interactive_cmd);

    // `todo complete <task_id>`
    var complete_cmd = app.createCommand("complete", "Complete a task given its `<task_id>`.");
    try complete_cmd.addArg(Arg.positional("task_id", "Task ID of the task to complete", null));
    try todo.addSubcommand(complete_cmd);

    // `todo incomplete <task_id>`
    var incomplete_cmd = app.createCommand("incomplete", "Mark a task as incomplete given its `<task_id>`.");
    try incomplete_cmd.addArg(Arg.positional("task_id", "Task ID of the task to mark incomplete", null));
    try todo.addSubcommand(incomplete_cmd);

    // `todo serve`
    const serve_cmd = app.createCommand("serve", "Start JSON-RPC daemon on Unix socket.");
    try todo.addSubcommand(serve_cmd);

    // `todo sync [push|pull|both] [--dry-run]`
    var sync_cmd = app.createCommand("sync", "Sync the local/remote databases.");
    try sync_cmd.addArg(Arg.positional("direction", "Sync direction: push, pull, or both", null));
    try sync_cmd.addArg(Arg.booleanOption("dry-run", null, "Show what would be done without making changes"));
    try todo.addSubcommand(sync_cmd);

    // parse args
    const matches = try app.parseProcess(io, args);

    // startup options parsing
    var startupOptions = StartupOption{
        .d_local = true,
        .d_remoteOptions = null,
    };

    if (matches.getSingleValue("remote")) |remote| {
        startupOptions.d_remoteOptions = .{ .d_dbUri = remote };
    }

    if (matches.getSingleValue("password")) |password| {
        if (startupOptions.d_remoteOptions) |*remote| {
            remote.d_password = password;
        } else {
            startupOptions.d_remoteOptions = .{ .d_dbUri = "", .d_password = password };
        }
    }

    // handle subcommands using yazap matches
    if (matches.subcommandMatches("add")) |add_matches| {
        var tunnel_child: std.process.Child = undefined;
        const database = createDatabase(io, startupOptions.d_remoteOptions, &tunnel_child);
        defer tunnel_child.kill(io);
        defer switch (database) {
            .sqlite => |s| _ = c.sqlite3_close(s),
            .mariadb => |m| c.mysql_close(m),
        };
        const desc = add_matches.getSingleValue("description") orelse {
            std.debug.print("Missing description for 'add'.\n", .{});
            return;
        };
        addTaskCmd(database, desc);
    } else if (matches.subcommandMatches("list")) |list_matches| {
        var tunnel_child: std.process.Child = undefined;
        const database = createDatabase(io, startupOptions.d_remoteOptions, &tunnel_child);
        defer tunnel_child.kill(io);
        defer switch (database) {
            .sqlite => |s| _ = c.sqlite3_close(s),
            .mariadb => |m| c.mysql_close(m),
        };
        const showAll = list_matches.containsArg("all");
        const jsonOutput = list_matches.containsArg("json");
        const interactive = list_matches.containsArg("interactive");
        listCmd(io, database, showAll, jsonOutput, interactive, init.arena.allocator());
    } else if (matches.subcommandMatches("interactive")) |_| {
        var tunnel_child: std.process.Child = undefined;
        const database = createDatabase(io, startupOptions.d_remoteOptions, &tunnel_child);
        defer tunnel_child.kill(io);
        defer switch (database) {
            .sqlite => |s| _ = c.sqlite3_close(s),
            .mariadb => |m| c.mysql_close(m),
        };
        interactiveCmd(io, database, false);
    } else if (matches.subcommandMatches("complete")) |complete_matches| {
        var tunnel_child: std.process.Child = undefined;
        const database = createDatabase(io, startupOptions.d_remoteOptions, &tunnel_child);
        defer tunnel_child.kill(io);
        defer switch (database) {
            .sqlite => |s| _ = c.sqlite3_close(s),
            .mariadb => |m| c.mysql_close(m),
        };
        const idStr = complete_matches.getSingleValue("task_id") orelse {
            std.debug.print("Missing task_id for 'complete'.\n", .{});
            return;
        };
        completeCmd(io, database, idStr);
    } else if (matches.subcommandMatches("incomplete")) |incomplete_matches| {
        var tunnel_child: std.process.Child = undefined;
        const database = createDatabase(io, startupOptions.d_remoteOptions, &tunnel_child);
        defer tunnel_child.kill(io);
        defer switch (database) {
            .sqlite => |s| _ = c.sqlite3_close(s),
            .mariadb => |m| c.mysql_close(m),
        };
        const idStr = incomplete_matches.getSingleValue("task_id") orelse {
            std.debug.print("Missing task_id for 'incomplete'.\n", .{});
            return;
        };
        incompleteCmd(io, database, idStr);
    } else if (matches.subcommandMatches("sync")) |sync_matches| {
        const remote = startupOptions.d_remoteOptions orelse {
            std.debug.print("Error: sync requires -r <host> flag for remote database.\n", .{});
            return;
        };
        try runSync(io, remote, sync_matches, init.arena.allocator());
    } else if (matches.subcommandMatches("serve")) |_| {
        var tunnel_child: std.process.Child = undefined;
        const database = createDatabase(io, startupOptions.d_remoteOptions, &tunnel_child);
        defer tunnel_child.kill(io);
        defer switch (database) {
            .sqlite => |s| _ = c.sqlite3_close(s),
            .mariadb => |m| c.mysql_close(m),
        };
        serveCmd(io, database);
    } else {
        std.debug.print("Usage: todo [-r <host>] [-p <password>] <add|list|complete|incomplete|serve|sync|interactive> [args]\n", .{});
        return;
    }
}
