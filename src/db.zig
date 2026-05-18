const std = @import("std");
const c = @import("c");
pub const json = @import("json");

// --- Types ---

pub const SqlError = error{SqlError};

/// A task as displayed to the user (id, title, status strings).
pub const Task = json.Task;

/// A task with full sync metadata (timestamps, deletion flag). Used for bidirectional sync.
pub const SyncTask = struct {
    title: []const u8,
    status: []const u8,
    last_modified: i64,
    completed_time: ?i64,
    is_deleted: bool,
    remote_id: ?[]const u8 = null,
};

/// Outcome of an upsert operation on a single task.
pub const UpsertResult = enum { inserted, updated, skipped };

/// Backend-agnostic database handle (either local SQLite or remote MariaDB).
pub const Db = union(enum) {
    sqlite: *c.sqlite3,
    mariadb: *c.MYSQL,
};

// --- Private helpers ---

fn checkError(rc: c_int, db: ?*c.sqlite3) !void {
    if (rc != c.SQLITE_OK) {
        if (db) |d| {
            const msg = std.mem.span(c.sqlite3_errmsg(d));
            std.log.err("SQLite error: {s}", .{msg});
        } else {
            std.log.err("SQLite error: (null db handle)", .{});
        }
        return SqlError.SqlError;
    }
}

// --- Transaction control ---

/// Begins a transaction. SQLite uses BEGIN, MariaDB uses START TRANSACTION.
pub fn beginTransaction(database: Db) !void {
    switch (database) {
        .sqlite => |s| {
            var errMsg: [*c]u8 = null;
            const rc = c.sqlite3_exec(s, "BEGIN", null, null, &errMsg);
            if (rc != c.SQLITE_OK) {
                if (errMsg) |e| {
                    std.log.err("SQLite BEGIN error: {s}", .{std.mem.span(e)});
                    c.sqlite3_free(e);
                }
                return SqlError.SqlError;
            }
        },
        .mariadb => |m| {
            if (c.mysql_query(m, "START TRANSACTION") != 0) {
                std.log.err("MariaDB START TRANSACTION error: {s}", .{c.mysql_error(m)});
                return error.SqlError;
            }
        },
    }
}

/// Commits the current transaction.
pub fn commitTransaction(database: Db) !void {
    switch (database) {
        .sqlite => |s| {
            var errMsg: [*c]u8 = null;
            const rc = c.sqlite3_exec(s, "COMMIT", null, null, &errMsg);
            if (rc != c.SQLITE_OK) {
                if (errMsg) |e| {
                    std.log.err("SQLite COMMIT error: {s}", .{std.mem.span(e)});
                    c.sqlite3_free(e);
                }
                return SqlError.SqlError;
            }
        },
        .mariadb => |m| {
            if (c.mysql_query(m, "COMMIT") != 0) {
                std.log.err("MariaDB COMMIT error: {s}", .{c.mysql_error(m)});
                return error.SqlError;
            }
        },
    }
}

/// Rolls back the current transaction.
pub fn rollbackTransaction(database: Db) !void {
    switch (database) {
        .sqlite => |s| {
            var errMsg: [*c]u8 = null;
            const rc = c.sqlite3_exec(s, "ROLLBACK", null, null, &errMsg);
            if (rc != c.SQLITE_OK) {
                if (errMsg) |e| {
                    std.log.err("SQLite ROLLBACK error: {s}", .{std.mem.span(e)});
                    c.sqlite3_free(e);
                }
                return SqlError.SqlError;
            }
        },
        .mariadb => |m| {
            if (c.mysql_query(m, "ROLLBACK") != 0) {
                std.log.err("MariaDB ROLLBACK error: {s}", .{c.mysql_error(m)});
                return error.SqlError;
            }
        },
    }
}

// --- Connection management ---

/// Opens or creates a SQLite database at `dbPath`, creating the tasks table if needed.
pub fn initDb(dbPath: [:0]const u8) !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(dbPath.ptr, &db);
    errdefer {
        if (db) |d| _ = c.sqlite3_close(d);
    }
    try checkError(rc, db);

    const createTable = "CREATE TABLE IF NOT EXISTS tasks (\n  id INTEGER PRIMARY KEY AUTOINCREMENT,\n  title TEXT NOT NULL,\n  status TEXT NOT NULL DEFAULT 'needsAction',\n  last_modified INTEGER NOT NULL DEFAULT (strftime('%s','now')),\n  is_deleted TEXT NOT NULL DEFAULT 'N',\n  completed_time INTEGER\n)";
    var errMsg: [*c]u8 = null;
    const rc2 = c.sqlite3_exec(db, createTable, null, null, &errMsg);
    if (rc2 != c.SQLITE_OK) {
        const msg = if (errMsg) |e| std.mem.span(e) else "unknown error";
        std.log.err("SQLite exec error: {s}", .{msg});
        if (errMsg) |e| c.sqlite3_free(e);
        return SqlError.SqlError;
    }

    // Migration: add remote_task_id column for sync identity tracking.
    // Ignore error — it fires when the column already exists.
    _ = c.sqlite3_exec(db, "ALTER TABLE tasks ADD COLUMN remote_task_id TEXT", null, null, null);

    // Enforce at most one local row per remote identity.
    // If this fails on an existing DB with duplicate remote_task_ids, warn but continue.
    const idx_rc = c.sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_remote_task_id ON tasks(remote_task_id) WHERE remote_task_id IS NOT NULL;", null, null, null);
    if (idx_rc != c.SQLITE_OK) {
        std.log.warn("Warning: could not create unique index on remote_task_id (possible duplicates in existing data)", .{});
    }

    return db.?;
}

/// Connects to a MariaDB instance. Assumes the `supernotedb` database exists.
pub fn initMariaDb(host: []const u8, port: u16, password: ?[]const u8) !*c.MYSQL {
    const conn = c.mysql_init(null) orelse return error.OutOfMemory;
    const pw_ptr = if (password) |pw| pw.ptr else null;
    if (c.mysql_real_connect(conn, host.ptr, "root", pw_ptr, "supernotedb", port, null, 0) == null) {
        std.log.err("MariaDB connection error: {s}", .{c.mysql_error(conn)});
        return error.SqlError;
    }
    return conn;
}

/// Closes the database connection (SQLite or MariaDB).
pub fn close(db: Db) void {
    switch (db) {
        .sqlite => |s| _ = c.sqlite3_close(s),
        .mariadb => |m| c.mysql_close(m),
    }
}

/// Generates an RFC 4122 UUID v4 string (36 chars, lowercase hex with dashes)
/// using the OS CSPRNG via std.Io.
fn generateUuidV4(io: std.Io) [36]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    const hex = "0123456789abcdef";
    var uuid: [36]u8 = undefined;
    var i: usize = 0;
    for (bytes, 0..) |b, idx| {
        if (idx == 4 or idx == 6 or idx == 8 or idx == 10) {
            uuid[i] = '-';
            i += 1;
        }
        uuid[i] = hex[b >> 4];
        uuid[i + 1] = hex[b & 0x0f];
        i += 2;
    }
    return uuid;
}

// --- CRUD operations ---

/// Inserts a new task with the given description and current timestamp.
pub fn addTask(io: std.Io, database: Db, desc: []const u8) !void {
    switch (database) {
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
        .mariadb => |m| {
            const uuid = generateUuidV4(io);
            const task_id: []const u8 = &uuid;

            const ins_sql = "INSERT INTO supernotedb.t_schedule_task (task_id, title, status, last_modified, is_deleted) VALUES (?, ?, 'needsAction', UNIX_TIMESTAMP(), 'N')";
            const ins_stmt = c.mysql_stmt_init(m) orelse return error.SqlError;
            defer _ = c.mysql_stmt_close(ins_stmt);

            if (c.mysql_stmt_prepare(ins_stmt, ins_sql, ins_sql.len) != 0) {
                std.log.err("MariaDB insert prepare error: {s}", .{c.mysql_stmt_error(ins_stmt)});
                return error.SqlError;
            }

            var task_id_len: c_ulong = @intCast(uuid.len);
            var desc_len: c_ulong = @intCast(desc.len);

            var ins_binds = [2]c.MYSQL_BIND{
                .{
                    .buffer_type = c.MYSQL_TYPE_STRING,
                    .buffer = @ptrCast(@constCast(task_id.ptr)),
                    .buffer_length = @intCast(task_id.len),
                    .length = &task_id_len,
                },
                .{
                    .buffer_type = c.MYSQL_TYPE_STRING,
                    .buffer = @ptrCast(@constCast(desc.ptr)),
                    .buffer_length = @intCast(desc.len),
                    .length = &desc_len,
                },
            };

            if (c.mysql_stmt_bind_param(ins_stmt, &ins_binds) != 0) {
                std.log.err("MariaDB insert bind error: {s}", .{c.mysql_stmt_error(ins_stmt)});
                return error.SqlError;
            }

            if (c.mysql_stmt_execute(ins_stmt) != 0) {
                std.log.err("MariaDB insert execute error: {s}", .{c.mysql_stmt_error(ins_stmt)});
                return error.SqlError;
            }
        },
    }
}

/// Returns displayable tasks, optionally including completed ones.
/// Caller owns the returned list and each task's string fields.
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
                std.log.err("MariaDB query error: {s}", .{c.mysql_error(m)});
                return error.SqlError;
            }

            const result = c.mysql_store_result(m) orelse {
                std.log.err("MariaDB store_result error: {s}", .{c.mysql_error(m)});
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

/// Queries tasks and prints them as a formatted checklist to stdout.
pub fn listTasks(io: std.Io, db: Db, showAll: bool, allocator: std.mem.Allocator) !void {
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

// --- Sync operations ---

/// Fetches all non-deleted tasks with full sync metadata (timestamps, status).
/// Used by the sync module to build a complete picture of one side.
pub fn queryAllTasksForSync(database: Db, allocator: std.mem.Allocator) !std.ArrayList(SyncTask) {
    var tasks: std.ArrayList(SyncTask) = .empty;
    errdefer {
        for (tasks.items) |task| {
            allocator.free(task.title);
            allocator.free(task.status);
            if (task.remote_id) |r| allocator.free(r);
        }
        tasks.deinit(allocator);
    }
    switch (database) {
        .sqlite => |s| {
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "SELECT title, status, last_modified, completed_time, is_deleted, remote_task_id FROM tasks WHERE is_deleted != 'Y';";
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
                    const remoteIdPtr = c.sqlite3_column_text(stmt, 5);
                    const remote_id_raw: ?[]const u8 = if (remoteIdPtr) |p| std.mem.span(p) else null;

                    const title = try allocator.dupe(u8, title_raw);
                    errdefer allocator.free(title);
                    const status = try allocator.dupe(u8, status_raw);
                    errdefer allocator.free(status);
                    const remote_id: ?[]const u8 = if (remote_id_raw) |r| try allocator.dupe(u8, r) else null;
                    errdefer if (remote_id) |r| allocator.free(r);

                    try tasks.append(allocator, .{
                        .title = title,
                        .status = status,
                        .last_modified = last_modified,
                        .completed_time = completed_time,
                        .is_deleted = is_deleted,
                        .remote_id = remote_id,
                    });
                } else if (step == c.SQLITE_DONE) {
                    break;
                } else {
                    try checkError(step, s);
                }
            }
        },
        .mariadb => |m| {
            const sync_query = "SELECT title, status, last_modified, completed_time, is_deleted, task_id FROM supernotedb.t_schedule_task WHERE is_deleted != 'Y';";
            if (c.mysql_query(m, sync_query) != 0) {
                std.log.err("MariaDB query error: {s}", .{c.mysql_error(m)});
                return error.SqlError;
            }

            const result = c.mysql_store_result(m) orelse {
                std.log.err("MariaDB store_result error: {s}", .{c.mysql_error(m)});
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
                const remote_id_raw: ?[]const u8 = if (row[5] != null) std.mem.span(row[5]) else null;

                const title = try allocator.dupe(u8, title_raw);
                errdefer allocator.free(title);
                const status = try allocator.dupe(u8, status_raw);
                errdefer allocator.free(status);
                const remote_id: ?[]const u8 = if (remote_id_raw) |r| try allocator.dupe(u8, r) else null;
                errdefer if (remote_id) |r| allocator.free(r);

                try tasks.append(allocator, .{
                    .title = title,
                    .status = status,
                    .last_modified = last_modified,
                    .completed_time = completed_time,
                    .is_deleted = is_deleted,
                    .remote_id = remote_id,
                });
            }
        },
    }
    return tasks;
}

/// Inserts or updates a task matched by remote_id (preferred) or title (fallback).
/// Only writes if the incoming task has a newer `last_modified` timestamp than the existing row.
pub fn upsertTask(io: std.Io, database: Db, task: SyncTask) !UpsertResult {
    switch (database) {
        .sqlite => |s| {
            // Decide lookup strategy: prefer remote_task_id, fall back to title
            const use_remote_id = task.remote_id != null;
            const check_sql = if (use_remote_id)
                "SELECT last_modified FROM tasks WHERE remote_task_id = ? AND is_deleted != 'Y';"
            else
                "SELECT last_modified FROM tasks WHERE title = ? AND is_deleted != 'Y' AND remote_task_id IS NULL;";

            var check_stmt: ?*c.sqlite3_stmt = null;
            const rc1 = c.sqlite3_prepare_v2(s, check_sql, @intCast(check_sql.len + 1), &check_stmt, null);
            try checkError(rc1, s);
            defer _ = c.sqlite3_finalize(check_stmt);

            if (use_remote_id) {
                const rid = task.remote_id.?;
                _ = c.sqlite3_bind_text(check_stmt, 1, rid.ptr, @intCast(rid.len), c.SQLITE_TRANSIENT);
            } else {
                _ = c.sqlite3_bind_text(check_stmt, 1, task.title.ptr, @intCast(task.title.len), c.SQLITE_TRANSIENT);
            }
            const step = c.sqlite3_step(check_stmt);

            if (step == c.SQLITE_ROW) {
                const existing_lm = c.sqlite3_column_int64(check_stmt, 0);
                if (task.last_modified > existing_lm) {
                    // UPDATE: match by same key used in check
                    const upd_sql = if (use_remote_id)
                        "UPDATE tasks SET title = ?, status = ?, completed_time = ?, last_modified = ? WHERE remote_task_id = ? AND is_deleted != 'Y';"
                    else
                        "UPDATE tasks SET title = ?, status = ?, completed_time = ?, last_modified = ? WHERE title = ? AND is_deleted != 'Y' AND remote_task_id IS NULL;";

                    var upd_stmt: ?*c.sqlite3_stmt = null;
                    const rc2 = c.sqlite3_prepare_v2(s, upd_sql, @intCast(upd_sql.len + 1), &upd_stmt, null);
                    try checkError(rc2, s);
                    defer _ = c.sqlite3_finalize(upd_stmt);

                    _ = c.sqlite3_bind_text(upd_stmt, 1, task.title.ptr, @intCast(task.title.len), c.SQLITE_TRANSIENT);
                    _ = c.sqlite3_bind_text(upd_stmt, 2, task.status.ptr, @intCast(task.status.len), c.SQLITE_TRANSIENT);
                    if (task.completed_time) |ct| {
                        _ = c.sqlite3_bind_int64(upd_stmt, 3, ct);
                    } else {
                        _ = c.sqlite3_bind_null(upd_stmt, 3);
                    }
                    _ = c.sqlite3_bind_int64(upd_stmt, 4, task.last_modified);
                    if (use_remote_id) {
                        const rid = task.remote_id.?;
                        _ = c.sqlite3_bind_text(upd_stmt, 5, rid.ptr, @intCast(rid.len), c.SQLITE_TRANSIENT);
                    } else {
                        _ = c.sqlite3_bind_text(upd_stmt, 5, task.title.ptr, @intCast(task.title.len), c.SQLITE_TRANSIENT);
                    }

                    const rc3 = c.sqlite3_step(upd_stmt);
                    if (rc3 != c.SQLITE_DONE) {
                        try checkError(rc3, s);
                    }
                    return .updated;
                } else {
                    return .skipped;
                }
            } else if (step == c.SQLITE_DONE) {
                // No existing row — INSERT with remote_task_id if known
                var ins_stmt: ?*c.sqlite3_stmt = null;
                const ins_sql = "INSERT INTO tasks (title, status, last_modified, completed_time, is_deleted, remote_task_id) VALUES (?, ?, ?, ?, 'N', ?);";
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
                if (task.remote_id) |rid| {
                    _ = c.sqlite3_bind_text(ins_stmt, 5, rid.ptr, @intCast(rid.len), c.SQLITE_TRANSIENT);
                } else {
                    _ = c.sqlite3_bind_null(ins_stmt, 5);
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
            // Decide lookup strategy: prefer task_id (remote_id), fall back to title
            const use_remote_id = task.remote_id != null;
            const check_sql = if (use_remote_id)
                "SELECT last_modified FROM supernotedb.t_schedule_task WHERE task_id = ? AND is_deleted != 'Y'"
            else
                "SELECT last_modified FROM supernotedb.t_schedule_task WHERE title = ? AND is_deleted != 'Y'";

            const check_stmt = c.mysql_stmt_init(m);
            if (check_stmt == null) {
                std.log.err("MariaDB stmt_init error: {s}", .{c.mysql_error(m)});
                return error.SqlError;
            }
            defer _ = c.mysql_stmt_close(check_stmt);

            if (c.mysql_stmt_prepare(check_stmt, check_sql, check_sql.len) != 0) {
                std.log.err("MariaDB stmt_prepare error: {s}", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            // Bind the lookup key (remote_id or title)
            const lookup_key: []const u8 = if (use_remote_id) task.remote_id.? else task.title;
            var lookup_len: c_ulong = @intCast(lookup_key.len);
            var check_bind = [1]c.MYSQL_BIND{.{
                .buffer_type = c.MYSQL_TYPE_STRING,
                .buffer = @ptrCast(@constCast(lookup_key.ptr)),
                .buffer_length = @intCast(lookup_key.len),
                .length = &lookup_len,
            }};

            if (c.mysql_stmt_bind_param(check_stmt, &check_bind) != 0) {
                std.log.err("MariaDB bind_param error: {s}", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            if (c.mysql_stmt_execute(check_stmt) != 0) {
                std.log.err("MariaDB stmt_execute error: {s}", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            if (c.mysql_stmt_store_result(check_stmt) != 0) {
                std.log.err("MariaDB stmt_store_result error: {s}", .{c.mysql_stmt_error(check_stmt)});
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
                std.log.err("MariaDB bind_result error: {s}", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            const fetch_rc = c.mysql_stmt_fetch(check_stmt);
            if (fetch_rc == 0) {
                // Row exists — check if our data is newer
                if (task.last_modified > existing_lm) {
                    // UPDATE using the same key for WHERE clause
                    const upd_sql = if (use_remote_id)
                        "UPDATE supernotedb.t_schedule_task SET title = ?, status = ?, completed_time = ?, last_modified = ? WHERE task_id = ? AND is_deleted != 'Y'"
                    else
                        "UPDATE supernotedb.t_schedule_task SET title = ?, status = ?, completed_time = ?, last_modified = ? WHERE title = ? AND is_deleted != 'Y'";
                    const upd_stmt = c.mysql_stmt_init(m);
                    if (upd_stmt == null) return error.SqlError;
                    defer _ = c.mysql_stmt_close(upd_stmt);

                    if (c.mysql_stmt_prepare(upd_stmt, upd_sql, upd_sql.len) != 0) {
                        std.log.err("MariaDB update prepare error: {s}", .{c.mysql_stmt_error(upd_stmt)});
                        return error.SqlError;
                    }

                    var upd_title_len: c_ulong = @intCast(task.title.len);
                    var status_len: c_ulong = @intCast(task.status.len);
                    var ct_value: i64 = task.completed_time orelse 0;
                    var ct_is_null: c.my_bool = if (task.completed_time == null) 1 else 0;
                    var lm_value: i64 = task.last_modified;
                    const where_key: []const u8 = if (use_remote_id) task.remote_id.? else task.title;
                    var where_key_len: c_ulong = @intCast(where_key.len);

                    var upd_binds = [5]c.MYSQL_BIND{
                        // param 1: title (SET)
                        .{
                            .buffer_type = c.MYSQL_TYPE_STRING,
                            .buffer = @ptrCast(@constCast(task.title.ptr)),
                            .buffer_length = @intCast(task.title.len),
                            .length = &upd_title_len,
                        },
                        // param 2: status (SET)
                        .{
                            .buffer_type = c.MYSQL_TYPE_STRING,
                            .buffer = @ptrCast(@constCast(task.status.ptr)),
                            .buffer_length = @intCast(task.status.len),
                            .length = &status_len,
                        },
                        // param 3: completed_time (SET)
                        .{
                            .buffer_type = c.MYSQL_TYPE_LONGLONG,
                            .buffer = @ptrCast(&ct_value),
                            .buffer_length = @sizeOf(i64),
                            .is_null = &ct_is_null,
                        },
                        // param 4: last_modified (SET)
                        .{
                            .buffer_type = c.MYSQL_TYPE_LONGLONG,
                            .buffer = @ptrCast(&lm_value),
                            .buffer_length = @sizeOf(i64),
                        },
                        // param 5: WHERE key (task_id or title)
                        .{
                            .buffer_type = c.MYSQL_TYPE_STRING,
                            .buffer = @ptrCast(@constCast(where_key.ptr)),
                            .buffer_length = @intCast(where_key.len),
                            .length = &where_key_len,
                        },
                    };

                    if (c.mysql_stmt_bind_param(upd_stmt, &upd_binds) != 0) {
                        std.log.err("MariaDB update bind error: {s}", .{c.mysql_stmt_error(upd_stmt)});
                        return error.SqlError;
                    }

                    if (c.mysql_stmt_execute(upd_stmt) != 0) {
                        std.log.err("MariaDB update execute error: {s}", .{c.mysql_stmt_error(upd_stmt)});
                        return error.SqlError;
                    }
                    return .updated;
                } else {
                    return .skipped;
                }
            } else if (fetch_rc == c.MYSQL_NO_DATA) {
                // No existing row — INSERT using prepared statement
                const uuid = generateUuidV4(io);
                const task_id: []const u8 = &uuid;

                const ins_sql = "INSERT INTO supernotedb.t_schedule_task (task_id, title, status, last_modified, completed_time, is_deleted) VALUES (?, ?, ?, ?, ?, 'N')";
                const ins_stmt = c.mysql_stmt_init(m);
                if (ins_stmt == null) return error.SqlError;
                defer _ = c.mysql_stmt_close(ins_stmt);

                if (c.mysql_stmt_prepare(ins_stmt, ins_sql, ins_sql.len) != 0) {
                    std.log.err("MariaDB insert prepare error: {s}", .{c.mysql_stmt_error(ins_stmt)});
                    return error.SqlError;
                }

                var task_id_len: c_ulong = @intCast(uuid.len);
                var ins_title_len: c_ulong = @intCast(task.title.len);
                var ins_status_len: c_ulong = @intCast(task.status.len);
                var ins_lm_value: i64 = task.last_modified;
                var ins_ct_value: i64 = task.completed_time orelse 0;
                var ins_ct_is_null: c.my_bool = if (task.completed_time == null) 1 else 0;

                var ins_binds = [5]c.MYSQL_BIND{
                    // param 1: task_id
                    .{
                        .buffer_type = c.MYSQL_TYPE_STRING,
                        .buffer = @ptrCast(@constCast(task_id.ptr)),
                        .buffer_length = @intCast(task_id.len),
                        .length = &task_id_len,
                    },
                    // param 2: title
                    .{
                        .buffer_type = c.MYSQL_TYPE_STRING,
                        .buffer = @ptrCast(@constCast(task.title.ptr)),
                        .buffer_length = @intCast(task.title.len),
                        .length = &ins_title_len,
                    },
                    // param 3: status
                    .{
                        .buffer_type = c.MYSQL_TYPE_STRING,
                        .buffer = @ptrCast(@constCast(task.status.ptr)),
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
                    std.log.err("MariaDB insert bind error: {s}", .{c.mysql_stmt_error(ins_stmt)});
                    return error.SqlError;
                }

                if (c.mysql_stmt_execute(ins_stmt) != 0) {
                    std.log.err("MariaDB insert execute error: {s}", .{c.mysql_stmt_error(ins_stmt)});
                    return error.SqlError;
                }
                return .inserted;
            } else {
                std.log.err("MariaDB fetch error: {s}", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }
        },
    }
}

/// Sets the remote_task_id on a local SQLite row matched by title.
/// Used during backfill: after first sync, a local task learns its remote identity.
pub fn setRemoteTaskId(database: Db, local_title: []const u8, remote_id: []const u8) !void {
    switch (database) {
        .sqlite => |s| {
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "UPDATE tasks SET remote_task_id = ? WHERE title = ? AND is_deleted != 'Y' AND remote_task_id IS NULL;";
            const rc = c.sqlite3_prepare_v2(s, sql, @intCast(sql.len + 1), &stmt, null);
            try checkError(rc, s);
            defer _ = c.sqlite3_finalize(stmt);

            _ = c.sqlite3_bind_text(stmt, 1, remote_id.ptr, @intCast(remote_id.len), c.SQLITE_TRANSIENT);
            _ = c.sqlite3_bind_text(stmt, 2, local_title.ptr, @intCast(local_title.len), c.SQLITE_TRANSIENT);

            const rc2 = c.sqlite3_step(stmt);
            if (rc2 != c.SQLITE_DONE) {
                try checkError(rc2, s);
            }
        },
        .mariadb => {
            // No-op: MariaDB rows already have task_id as their PK.
        },
    }
}

// --- Status updates ---

fn validateIdStr(id_str: []const u8) !void {
    if (id_str.len == 0 or id_str.len > 255) return error.SqlError;
    for (id_str) |ch| {
        switch (ch) {
            '0'...'9', 'a'...'z', 'A'...'Z', '-', '_' => {},
            else => {
                std.log.err("Error: invalid character in task ID.", .{});
                return error.SqlError;
            },
        }
    }
}

/// Marks a task as completed or incomplete by ID, updating `last_modified` and `completed_time`.
pub fn changeCompletionStatus(io: std.Io, db: Db, id_str: []const u8, complete: bool) !void {
    switch (db) {
        .sqlite => |s| {
            const id = try std.fmt.parseInt(i64, id_str, 10);

            // Check existence first to distinguish "no such task" from "already in desired state"
            var check_stmt: ?*c.sqlite3_stmt = null;
            const check_sql = "SELECT 1 FROM tasks WHERE id = ?;";
            const check_rc = c.sqlite3_prepare_v2(s, check_sql, @intCast(check_sql.len + 1), &check_stmt, null);
            try checkError(check_rc, s);
            defer _ = c.sqlite3_finalize(check_stmt);
            _ = c.sqlite3_bind_int64(check_stmt, 1, id);
            const check_step = c.sqlite3_step(check_stmt);
            if (check_step == c.SQLITE_DONE) {
                // No row — task does not exist
                var stderr_buf: [256]u8 = undefined;
                var w = std.Io.File.stderr().writer(io, &stderr_buf);
                w.interface.print("Error: no task found with id '{s}'.\n", .{id_str}) catch {};
                w.interface.flush() catch {};
                return error.SqlError;
            } else if (check_step != c.SQLITE_ROW) {
                try checkError(check_step, s);
            }

            // Task exists — proceed with UPDATE (idempotent; no-op if already in desired state)
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

            // Check existence first to distinguish "no such task" from "already in desired state"
            const check_sql = "SELECT 1 FROM supernotedb.t_schedule_task WHERE task_id = ?";
            const check_stmt = c.mysql_stmt_init(m);
            if (check_stmt == null) {
                std.log.err("MariaDB stmt_init error: {s}", .{c.mysql_error(m)});
                return error.SqlError;
            }
            defer _ = c.mysql_stmt_close(check_stmt);

            if (c.mysql_stmt_prepare(check_stmt, check_sql, check_sql.len) != 0) {
                std.log.err("MariaDB check prepare error: {s}", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            var check_id_len: c_ulong = @intCast(id_str.len);
            var check_bind = [1]c.MYSQL_BIND{.{
                .buffer_type = c.MYSQL_TYPE_STRING,
                .buffer = @ptrCast(@constCast(id_str.ptr)),
                .buffer_length = @intCast(id_str.len),
                .length = &check_id_len,
            }};

            if (c.mysql_stmt_bind_param(check_stmt, &check_bind) != 0) {
                std.log.err("MariaDB check bind error: {s}", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            if (c.mysql_stmt_execute(check_stmt) != 0) {
                std.log.err("MariaDB check execute error: {s}", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            if (c.mysql_stmt_store_result(check_stmt) != 0) {
                std.log.err("MariaDB check store_result error: {s}", .{c.mysql_stmt_error(check_stmt)});
                return error.SqlError;
            }

            if (c.mysql_stmt_num_rows(check_stmt) == 0) {
                // No row — task does not exist
                var stderr_buf: [256]u8 = undefined;
                var w = std.Io.File.stderr().writer(io, &stderr_buf);
                w.interface.print("Error: no task found with id '{s}'.\n", .{id_str}) catch {};
                w.interface.flush() catch {};
                return error.SqlError;
            }

            // Task exists — proceed with UPDATE (idempotent; no-op if already in desired state)
            const sql = "UPDATE supernotedb.t_schedule_task SET status = ?, completed_time = ?, last_modified = UNIX_TIMESTAMP() WHERE task_id = ?";
            const stmt = c.mysql_stmt_init(m);
            if (stmt == null) {
                std.log.err("MariaDB stmt_init error: {s}", .{c.mysql_error(m)});
                return error.SqlError;
            }
            defer _ = c.mysql_stmt_close(stmt);

            if (c.mysql_stmt_prepare(stmt, sql, sql.len) != 0) {
                std.log.err("MariaDB stmt_prepare error: {s}", .{c.mysql_stmt_error(stmt)});
                return error.SqlError;
            }

            const statusVal: []const u8 = if (complete) "completed" else "needsAction";
            var status_len: c_ulong = @intCast(statusVal.len);

            const ts = std.Io.Timestamp.now(io, .real);
            const seconds = @as(i64, @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s)));
            var ct_value: i64 = seconds;
            var ct_is_null: c.my_bool = if (complete) 0 else 1;

            var id_len: c_ulong = @intCast(id_str.len);

            var binds = [3]c.MYSQL_BIND{
                // param 1: status
                .{
                    .buffer_type = c.MYSQL_TYPE_STRING,
                    .buffer = @ptrCast(@constCast(statusVal.ptr)),
                    .buffer_length = @intCast(statusVal.len),
                    .length = &status_len,
                },
                // param 2: completed_time
                .{
                    .buffer_type = c.MYSQL_TYPE_LONGLONG,
                    .buffer = @ptrCast(&ct_value),
                    .buffer_length = @sizeOf(i64),
                    .is_null = &ct_is_null,
                },
                // param 3: task_id
                .{
                    .buffer_type = c.MYSQL_TYPE_STRING,
                    .buffer = @ptrCast(@constCast(id_str.ptr)),
                    .buffer_length = @intCast(id_str.len),
                    .length = &id_len,
                },
            };

            if (c.mysql_stmt_bind_param(stmt, &binds) != 0) {
                std.log.err("MariaDB bind_param error: {s}", .{c.mysql_stmt_error(stmt)});
                return error.SqlError;
            }

            if (c.mysql_stmt_execute(stmt) != 0) {
                std.log.err("MariaDB execute error: {s}", .{c.mysql_stmt_error(stmt)});
                return error.SqlError;
            }
        },
    }
}
