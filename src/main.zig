const std = @import("std");

const Iterator =  std.process.Args.Iterator;

// Import the SQLite C API
const c = @import("c");

const Args = std.ArrayList([]const u8);

const CmdPair = struct {
    d_cmd: []const u8,
    d_args: ?Args
};

const RemoteOptions = struct {
    d_dbUri: []const u8,
    d_password: ?[]const u8 = null,
};

const StartupOption = struct {
    d_local: bool = true,
    d_remoteOptions: ?RemoteOptions = null
};

const SqlError = error{ SqlError };

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
                }
            };
       },
       else => return false
    }

    return true;
}

const Db = union(enum) {
    sqlite: *c.sqlite3,
    mariadb: *c.MYSQL,
};

fn checkError(rc: c_int, db: ?*c.sqlite3) !void {
    if (rc != c.SQLITE_OK) {
        const msg = std.mem.span(c.sqlite3_errmsg(db.?));
        std.debug.print("SQLite error: {s}\n", .{msg});
        return SqlError.SqlError;
    }
}

// Open (or create) the database and ensure the tasks table exists
fn initDb(dbPath: []const u8) !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(dbPath.ptr, &db);
    try checkError(rc, db);

    const createTable = "CREATE TABLE IF NOT EXISTS tasks (\n  id INTEGER PRIMARY KEY AUTOINCREMENT,\n  description TEXT NOT NULL,\n  completed INTEGER NOT NULL DEFAULT 0\n)";
    var errMsg: [*c]u8 = undefined;
    // sqlite3_exec expects a null-terminated string. Our Zig string literal is null-terminated.
    const rc2 = c.sqlite3_exec(db, createTable, null, null, &errMsg);
    if (rc2 != c.SQLITE_OK) {
        const msg = if (errMsg != 0) std.mem.span(errMsg) else "unknown error";
        std.debug.print("SQLite exec error: {s}\n", .{msg});
        if (errMsg != 0) c.sqlite3_free(errMsg);
        return SqlError.SqlError;
    }
    return db.?;
}

fn initMariaDb(host: []const u8, port: u16, password: ?[]const u8) !*c.MYSQL {
    const conn = c.mysql_init(null) orelse return error.OutOfMemory;
    const pw_ptr = if (password) |pw| pw.ptr else null;
    if (c.mysql_real_connect(conn, host.ptr, "root", pw_ptr, "supernotedb", port, null, 0) == null) {
        std.debug.print("MariaDB connection error: {s}\n", .{c.mysql_error(conn)});
        return error.SqlError;
    }
    return conn;
}

// Insert a new task
fn addTask(db: Db, desc: []const u8) !void {
    switch (db) {
        .sqlite => |s| {
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "INSERT INTO tasks (description) VALUES (?);";
            const rc = c.sqlite3_prepare_v2(s, sql, @intCast(sql.len + 1), &stmt, null);
            try checkError(rc, s);
            defer _ = c.sqlite3_finalize(stmt);

            _ = c.sqlite3_bind_text(stmt, 1, desc.ptr, @intCast(desc.len), c.SQLITE_TRANSIENT);
            const rc2 = c.sqlite3_step(stmt);
            if (rc2 != c.SQLITE_DONE) {
                try checkError(rc2, s);
            }
        },
        .mariadb => {
            std.debug.print("Add task not yet implemented for MariaDB (needs task_id generation).\n", .{});
            return error.SqlError;
        },
    }
}

// List all tasks
fn listTasks(io: std.Io, db: Db) !void {
    _ = io;
    switch (db) {
        .sqlite => |s| {
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "SELECT id, description, completed FROM tasks ORDER BY id;";
            const rc = c.sqlite3_prepare_v2(s, sql, @intCast(sql.len + 1), &stmt, null);
            try checkError(rc, s);
            defer _ = c.sqlite3_finalize(stmt);

            while (true) {
                const step = c.sqlite3_step(stmt);
                if (step == c.SQLITE_ROW) {
                    const id = c.sqlite3_column_int(stmt, 0);
                    const descPtr = c.sqlite3_column_text(stmt, 1);
                    const desc = std.mem.span(descPtr);
                    const completed = c.sqlite3_column_int(stmt, 2) != 0;
                    std.debug.print("{d}. [{s}] {s}\n", .{
                        id,
                        if (completed) "x" else " ",
                        desc,
                    });
                } else if (step == c.SQLITE_DONE) {
                    break;
                } else {
                    try checkError(step, s);
                }
            }
        },
        .mariadb => |m| {
            const query = "SELECT task_id, title, status FROM supernotedb.t_schedule_task ORDER BY last_modified DESC;";
            if (c.mysql_query(m, query) != 0) {
                std.debug.print("MariaDB query error: {s}\n", .{c.mysql_error(m)});
                return error.SqlError;
            }

            const result = c.mysql_store_result(m) orelse {
                std.debug.print("MariaDB store_result error: {s}\n", .{c.mysql_error(m)});
                return error.SqlError;
            } ;
            defer c.mysql_free_result(result);

            while (c.mysql_fetch_row(result)) |row| {
                const id = if (row[0] != null) std.mem.span(row[0]) else "unknown";
                const title = if (row[1] != null) std.mem.span(row[1]) else "(no title)";
                const status = if (row[2] != null) std.mem.span(row[2]) else "";

                const completed = std.mem.eql(u8, status, "completed");

                std.debug.print("{s}. [{s}] {s}\n", .{
                    id,
                    if (completed) "x" else " ",
                    title,
                });
            }
        },
    }
}

// Mark a task as completed
fn changeCompletionStatus(io: std.Io, db: Db, id_str: []const u8, complete: bool) !void {
    switch (db) {
        .sqlite => |s| {
            const id = try std.fmt.parseInt(i64, id_str, 10);
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "UPDATE tasks SET completed = ? WHERE id = ?;";
            const rc = c.sqlite3_prepare_v2(s, sql, @intCast(sql.len + 1), &stmt, null);
            try checkError(rc, s);
            defer _ = c.sqlite3_finalize(stmt);

            _ = c.sqlite3_bind_int64(stmt, 1, @intFromBool(complete));
            _ = c.sqlite3_bind_int64(stmt, 2, id);
            const rc2 = c.sqlite3_step(stmt);
            if (rc2 != c.SQLITE_DONE) {
                try checkError(rc2, s);
            }
        },
        .mariadb => |m| {
            const ts = std.Io.Timestamp.now(io, .real);
            const seconds = @as(u64, @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s)));
            // Using task_id (varchar) for MariaDB
            const query = try std.fmt.allocPrint(std.heap.page_allocator, "UPDATE supernotedb.t_schedule_task SET status = '{s}', completed_time = {d} WHERE task_id = '{s}';", .{
                if (complete) "completed" else "needsAction",
                seconds,
                id_str,
            });
            defer std.heap.page_allocator.free(query);

            if (c.mysql_query(m, query.ptr) != 0) {
                std.debug.print("MariaDB update error: {s}\n", .{c.mysql_error(m)});
                return error.SqlError;
            }
        },
    }
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
            .d_cmd = firstArg
        };
        try cmdPair.d_args.?.append(init.arena.allocator(), other);
        try commandAndArgs.append(init.arena.allocator(), cmdPair);
    }
    else if (std.mem.eql(u8, firstArg, "complete")) {
        const other = argsIter.next() orelse {
            std.debug.print("Missing id for '{s}'.\n", .{firstArg});
            return;
        };
        var cmdPair: CmdPair = .{
            .d_args = Args.empty,
            .d_cmd = firstArg
        };
        try cmdPair.d_args.?.append(init.arena.allocator(), other);
        try commandAndArgs.append(init.arena.allocator(), cmdPair);
    }
    else if (std.mem.eql(u8, firstArg, "list")) {
        const cmdPair: CmdPair = .{
            .d_args = null,
            .d_cmd = firstArg
        };
        try commandAndArgs.append(init.arena.allocator(), cmdPair);
    }
    else {
        // Assume firstArg might be a flag
        // We'll use a simple loop to find the command.
        var currentArg: ?[]const u8 = firstArg;
        while (currentArg) |arg| {
            if (arg[0] == '-') {
                // It's a flag, let's try to parse it
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
                    .d_args = Args.empty
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

    // Use a C-string for sqlite3_open
    const dbPath = "todo.db\x00";

    var tunnel_child: ?std.process.Child = null;
    var db: Db = undefined;
    if (startupOptions.d_remoteOptions) |remote| {
        std.debug.print("Opening SSH tunnel to {s}...\n", .{remote.d_dbUri});

        var argv: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty;
        if (remote.d_password) |pw| {
            try argv.appendSlice(init.arena.allocator(), &[_][]const u8{ "sshpass", "-p", pw });
        }
        try argv.appendSlice(init.arena.allocator(), &[_][]const u8{
            "ssh", "-o", "StrictHostKeyChecking=no", "-N", "-L", "3307:127.0.0.1:3306", remote.d_dbUri
        });

        tunnel_child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        try std.Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_s }, .real);
        db = .{ .mariadb = try initMariaDb("127.0.0.1", 3307, remote.d_password) };
    } else {
        db = .{ .sqlite = try initDb(dbPath) };
    }

    defer if (tunnel_child) |*child| {
        child.kill(io);
    };

    defer switch (db) {
        .sqlite => |s| _ = c.sqlite3_close(s),
        .mariadb => |m| c.mysql_close(m),
    };


    for (commandAndArgs.items) |cmdPair| {
        const cmd = cmdPair.d_cmd;
        if (std.mem.eql(u8, cmd, "add")) {
            const desc = cmdPair.d_args orelse unreachable;
            try addTask(db, desc.items[0]);
            std.debug.print("Task added.\n", .{});
        } else if (std.mem.eql(u8, cmd, "list")) {
            try listTasks(io, db);
        } else if (std.mem.eql(u8, cmd, "complete")) {
            const idStr = cmdPair.d_args orelse unreachable;
            // completeTask now takes the id_str directly to handle both int (SQLite) and varchar (MariaDB)
            try changeCompletionStatus(io, db, idStr.items[0], true);
            std.debug.print("Task {s} marked as completed.\n", .{idStr.items[0]});
        } else if (std.mem.eql(u8, cmd, "incomplete")) {
            const idStr = cmdPair.d_args orelse unreachable;
            // completeTask now takes the id_str directly to handle both int (SQLite) and varchar (MariaDB)
            try changeCompletionStatus(io, db, idStr.items[0], false);
            std.debug.print("Task {s} marked as incomplete.\n", .{idStr.items[0]});
        } else {
            std.debug.print("Unknown command: {s}\n", .{cmd});
        }
    }
}
