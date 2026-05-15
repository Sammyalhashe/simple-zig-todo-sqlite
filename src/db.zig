const std = @import("std");
const c = @import("c");
pub const json = @import("json");

pub const SqlError = error{SqlError};

pub const Task = json.Task;

pub const SyncTask = struct {
    title: []const u8,
    status: []const u8,
    last_modified: i64,
    completed_time: ?i64,
    is_deleted: bool,
};

pub const UpsertResult = enum { inserted, updated, skipped };

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

    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &stdout_buf);
    for (tasks.items) |task| {
        const completed = std.mem.eql(u8, task.status, "completed");
        w.interface.print("{s}. [{s}] {s}\n", .{
            task.id,
            if (completed) "x" else " ",
            task.title,
        }) catch {};
    }
    w.interface.flush() catch {};
}

pub fn queryAllTasksForSync(database: Db, allocator: std.mem.Allocator) !std.ArrayList(SyncTask) {
    var tasks: std.ArrayList(SyncTask) = .empty;
    errdefer {
        for (tasks.items) |task| {
            allocator.free(task.title);
            allocator.free(task.status);
        }
        tasks.deinit(allocator);
    }
    switch (database) {
        .sqlite => |s| {
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "SELECT title, status, last_modified, completed_time, is_deleted FROM tasks WHERE is_deleted != 'Y';";
            const rc = c.sqlite3_prepare_v2(s, sql, @intCast(sql.len + 1), &stmt, null);
            try checkError(rc, s);
            defer _ = c.sqlite3_finalize(stmt);

            while (true) {
                const step = c.sqlite3_step(stmt);
                if (step == c.SQLITE_ROW) {
                    const titlePtr = c.sqlite3_column_text(stmt, 0);
                    const title_raw = if (titlePtr) |p| std.mem.span(p) else "(no title)";
                    const statusPtr = c.sqlite3_column_text(stmt, 1);
                    const status_raw = if (statusPtr) |p| std.mem.span(p) else "";
                    const last_modified = c.sqlite3_column_int64(stmt, 2);
                    const completed_time: ?i64 = if (c.sqlite3_column_type(stmt, 3) == c.SQLITE_NULL)
                        null
                    else
                        c.sqlite3_column_int64(stmt, 3);
                    const deletedPtr = c.sqlite3_column_text(stmt, 4);
                    const deleted_str = if (deletedPtr) |p| std.mem.span(p) else "N";
                    const is_deleted = std.mem.eql(u8, deleted_str, "Y");

                    const title = try allocator.dupe(u8, title_raw);
                    errdefer allocator.free(title);
                    const status = try allocator.dupe(u8, status_raw);
                    errdefer allocator.free(status);

                    try tasks.append(allocator, .{
                        .title = title,
                        .status = status,
                        .last_modified = last_modified,
                        .completed_time = completed_time,
                        .is_deleted = is_deleted,
                    });
                } else if (step == c.SQLITE_DONE) {
                    break;
                } else {
                    try checkError(step, s);
                }
            }
        },
        .mariadb => |m| {
            const sync_query = "SELECT title, status, last_modified, completed_time, is_deleted FROM supernotedb.t_schedule_task WHERE is_deleted != 'Y';";
            if (c.mysql_query(m, sync_query) != 0) {
                std.debug.print("MariaDB query error: {s}\n", .{c.mysql_error(m)});
                return error.SqlError;
            }

            const result = c.mysql_store_result(m) orelse {
                std.debug.print("MariaDB store_result error: {s}\n", .{c.mysql_error(m)});
                return error.SqlError;
            };
            defer c.mysql_free_result(result);

            while (c.mysql_fetch_row(result)) |row| {
                const title_raw = if (row[0] != null) std.mem.span(row[0]) else "(no title)";
                const status_raw = if (row[1] != null) std.mem.span(row[1]) else "";
                const lm_str = if (row[2] != null) std.mem.span(row[2]) else "0";
                const last_modified = std.fmt.parseInt(i64, lm_str, 10) catch 0;
                const completed_time: ?i64 = if (row[3] != null) blk: {
                    const ct_str = std.mem.span(row[3]);
                    break :blk std.fmt.parseInt(i64, ct_str, 10) catch null;
                } else null;
                const deleted_str = if (row[4] != null) std.mem.span(row[4]) else "N";
                const is_deleted = std.mem.eql(u8, deleted_str, "Y");

                const title = try allocator.dupe(u8, title_raw);
                errdefer allocator.free(title);
                const status = try allocator.dupe(u8, status_raw);
                errdefer allocator.free(status);

                try tasks.append(allocator, .{
                    .title = title,
                    .status = status,
                    .last_modified = last_modified,
                    .completed_time = completed_time,
                    .is_deleted = is_deleted,
                });
            }
        },
    }
    return tasks;
}

pub fn upsertTaskByTitle(database: Db, task: SyncTask) !UpsertResult {
    switch (database) {
        .sqlite => |s| {
            var check_stmt: ?*c.sqlite3_stmt = null;
            const check_sql = "SELECT last_modified FROM tasks WHERE title = ? AND is_deleted != 'Y';";
            const rc1 = c.sqlite3_prepare_v2(s, check_sql, @intCast(check_sql.len + 1), &check_stmt, null);
            try checkError(rc1, s);
            defer _ = c.sqlite3_finalize(check_stmt);

            _ = c.sqlite3_bind_text(check_stmt, 1, task.title.ptr, @intCast(task.title.len), c.SQLITE_TRANSIENT);
            const step = c.sqlite3_step(check_stmt);

            if (step == c.SQLITE_ROW) {
                const existing_lm = c.sqlite3_column_int64(check_stmt, 0);
                if (task.last_modified > existing_lm) {
                    var upd_stmt: ?*c.sqlite3_stmt = null;
                    const upd_sql = "UPDATE tasks SET status = ?, completed_time = ?, last_modified = ? WHERE title = ? AND is_deleted != 'Y';";
                    const rc2 = c.sqlite3_prepare_v2(s, upd_sql, @intCast(upd_sql.len + 1), &upd_stmt, null);
                    try checkError(rc2, s);
                    defer _ = c.sqlite3_finalize(upd_stmt);

                    _ = c.sqlite3_bind_text(upd_stmt, 1, task.status.ptr, @intCast(task.status.len), c.SQLITE_TRANSIENT);
                    if (task.completed_time) |ct| {
                        _ = c.sqlite3_bind_int64(upd_stmt, 2, ct);
                    } else {
                        _ = c.sqlite3_bind_null(upd_stmt, 2);
                    }
                    _ = c.sqlite3_bind_int64(upd_stmt, 3, task.last_modified);
                    _ = c.sqlite3_bind_text(upd_stmt, 4, task.title.ptr, @intCast(task.title.len), c.SQLITE_TRANSIENT);

                    const rc3 = c.sqlite3_step(upd_stmt);
                    if (rc3 != c.SQLITE_DONE) {
                        try checkError(rc3, s);
                    }
                    return .updated;
                } else {
                    return .skipped;
                }
            } else if (step == c.SQLITE_DONE) {
                var ins_stmt: ?*c.sqlite3_stmt = null;
                const ins_sql = "INSERT INTO tasks (title, status, last_modified, completed_time, is_deleted) VALUES (?, ?, ?, ?, 'N');";
                const rc2 = c.sqlite3_prepare_v2(s, ins_sql, @intCast(ins_sql.len + 1), &ins_stmt, null);
                try checkError(rc2, s);
                defer _ = c.sqlite3_finalize(ins_stmt);

                _ = c.sqlite3_bind_text(ins_stmt, 1, task.title.ptr, @intCast(task.title.len), c.SQLITE_TRANSIENT);
                _ = c.sqlite3_bind_text(ins_stmt, 2, task.status.ptr, @intCast(task.status.len), c.SQLITE_TRANSIENT);
                _ = c.sqlite3_bind_int64(ins_stmt, 3, task.last_modified);
                if (task.completed_time) |ct| {
                    _ = c.sqlite3_bind_int64(ins_stmt, 4, ct);
                } else {
                    _ = c.sqlite3_bind_null(ins_stmt, 4);
                }

                const rc3 = c.sqlite3_step(ins_stmt);
                if (rc3 != c.SQLITE_DONE) {
                    try checkError(rc3, s);
                }
                return .inserted;
            } else {
                try checkError(step, s);
                return .skipped;
            }
        },
        .mariadb => |m| {
            // SELECT: check existing last_modified using prepared statement
            const check_sql = "SELECT last_modified FROM supernotedb.t_schedule_task WHERE title = ? AND is_deleted != 'Y'";
            const check_stmt = c.mysql_stmt_init(m);
            if (check_stmt == null) {
                std.debug.print("MariaDB stmt_init error: {s}\n", .{c.mysql_error(m)});
                return error.SqlError;
            }
            defer _ = c.mysql_stmt_close(check_stmt);

            if (c.mysql_stmt_prepare(check_stmt, check_sql, check_sql.len) != 0) {
                std.debug.print("MariaDB stmt_prepare error: {s}\n", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            var title_len: c_ulong = @intCast(task.title.len);
            var check_bind = [1]c.MYSQL_BIND{.{
                .buffer_type = c.MYSQL_TYPE_STRING,
                .buffer = @constCast(@ptrCast(task.title.ptr)),
                .buffer_length = @intCast(task.title.len),
                .length = &title_len,
            }};

            if (c.mysql_stmt_bind_param(check_stmt, &check_bind) != 0) {
                std.debug.print("MariaDB bind_param error: {s}\n", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            if (c.mysql_stmt_execute(check_stmt) != 0) {
                std.debug.print("MariaDB stmt_execute error: {s}\n", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            if (c.mysql_stmt_store_result(check_stmt) != 0) {
                std.debug.print("MariaDB stmt_store_result error: {s}\n", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            // Bind result: last_modified as LONGLONG
            var existing_lm: i64 = 0;
            var result_is_null: c.my_bool = 0;
            var result_len: c_ulong = 0;
            var result_bind = [1]c.MYSQL_BIND{.{
                .buffer_type = c.MYSQL_TYPE_LONGLONG,
                .buffer = @ptrCast(&existing_lm),
                .buffer_length = @sizeOf(i64),
                .is_null = &result_is_null,
                .length = &result_len,
            }};

            if (c.mysql_stmt_bind_result(check_stmt, &result_bind) != 0) {
                std.debug.print("MariaDB bind_result error: {s}\n", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            const fetch_rc = c.mysql_stmt_fetch(check_stmt);
            if (fetch_rc == 0) {
                // Row exists — check if our data is newer
                if (task.last_modified > existing_lm) {
                    // UPDATE using prepared statement
                    const upd_sql = "UPDATE supernotedb.t_schedule_task SET status = ?, completed_time = ?, last_modified = ? WHERE title = ? AND is_deleted != 'Y'";
                    const upd_stmt = c.mysql_stmt_init(m);
                    if (upd_stmt == null) return error.SqlError;
                    defer _ = c.mysql_stmt_close(upd_stmt);

                    if (c.mysql_stmt_prepare(upd_stmt, upd_sql, upd_sql.len) != 0) {
                        std.debug.print("MariaDB update prepare error: {s}\n", .{c.mysql_stmt_error(upd_stmt)});
                        return error.SqlError;
                    }

                    var status_len: c_ulong = @intCast(task.status.len);
                    var ct_value: i64 = task.completed_time orelse 0;
                    var ct_is_null: c.my_bool = if (task.completed_time == null) 1 else 0;
                    var lm_value: i64 = task.last_modified;
                    var upd_title_len: c_ulong = @intCast(task.title.len);

                    var upd_binds = [4]c.MYSQL_BIND{
                        // param 1: status
                        .{
                            .buffer_type = c.MYSQL_TYPE_STRING,
                            .buffer = @constCast(@ptrCast(task.status.ptr)),
                            .buffer_length = @intCast(task.status.len),
                            .length = &status_len,
                        },
                        // param 2: completed_time
                        .{
                            .buffer_type = c.MYSQL_TYPE_LONGLONG,
                            .buffer = @ptrCast(&ct_value),
                            .buffer_length = @sizeOf(i64),
                            .is_null = &ct_is_null,
                        },
                        // param 3: last_modified
                        .{
                            .buffer_type = c.MYSQL_TYPE_LONGLONG,
                            .buffer = @ptrCast(&lm_value),
                            .buffer_length = @sizeOf(i64),
                        },
                        // param 4: title (WHERE clause)
                        .{
                            .buffer_type = c.MYSQL_TYPE_STRING,
                            .buffer = @constCast(@ptrCast(task.title.ptr)),
                            .buffer_length = @intCast(task.title.len),
                            .length = &upd_title_len,
                        },
                    };

                    if (c.mysql_stmt_bind_param(upd_stmt, &upd_binds) != 0) {
                        std.debug.print("MariaDB update bind error: {s}\n", .{c.mysql_stmt_error(upd_stmt)});
                        return error.SqlError;
                    }

                    if (c.mysql_stmt_execute(upd_stmt) != 0) {
                        std.debug.print("MariaDB update execute error: {s}\n", .{c.mysql_stmt_error(upd_stmt)});
                        return error.SqlError;
                    }
                    return .updated;
                } else {
                    return .skipped;
                }
            } else if (fetch_rc == c.MYSQL_NO_DATA) {
                // No existing row — INSERT using prepared statement
                var hash: u32 = 0;
                for (task.title) |ch| {
                    hash = hash *% 31 +% @as(u32, ch);
                }

                var id_buf: [64]u8 = undefined;
                const task_id = std.fmt.bufPrint(&id_buf, "sync-{x}-{x:0>8}", .{
                    @as(u64, @bitCast(task.last_modified)),
                    hash,
                }) catch return error.SqlError;

                const ins_sql = "INSERT INTO supernotedb.t_schedule_task (task_id, title, status, last_modified, completed_time, is_deleted) VALUES (?, ?, ?, ?, ?, 'N')";
                const ins_stmt = c.mysql_stmt_init(m);
                if (ins_stmt == null) return error.SqlError;
                defer _ = c.mysql_stmt_close(ins_stmt);

                if (c.mysql_stmt_prepare(ins_stmt, ins_sql, ins_sql.len) != 0) {
                    std.debug.print("MariaDB insert prepare error: {s}\n", .{c.mysql_stmt_error(ins_stmt)});
                    return error.SqlError;
                }

                var task_id_len: c_ulong = @intCast(task_id.len);
                var ins_title_len: c_ulong = @intCast(task.title.len);
                var ins_status_len: c_ulong = @intCast(task.status.len);
                var ins_lm_value: i64 = task.last_modified;
                var ins_ct_value: i64 = task.completed_time orelse 0;
                var ins_ct_is_null: c.my_bool = if (task.completed_time == null) 1 else 0;

                var ins_binds = [5]c.MYSQL_BIND{
                    // param 1: task_id
                    .{
                        .buffer_type = c.MYSQL_TYPE_STRING,
                        .buffer = @constCast(@ptrCast(task_id.ptr)),
                        .buffer_length = @intCast(task_id.len),
                        .length = &task_id_len,
                    },
                    // param 2: title
                    .{
                        .buffer_type = c.MYSQL_TYPE_STRING,
                        .buffer = @constCast(@ptrCast(task.title.ptr)),
                        .buffer_length = @intCast(task.title.len),
                        .length = &ins_title_len,
                    },
                    // param 3: status
                    .{
                        .buffer_type = c.MYSQL_TYPE_STRING,
                        .buffer = @constCast(@ptrCast(task.status.ptr)),
                        .buffer_length = @intCast(task.status.len),
                        .length = &ins_status_len,
                    },
                    // param 4: last_modified
                    .{
                        .buffer_type = c.MYSQL_TYPE_LONGLONG,
                        .buffer = @ptrCast(&ins_lm_value),
                        .buffer_length = @sizeOf(i64),
                    },
                    // param 5: completed_time
                    .{
                        .buffer_type = c.MYSQL_TYPE_LONGLONG,
                        .buffer = @ptrCast(&ins_ct_value),
                        .buffer_length = @sizeOf(i64),
                        .is_null = &ins_ct_is_null,
                    },
                };

                if (c.mysql_stmt_bind_param(ins_stmt, &ins_binds) != 0) {
                    std.debug.print("MariaDB insert bind error: {s}\n", .{c.mysql_stmt_error(ins_stmt)});
                    return error.SqlError;
                }

                if (c.mysql_stmt_execute(ins_stmt) != 0) {
                    std.debug.print("MariaDB insert execute error: {s}\n", .{c.mysql_stmt_error(ins_stmt)});
                    return error.SqlError;
                }
                return .inserted;
            } else {
                std.debug.print("MariaDB fetch error: {s}\n", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }
        },
    }
}

fn validateIdStr(id_str: []const u8) !void {
    if (id_str.len == 0 or id_str.len > 255) return error.SqlError;
    for (id_str) |ch| {
        switch (ch) {
            '0'...'9', 'a'...'z', 'A'...'Z', '-', '_' => {},
            else => {
                std.debug.print("Error: invalid character in task ID.\n", .{});
                return error.SqlError;
            },
        }
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
