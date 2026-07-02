const std = @import("std");
const db = @import("db");
const json = @import("json");
const server = @import("server");
const http = @import("http");
const ssh_tunnel = @import("ssh_tunnel");
const sync = @import("sync");
const tui = @import("tui");
const config = @import("config");

const yazap = @import("yazap");
const App = yazap.App;
const Arg = yazap.Arg;
const ArgMatches = yazap.ArgMatches;

const Conf = config.Configuration;

// --- Types ---

const StartupOption = struct {
    backend: Conf.Backend,
    mariadb: ?Conf.MariadbConfig = null,
    jj: ?Conf.JjConfig = null,
    sqlite: ?Conf.SqliteConfig = null,
};

// --- Database initialization ---

fn stdoutWrite(io: std.Io, data: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, data) catch {};
}

fn createDatabase(
    io: std.Io,
    opts: StartupOption,
    tunnel: *?ssh_tunnel.SshTunnel,
    allocator: std.mem.Allocator,
) !db.AnyBackend {
    switch (opts.backend) {
        .jj => {
            const jj_config = opts.jj.?;
            const jj = db.openJj(allocator, io, jj_config.path) catch |err| {
                std.log.err("failed to open jj database at '{s}': {s}", .{ jj_config.path, @errorName(err) });
                return error.SqlError;
            };
            return .{ .jj = jj };
        },
        .mariadb => {
            const maria = opts.mariadb.?;
            if (std.c.getenv("TODO_MARIADB_PORT")) |port_ptr| {
                std.log.warn("TODO_MARIADB_PORT is set — skipping SSH tunnel (test mode only)", .{});
                const port_str: [:0]const u8 = std.mem.span(port_ptr);
                const port = std.fmt.parseInt(u16, port_str, 10) catch {
                    std.log.err("invalid TODO_MARIADB_PORT value", .{});
                    return error.SqlError;
                };
                const host: []const u8 = if (std.c.getenv("TODO_MARIADB_HOST")) |h| std.mem.span(h) else maria.host;
                const mariadb = db.openMariaDb(allocator, host, port, maria.user, maria.password) catch |err| {
                    std.log.err("failed to connect to test MariaDB: {s}", .{@errorName(err)});
                    return error.SqlError;
                };
                return .{ .mariadb = mariadb };
            }
            if (maria.port) |port| {
                const mariadb = db.openMariaDb(allocator, maria.host, port, maria.user, maria.password) catch |err| {
                    std.log.err("failed to connect to database at {s}:{d}: {s}", .{ maria.host, port, @errorName(err) });
                    return error.SqlError;
                };
                return .{ .mariadb = mariadb };
            }
            tunnel.* = ssh_tunnel.SshTunnel.spawn(io, maria.host, maria.password) catch |err| {
                std.log.err("failed to spawn SSH tunnel: {s}", .{@errorName(err)});
                return error.SqlError;
            };
            errdefer if (tunnel.*) |*t| t.deinit(io);
            const mariadb = db.openMariaDb(allocator, "127.0.0.1", ssh_tunnel.local_forward_port, maria.user, maria.password) catch |err| {
                std.log.err("failed to connect to remote database: {s}", .{@errorName(err)});
                return error.SqlError;
            };
            return .{ .mariadb = mariadb };
        },
        .sqlite => {
            const sqlite_config = opts.sqlite.?;
            const pathZ = try std.fmt.allocPrintSentinel(allocator, "{s}", .{sqlite_config.path}, 0);
            const sqlite = db.openSqlite(allocator, pathZ) catch |err| {
                std.log.err("failed to open local database: {s}", .{@errorName(err)});
                return error.SqlError;
            };
            return .{ .sqlite = sqlite };
        },
    }
}

const DbContext = struct {
    d_database: db.AnyBackend,
    d_tunnel: ?ssh_tunnel.SshTunnel,

    fn init(io: std.Io, opts: StartupOption, allocator: std.mem.Allocator) !DbContext {
        var tunnel: ?ssh_tunnel.SshTunnel = null;
        const database = try createDatabase(io, opts, &tunnel, allocator);
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

fn deleteCmd(io: std.Io, database: db.Db, idStr: []const u8) void {
    db.deleteTask(io, database, idStr) catch |err| {
        if (err == error.TaskNotFound) {
            std.log.err("Task {s} not found.", .{idStr});
        } else {
            std.log.err("Failed to delete task {s}: {s}", .{ idStr, @errorName(err) });
        }
        return;
    };
    std.log.info("Task {s} deleted.", .{idStr});
}

fn serveCmd(io: std.Io, database: db.Db, arena: std.mem.Allocator) void {
    const socket_path = "/tmp/todo.sock";
    server.serve(io, database, socket_path, arena) catch |err| {
        std.log.err("server failed: {s}", .{@errorName(err)});
    };
}

fn httpCmd(io: std.Io, database: db.Db, http_matches: ArgMatches, arena: std.mem.Allocator) void {
    const addr = http_matches.getSingleValue("addr") orelse "127.0.0.1";
    const port_str = http_matches.getSingleValue("port") orelse "2310";
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        std.log.err("invalid port '{s}'", .{port_str});
        return;
    };
    http.serve(io, database, addr, port, arena) catch |err| {
        std.log.err("http server failed: {s}", .{@errorName(err)});
    };
}

fn runSync(
    io: std.Io,
    opts: StartupOption,
    sync_matches: ArgMatches,
    arena: std.mem.Allocator,
) !void {
    const maria = opts.mariadb orelse {
        std.log.err("sync requires mariadb config; set \"mariadb\" in ~/.todo.json or pass -r <host>", .{});
        return error.SqlError;
    };

    const local_db: db.AnyBackend = switch (opts.backend) {
        .jj => blk: {
            const jj_config = opts.jj.?;
            const jj = db.openJj(arena, io, jj_config.path) catch |err| {
                std.log.err("failed to open jj database at '{s}': {s}", .{ jj_config.path, @errorName(err) });
                return error.SqlError;
            };
            break :blk .{ .jj = jj };
        },
        .sqlite, .mariadb => blk: {
            const sqlite_config = opts.sqlite orelse {
                std.log.err("sync requires a local backend; configure \"sqlite.path\" in ~/.todo.json or use -b sqlite", .{});
                return error.SqlError;
            };
            const pathZ = try std.fmt.allocPrintSentinel(arena, "{s}", .{sqlite_config.path}, 0);
            const sqlite = db.openSqlite(arena, pathZ) catch |err| {
                std.log.err("failed to open local database: {s}", .{@errorName(err)});
                return error.SqlError;
            };
            break :blk .{ .sqlite = sqlite };
        },
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
            const host: []const u8 = if (std.c.getenv("TODO_MARIADB_HOST")) |h| std.mem.span(h) else maria.host;
            break :blk db.openMariaDb(arena, host, port, maria.user, maria.password) catch |err| {
                std.log.err("failed to connect to test MariaDB: {s}", .{@errorName(err)});
                return error.SqlError;
            };
        }
        if (maria.port) |port| {
            break :blk db.openMariaDb(arena, maria.host, port, maria.user, maria.password) catch |err| {
                std.log.err("failed to connect to database at {s}:{d}: {s}", .{ maria.host, port, @errorName(err) });
                return error.SqlError;
            };
        }
        std.log.info("Opening SSH tunnel to {s}...", .{maria.host});
        tunnel = ssh_tunnel.SshTunnel.spawn(io, maria.host, maria.password) catch |err| {
            std.log.err("failed to spawn SSH tunnel: {s}", .{@errorName(err)});
            return error.SqlError;
        };
        break :blk db.openMariaDb(arena, "127.0.0.1", ssh_tunnel.local_forward_port, maria.user, maria.password) catch |err| {
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
        std.log.err("syncTasks: {s}", .{@errorName(err)});
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
    const conf = try config.Configuration.init(init);
    var app = App.init(init.arena.allocator(), "todo", "Todo app that integrates with either local Sqlite db or remote Mariadb instance");
    defer app.deinit();

    var todo = app.rootCommand();
    todo.setProperty(.help_on_empty_args);

    try todo.addArg(Arg.singleValueOption("backend", 'b', "Backend to use: sqlite, mariadb, or jj"));
    try todo.addArg(Arg.singleValueOption("remote", 'r', "Remote host for MariaDB (implies -b mariadb)"));
    try todo.addArg(Arg.singleValueOption("password", 'p', "Password for the remote MariaDB host"));
    try todo.addArg(Arg.singleValueOption("jj", 'g', "Path to jj-backed JSON-lines task file (implies -b jj)"));

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

    var delete_cmd = app.createCommand("delete", "Delete a task given its `<task_id>`.");
    try delete_cmd.addArg(Arg.positional("task_id", "Task ID of the task to delete", null));
    try todo.addSubcommand(delete_cmd);

    const serve_cmd = app.createCommand("serve", "Start JSON-RPC daemon on Unix socket.");
    try todo.addSubcommand(serve_cmd);

    var http_cmd = app.createCommand("http", "Serve incomplete tasks read-only over HTTP (GET /tasks, GET /healthz).");
    try http_cmd.addArg(Arg.singleValueOption("addr", null, "Address to listen on (default 127.0.0.1)"));
    try http_cmd.addArg(Arg.singleValueOption("port", null, "Port to listen on (default 2310)"));
    try todo.addSubcommand(http_cmd);

    var sync_cmd = app.createCommand("sync", "Sync the local/remote databases.");
    try sync_cmd.addArg(Arg.positional("direction", "Sync direction: push, pull, or both", null));
    try sync_cmd.addArg(Arg.booleanOption("dry-run", null, "Show what would be done without making changes"));
    try todo.addSubcommand(sync_cmd);

    const matches = try app.parseProcess(io, args);

    var opts = StartupOption{
        .backend = conf.options.backend,
        .mariadb = conf.options.mariadb,
        .jj = conf.options.jj,
        .sqlite = conf.options.sqlite,
    };

    var backend_explicit = false;

    if (matches.getSingleValue("backend")) |b| {
        if (std.mem.eql(u8, b, "sqlite")) {
            opts.backend = .sqlite;
        } else if (std.mem.eql(u8, b, "mariadb")) {
            opts.backend = .mariadb;
        } else if (std.mem.eql(u8, b, "jj")) {
            opts.backend = .jj;
        } else {
            std.log.err("unknown backend '{s}', expected: sqlite, mariadb, or jj", .{b});
            return;
        }
        backend_explicit = true;
    }

    if (matches.getSingleValue("remote")) |host| {
        if (opts.mariadb) |*m| {
            m.host = host;
        } else {
            opts.mariadb = .{ .host = host };
        }
        if (!backend_explicit) opts.backend = .mariadb;
    }

    if (matches.getSingleValue("password")) |pass| {
        if (opts.mariadb) |*m| {
            m.password = pass;
        } else {
            opts.mariadb = .{ .host = "", .password = pass };
        }
    }

    if (matches.getSingleValue("jj")) |path| {
        if (opts.jj) |*j| {
            j.path = path;
        } else {
            opts.jj = .{ .path = path };
        }
        if (!backend_explicit) opts.backend = .jj;
    }

    switch (opts.backend) {
        .mariadb => {
            if (opts.mariadb) |m| {
                if (m.host.len == 0) {
                    std.log.err("backend 'mariadb' requires a host; set \"mariadb.host\" in ~/.todo.json or pass -r <host>", .{});
                    return;
                }
            } else {
                std.log.err("backend 'mariadb' requires a host; set \"mariadb.host\" in ~/.todo.json or pass -r <host>", .{});
                return;
            }
        },
        .jj => {
            if (opts.jj == null) {
                std.log.err("backend 'jj' requires a path; set \"jj.path\" in ~/.todo.json or pass -g <path>", .{});
                return;
            }
        },
        .sqlite => {},
    }

    if (matches.subcommandMatches("add")) |add_matches| {
        var ctx = DbContext.init(io, opts, init.arena.allocator()) catch |err| {
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
        var ctx = DbContext.init(io, opts, init.arena.allocator()) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        const showAll = list_matches.containsArg("all");
        const jsonOutput = list_matches.containsArg("json");
        const interactive = list_matches.containsArg("interactive");
        listCmd(io, ctx.d_database, showAll, jsonOutput, interactive, init.arena.allocator());
    } else if (matches.subcommandMatches("interactive")) |_| {
        var ctx = DbContext.init(io, opts, init.arena.allocator()) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        interactiveCmd(io, ctx.d_database, false, init.arena.allocator());
    } else if (matches.subcommandMatches("complete")) |complete_matches| {
        var ctx = DbContext.init(io, opts, init.arena.allocator()) catch |err| {
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
        var ctx = DbContext.init(io, opts, init.arena.allocator()) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        const idStr = incomplete_matches.getSingleValue("task_id") orelse {
            std.log.info("Missing task_id for 'incomplete'.", .{});
            return;
        };
        incompleteCmd(io, ctx.d_database, idStr);
    } else if (matches.subcommandMatches("delete")) |delete_matches| {
        var ctx = DbContext.init(io, opts, init.arena.allocator()) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        const idStr = delete_matches.getSingleValue("task_id") orelse {
            std.log.info("Missing task_id for 'delete'.", .{});
            return;
        };
        deleteCmd(io, ctx.d_database, idStr);
    } else if (matches.subcommandMatches("sync")) |sync_matches| {
        runSync(io, opts, sync_matches, init.arena.allocator()) catch |err| {
            std.log.err("sync failed: {s}", .{@errorName(err)});
            return;
        };
    } else if (matches.subcommandMatches("serve")) |_| {
        var ctx = DbContext.init(io, opts, init.arena.allocator()) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        serveCmd(io, ctx.d_database, init.arena.allocator());
    } else if (matches.subcommandMatches("http")) |http_matches| {
        var ctx = DbContext.init(io, opts, init.arena.allocator()) catch |err| {
            std.log.err("failed to initialize database: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.deinit(io);
        httpCmd(io, ctx.d_database, http_matches, init.arena.allocator());
    } else {
        app.displayHelp(io) catch {};
        return;
    }
}
