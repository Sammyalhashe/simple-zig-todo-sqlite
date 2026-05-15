const std = @import("std");
const c = @import("c");

pub const SqlError = error{SqlError};

pub const Task = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
};

pub const Db = union(enum) {
    sqlite: *c.sqlite3,
    mariadb: *c.MYSQL,
};

fn checkError(rc: c_int, db: ?*c.sqlite3) !void {
    if (rc != c.SQLITE_OK) {
        if (db) |d| {
            const msg = std.mem.span(c.sqlite3_errmsg(d));
            std.debug.print("SQLite error: {s}\n", .{msg});
        } else {
            std.debug.print("SQLite error: (null db handle)\n", .{});
        }
        return SqlError.SqlError;
    }
}

pub fn initDb(dbPath: []const u8) !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(dbPath.ptr, &db);
    errdefer {
        if (db) |d| _ = c.sqlite3_close(d);
    }
    try checkError(rc, db);

    const createTable = "CREATE TABLE IF NOT EXISTS tasks (\n  id INTEGER PRIMARY KEY AUTOINCREMENT,\n  title TEXT NOT NULL,\n  status TEXT NOT NULL DEFAULT 'needsAction',\n  last_modified INTEGER NOT NULL DEFAULT (strftime('%s','now')),\n  is_deleted TEXT NOT NULL DEFAULT 'N',\n  completed_time INTEGER\n)";
    var errMsg: [*c]u8 = undefined;
    const rc2 = c.sqlite3_exec(db, createTable, null, null, &errMsg);
    if (rc2 != c.SQLITE_OK) {
        const msg = if (errMsg) |e| std.mem.span(e) else "unknown error";
        std.debug.print("SQLite exec error: {s}\n", .{msg});
        if (errMsg) |e| c.sqlite3_free(e);
        return SqlError.SqlError;
    }
    return db.?;
}

pub fn initMariaDb(host: []const u8, port: u16, password: ?[]const u8) !*c.MYSQL {
    const conn = c.mysql_init(null) orelse return error.OutOfMemory;
    const pw_ptr = if (password) |pw| pw.ptr else null;
    if (c.mysql_real_connect(conn, host.ptr, "root", pw_ptr, "supernotedb", port, null, 0) == null) {
        std.debug.print("MariaDB connection error: {s}\n", .{c.mysql_error(conn)});
        return error.SqlError;
    }
    return conn;
}

pub fn close(db: Db) void {
    switch (db) {
        .sqlite => |s| _ = c.sqlite3_close(s),
        .mariadb => |m| c.mysql_close(m),
    }
}

pub fn addTask(db: Db, desc: []const u8) !void {
    switch (db) {
        .sqlite => |s| {
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "INSERT INTO tasks (title, last_modified) VALUES (?, CAST(strftime('%s','now') AS INTEGER));";
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

pub fn queryTasks(db: Db, showAll: bool, allocator: std.mem.Allocator) !std.ArrayList(Task) {
    var tasks: std.ArrayList(Task) = .empty;
    switch (db) {
        .sqlite => |s| {
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = if (showAll)
                "SELECT id, title, status FROM tasks WHERE is_deleted != 'Y' ORDER BY last_modified DESC;"
            else
                "SELECT id, title, status FROM tasks WHERE is_deleted != 'Y' AND status != 'completed' ORDER BY last_modified DESC;";
            const rc = c.sqlite3_prepare_v2(s, sql, @intCast(sql.len + 1), &stmt, null);
            try checkError(rc, s);
            defer _ = c.sqlite3_finalize(stmt);

            while (true) {
                const step = c.sqlite3_step(stmt);
                if (step == c.SQLITE_ROW) {
                    const id = c.sqlite3_column_int(stmt, 0);
                    const titlePtr = c.sqlite3_column_text(stmt, 1);
                    const title = if (titlePtr) |p| std.mem.span(p) else "(no title)";
                    const statusPtr = c.sqlite3_column_text(stmt, 2);
                    const status = if (statusPtr) |p| std.mem.span(p) else "";

                    var id_buf: [20]u8 = undefined;
                    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch "?";

                    try tasks.append(allocator, .{
                        .id = try allocator.dupe(u8, id_str),
                        .title = try allocator.dupe(u8, title),
                        .status = try allocator.dupe(u8, status),
                    });
                } else if (step == c.SQLITE_DONE) {
                    break;
                } else {
                    try checkError(step, s);
                }
            }
        },
        .mariadb => |m| {
            const query = if (showAll)
                "SELECT task_id, title, status FROM supernotedb.t_schedule_task WHERE is_deleted != 'Y' ORDER BY last_modified DESC;"
            else
                "SELECT task_id, title, status FROM supernotedb.t_schedule_task WHERE is_deleted != 'Y' AND status != 'completed' ORDER BY last_modified DESC;";
            if (c.mysql_query(m, query) != 0) {
                std.debug.print("MariaDB query error: {s}\n", .{c.mysql_error(m)});
                return error.SqlError;
            }

            const result = c.mysql_store_result(m) orelse {
                std.debug.print("MariaDB store_result error: {s}\n", .{c.mysql_error(m)});
                return error.SqlError;
            };
            defer c.mysql_free_result(result);

            while (c.mysql_fetch_row(result)) |row| {
                const id = if (row[0] != null) std.mem.span(row[0]) else "unknown";
                const title = if (row[1] != null) std.mem.span(row[1]) else "(no title)";
                const status = if (row[2] != null) std.mem.span(row[2]) else "";

                try tasks.append(allocator, .{
                    .id = try allocator.dupe(u8, id),
                    .title = try allocator.dupe(u8, title),
                    .status = try allocator.dupe(u8, status),
                });
            }
        },
    }
    return tasks;
}

pub fn listTasks(io: std.Io, db: Db, showAll: bool) !void {
    _ = io;
    const allocator = std.heap.page_allocator;
    var tasks = try queryTasks(db, showAll, allocator);
    defer {
        for (tasks.items) |task| {
            allocator.free(task.id);
            allocator.free(task.title);
            allocator.free(task.status);
        }
        tasks.deinit(allocator);
    }

    for (tasks.items) |task| {
        const completed = std.mem.eql(u8, task.status, "completed");
        std.debug.print("{s}. [{s}] {s}\n", .{
            task.id,
            if (completed) "x" else " ",
            task.title,
        });
    }
}

fn validateIdStr(id_str: []const u8) !void {
    if (id_str.len == 0 or id_str.len > 255) return error.SqlError;
    for (id_str) |ch| {
        if (ch == '\'' or ch == ';' or ch == '\\' or ch == '"') {
            std.debug.print("Error: invalid character in task ID.\n", .{});
            return error.SqlError;
        }
    }
}

pub fn changeCompletionStatusNoIo(db: Db, id_str: []const u8, complete: bool) !void {
    switch (db) {
        .sqlite => |s| {
            const id = try std.fmt.parseInt(i64, id_str, 10);
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = if (complete)
                "UPDATE tasks SET status = ?, completed_time = CAST(strftime('%s','now') AS INTEGER), last_modified = CAST(strftime('%s','now') AS INTEGER) WHERE id = ?;"
            else
                "UPDATE tasks SET status = ?, completed_time = NULL, last_modified = CAST(strftime('%s','now') AS INTEGER) WHERE id = ?;";
            const rc = c.sqlite3_prepare_v2(s, sql, @intCast(sql.len + 1), &stmt, null);
            try checkError(rc, s);
            defer _ = c.sqlite3_finalize(stmt);

            const statusVal: []const u8 = if (complete) "completed" else "needsAction";
            _ = c.sqlite3_bind_text(stmt, 1, statusVal.ptr, @intCast(statusVal.len), c.SQLITE_TRANSIENT);
            _ = c.sqlite3_bind_int64(stmt, 2, id);
            const rc2 = c.sqlite3_step(stmt);
            if (rc2 != c.SQLITE_DONE) {
                try checkError(rc2, s);
            }
        },
        .mariadb => |m| {
            try validateIdStr(id_str);
            const completed_time_expr: []const u8 = if (complete) "UNIX_TIMESTAMP()" else "NULL";
            const query = try std.fmt.allocPrint(std.heap.page_allocator, "UPDATE supernotedb.t_schedule_task SET status = '{s}', completed_time = {s}, last_modified = UNIX_TIMESTAMP() WHERE task_id = '{s}';", .{
                if (complete) "completed" else "needsAction",
                completed_time_expr,
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

pub fn changeCompletionStatus(io: std.Io, db: Db, id_str: []const u8, complete: bool) !void {
    switch (db) {
        .sqlite => |s| {
            const id = try std.fmt.parseInt(i64, id_str, 10);
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "UPDATE tasks SET status = ?, completed_time = ?, last_modified = CAST(strftime('%s','now') AS INTEGER) WHERE id = ?;";
            const rc = c.sqlite3_prepare_v2(s, sql, @intCast(sql.len + 1), &stmt, null);
            try checkError(rc, s);
            defer _ = c.sqlite3_finalize(stmt);

            const statusVal: []const u8 = if (complete) "completed" else "needsAction";
            _ = c.sqlite3_bind_text(stmt, 1, statusVal.ptr, @intCast(statusVal.len), c.SQLITE_TRANSIENT);
            if (complete) {
                const ts = std.Io.Timestamp.now(io, .real);
                const seconds = @as(i64, @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s)));
                _ = c.sqlite3_bind_int64(stmt, 2, seconds);
            } else {
                _ = c.sqlite3_bind_null(stmt, 2);
            }
            _ = c.sqlite3_bind_int64(stmt, 3, id);
            const rc2 = c.sqlite3_step(stmt);
            if (rc2 != c.SQLITE_DONE) {
                try checkError(rc2, s);
            }
        },
        .mariadb => |m| {
            try validateIdStr(id_str);
            const ts = std.Io.Timestamp.now(io, .real);
            const seconds = @as(u64, @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s)));
            const completed_time_expr = if (complete)
                try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{seconds})
            else
                try std.fmt.allocPrint(std.heap.page_allocator, "NULL", .{});
            defer std.heap.page_allocator.free(completed_time_expr);

            const query = try std.fmt.allocPrint(std.heap.page_allocator, "UPDATE supernotedb.t_schedule_task SET status = '{s}', completed_time = {s} WHERE task_id = '{s}';", .{
                if (complete) "completed" else "needsAction",
                completed_time_expr,
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
