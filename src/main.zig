const std = @import("std");
const db = @import("db");
const json = @import("json");
const server = @import("server");
const ssh_tunnel = @import("ssh_tunnel");
const sync = @import("sync");
const tui = @import("tui");

const yazap = @import("yazap");
const App = yazap.App;
const Arg = yazap.Arg;
const ArgMatches = yazap.ArgMatches;

// --- Types ---

/// Connection details for a remote MariaDB instance accessed via SSH tunnel.
const RemoteOptions = struct {
    d_dbUri: []const u8,
    d_password: ?[]const u8 = null,
};

/// Parsed startup flags controlling local vs. remote database selection.
const StartupOption = struct {
    d_local: bool = true,
    d_remoteOptions: ?RemoteOptions = null,
    d_jjPath: ?[]const u8 = null,
};

// --- Database initialization ---

fn stdoutWrite(io: std.Io, data: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, data) catch {};
}

/// Opens either a local SQLite or remote MariaDB (via SSH tunnel) depending on options.
/// On remote, spawns the tunnel and writes it back through `tunnel` for lifetime management.
/// If TODO_MARIADB_PORT is set, skips SSH and connects directly (test mode).
fn createDatabase(
    io: std.Io,
    remote: ?RemoteOptions,
    tunnel: *?ssh_tunnel.SshTunnel,
    allocator: std.mem.Allocator,
    jj_path: ?[]const u8,
) !db.AnyBackend {
    if (jj_path) |path| {
        const jj = db.openJj(allocator, io, path) catch |err| {
            std.log.err("failed to open jj database at '{s}': {s}", .{ path, @errorName(err) });
            return error.SqlError;
        };
        return .{ .jj = jj };
    }
    if (remote) |rem| {
        if (std.c.getenv("TODO_MARIADB_PORT")) |port_ptr| {
            std.log.warn("TODO_MARIADB_PORT is set — skipping SSH tunnel (test mode only)", .{});
            const port_str: [:0]const u8 = std.mem.span(port_ptr);
            const port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.log.err("invalid TODO_MARIADB_PORT value", .{});
                return error.SqlError;
            };
            const host: []const u8 = if (std.c.getenv("TODO_MARIADB_HOST")) |h| std.mem.span(h) else rem.d_dbUri;
            const mariadb = db.openMariaDb(allocator, host, port, rem.d_password) catch |err| {
                std.log.err("failed to connect to test MariaDB: {s}", .{@errorName(err)});
                return error.SqlError;
            };
            return .{ .mariadb = mariadb };
        }
        tunnel.* = ssh_tunnel.SshTunnel.spawn(io, rem.d_dbUri, rem.d_password) catch |err| {
            std.log.err("failed to spawn SSH tunnel: {s}", .{@errorName(err)});
            return error.SqlError;
        };
        errdefer if (tunnel.*) |*t| t.deinit(io);
        const mariadb = db.openMariaDb(allocator, "127.0.0.1", ssh_tunnel.local_forward_port, rem.d_password) catch |err| {
            std.log.err("failed to connect to remote database: {s}", .{@errorName(err)});
            return error.SqlError;
        };
        return .{ .mariadb = mariadb };
    } else {
        const sqlite = db.openSqlite(allocator, "todo.db") catch |err| {
            std.log.err("failed to open local database: {s}", .{@errorName(err)});
            return error.SqlError;
        };
        return .{ .sqlite = sqlite };
    }
}

/// Owns a database handle and its optional SSH tunnel, ensuring paired cleanup.
const DbContext = struct {
    d_database: db.AnyBackend,
    d_tunnel: ?ssh_tunnel.SshTunnel,

    fn init(io: std.Io, remote: ?RemoteOptions, allocator: std.mem.Allocator, jj_path: ?[]const u8) !DbContext {
        var tunnel: ?ssh_tunnel.SshTunnel = null;
        const database = try createDatabase(io, remote, &tunnel, allocator, jj_path);
        return .{ .d_database = database, .d_tunnel = tunnel };
    }

    fn deinit(self: *DbContext, io: std.Io) void {
        db.close(self.d_database);
        if (self.d_tunnel) |*t| t.deinit(io);
    }
};

// --- Subcommand handlers ---

fn addTaskCmd(io: std.Io, database: db.Db, desc: []const u8) void {
    db.addTask(io, database, desc) catch return;
    std.log.info("Task added.", .{});
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
        tui.run(io, database, showAll, arena) catch |err| {
            std.log.err("interactive mode failed: {s}", .{@errorName(err)});
        };
    } else if (jsonOutput) {
        const tasks = db.queryTasks(database, showAll, arena) catch |err| {
            std.log.err("failed to query tasks: {s}", .{@errorName(err)});
            return;
        };
        const output = json.serializeTasksJson(tasks.items, arena) catch |err| {
            std.log.err("failed to serialize tasks: {s}", .{@errorName(err)});
            return;
        };
        stdoutWrite(io, output);
    } else {
        db.listTasks(io, database, showAll, arena) catch |err| {
            std.log.err("failed to list tasks: {s}", .{@errorName(err)});
        };
    }
}

fn interactiveCmd(io: std.Io, database: db.Db, showAll: bool, arena: std.mem.Allocator) void {
    tui.run(io, database, showAll, arena) catch |err| {
        std.log.err("interactive mode failed: {s}", .{@errorName(err)});
    };
}

fn completeCmd(io: std.Io, database: db.Db, idStr: []const u8) void {
    db.changeCompletionStatus(io, database, idStr, true) catch return;
    std.log.info("Task {s} marked as completed.", .{idStr});
}

fn incompleteCmd(io: std.Io, database: db.Db, idStr: []const u8) void {
    db.changeCompletionStatus(io, database, idStr, false) catch return;
    std.log.info("Task {s} marked as incomplete.", .{idStr});
}

fn serveCmd(io: std.Io, database: db.Db, arena: std.mem.Allocator) void {
    const socket_path = "/tmp/todo.sock";
    server.serve(io, database, socket_path, arena) catch |err| {
        std.log.err("server failed: {s}", .{@errorName(err)});
    };
}

/// Opens local (SQLite or jj) and remote MariaDB, then runs bidirectional sync.
fn runSync(
    io: std.Io,
    remote: RemoteOptions,
    jj_path: ?[]const u8,
    sync_matches: ArgMatches,
    arena: std.mem.Allocator,
) !void {
    const local_db: db.AnyBackend = if (jj_path) |path| blk: {
        const jj = db.openJj(arena, io, path) catch |err| {
            std.log.err("failed to open jj database at '{s}': {s}", .{ path, @errorName(err) });
            return error.SqlError;
        };
        break :blk .{ .jj = jj };
    } else blk: {
        const sqlite = db.openSqlite(arena, "todo.db") catch |err| {
            std.log.err("failed to open local database: {s}", .{@errorName(err)});
            return error.SqlError;
        };
        break :blk .{ .sqlite = sqlite };
    };
    defer db.close(local_db);

    var tunnel: ?ssh_tunnel.SshTunnel = null;
    const mariadb = blk: {
        if (std.c.getenv("TODO_MARIADB_PORT")) |port_ptr| {
            std.log.warn("TODO_MARIADB_PORT is set — skipping SSH tunnel (test mode only)", .{});
            const port_str: [:0]const u8 = std.mem.span(port_ptr);
            const port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.log.err("invalid TODO_MARIADB_PORT value", .{});
                return error.SqlError;
            };
            const host: []const u8 = if (std.c.getenv("TODO_MARIADB_HOST")) |h| std.mem.span(h) else remote.d_dbUri;
            break :blk db.openMariaDb(arena, host, port, remote.d_password) catch |err| {
                std.log.err("failed to connect to test MariaDB: {s}", .{@errorName(err)});
                return error.SqlError;
            };
        }
        std.log.info("Opening SSH tunnel to {s}...", .{remote.d_dbUri});
        tunnel = ssh_tunnel.SshTunnel.spawn(io, remote.d_dbUri, remote.d_password) catch |err| {
            std.log.err("failed to spawn SSH tunnel: {s}", .{@errorName(err)});
            return error.SqlError;
        };
        break :blk db.openMariaDb(arena, "127.0.0.1", ssh_tunnel.local_forward_port, remote.d_password) catch |err| {
            std.log.err("failed to connect to remote database: {s}", .{@errorName(err)});
            return error.SqlError;
        };
    };
    defer if (tunnel) |*t| t.deinit(io);
    const remote_db: db.AnyBackend = .{ .mariadb = mariadb };
    defer db.close(remote_db);

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
            std.log.err("unknown sync direction '{s}'", .{dirStr});
            return error.SqlError;
        }
    }

    _ = sync.syncTasks(io, local_db, remote_db, direction, dry_run, arena) catch |err| {
        std.log.err("sync failed: {s}", .{@errorName(err)});
        return;
    };

    switch (local_db) {
        .jj => |jj| jj.syncToRemote(),
        else => {},
    }
}

// --- Entry point ---

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = init.minimal.args;

    var app = App.init(init.arena.allocator(), "todo", "Todo app that integrates with either local Sqlite db or remote Mariadb instance");
    defer app.deinit();

    var todo = app.rootCommand();
    todo.setProperty(.help_on_empty_args);

    try todo.addArg(Arg.singleValueOption("remote", 'r', "remote of the MariaDB"));
    try todo.addArg(Arg.singleValueOption("password", 'p', "password of the host where the MariaDB is hosted"));
    try todo.addArg(Arg.singleValueOption("jj", 'g', "path to jj-backed JSON-lines task file (uses jj backend instead of SQLite)"));

    var add_cmd = app.createCommand("add", "Add a task to the todo list");
    try add_cmd.addArg(Arg.positional("description", "Task description", null));
    try todo.addSubcommand(add_cmd);

    var list_cmd = app.createCommand("list", "List tasks. By default specifies all incomplete tasks. Use `-a` for all tasks.");
    try list_cmd.addArg(Arg.booleanOption("all", 'a', "If given, list all tasks in database."));
    try list_cmd.addArg(Arg.booleanOption("interactive", 'i', "Interactive tui mode."));
    try list_cmd.addArg(Arg.booleanOption("json", 'j', "Output tasks as JSON."));
    try todo.addSubcommand(list_cmd);

    const interactive_cmd = app.createCommand("interactive", "Interactive tui mode. Alias for `todo list -i`.");
    try todo.addSubcommand(interactive_cmd);

    var complete_cmd = app.createCommand("complete", "Complete a task given its `<task_id>`.");
    try complete_cmd.addArg(Arg.positional("task_id", "Task ID of the task to complete", null));
    try todo.addSubcommand(complete_cmd);

    var incomplete_cmd = app.createCommand("incomplete", "Mark a task as incomplete given its `<task_id>`.");
    try incomplete_cmd.addArg(Arg.positional("task_id", "Task ID of the task to mark incomplete", null));
    try todo.addSubcommand(incomplete_cmd);

    const serve_cmd = app.createCommand("serve", "Start JSON-RPC daemon on Unix socket.");
    try todo.addSubcommand(serve_cmd);

    var sync_cmd = app.createCommand("sync", "Sync the local/remote databases.");
    try sync_cmd.addArg(Arg.positional("direction", "Sync direction: push, pull, or both", null));
    try sync_cmd.addArg(Arg.booleanOption("dry-run", null, "Show what would be done without making changes"));
    try todo.addSubcommand(sync_cmd);

    const matches = try app.parseProcess(io, args);

    var startupOptions = StartupOption{
        .d_local = true,
        .d_remoteOptions = null,
    };

    if (matches.getSingleValue("jj")) |jj_path| {
        startupOptions.d_jjPath = jj_path;
    }

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

    if (startupOptions.d_remoteOptions) |rem| {
        if (rem.d_dbUri.len == 0) {
            std.log.info("Error: -p requires -r <host> to specify the remote host.", .{});
            return;
        }
    }

    if (matches.subcommandMatches("add")) |add_matches| {
        var ctx = DbContext.init(io, startupOptions.d_remoteOptions, init.arena.allocator(), startupOptions.d_jjPath) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        const desc = add_matches.getSingleValue("description") orelse {
            std.log.info("Missing description for 'add'.", .{});
            return;
        };
        addTaskCmd(io, ctx.d_database, desc);
    } else if (matches.subcommandMatches("list")) |list_matches| {
        var ctx = DbContext.init(io, startupOptions.d_remoteOptions, init.arena.allocator(), startupOptions.d_jjPath) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        const showAll = list_matches.containsArg("all");
        const jsonOutput = list_matches.containsArg("json");
        const interactive = list_matches.containsArg("interactive");
        listCmd(io, ctx.d_database, showAll, jsonOutput, interactive, init.arena.allocator());
    } else if (matches.subcommandMatches("interactive")) |_| {
        var ctx = DbContext.init(io, startupOptions.d_remoteOptions, init.arena.allocator(), startupOptions.d_jjPath) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        interactiveCmd(io, ctx.d_database, false, init.arena.allocator());
    } else if (matches.subcommandMatches("complete")) |complete_matches| {
        var ctx = DbContext.init(io, startupOptions.d_remoteOptions, init.arena.allocator(), startupOptions.d_jjPath) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        const idStr = complete_matches.getSingleValue("task_id") orelse {
            std.log.info("Missing task_id for 'complete'.", .{});
            return;
        };
        completeCmd(io, ctx.d_database, idStr);
    } else if (matches.subcommandMatches("incomplete")) |incomplete_matches| {
        var ctx = DbContext.init(io, startupOptions.d_remoteOptions, init.arena.allocator(), startupOptions.d_jjPath) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        const idStr = incomplete_matches.getSingleValue("task_id") orelse {
            std.log.info("Missing task_id for 'incomplete'.", .{});
            return;
        };
        incompleteCmd(io, ctx.d_database, idStr);
    } else if (matches.subcommandMatches("sync")) |sync_matches| {
        const remote = startupOptions.d_remoteOptions orelse {
            std.log.info("Error: sync requires -r <host> flag for remote database.", .{});
            return;
        };
        runSync(io, remote, startupOptions.d_jjPath, sync_matches, init.arena.allocator()) catch |err| {
            std.log.err("sync failed: {s}", .{@errorName(err)});
            return;
        };
    } else if (matches.subcommandMatches("serve")) |_| {
        var ctx = DbContext.init(io, startupOptions.d_remoteOptions, init.arena.allocator(), startupOptions.d_jjPath) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        serveCmd(io, ctx.d_database, init.arena.allocator());
    } else {
        app.displayHelp(io) catch {};
        return;
    }
}
