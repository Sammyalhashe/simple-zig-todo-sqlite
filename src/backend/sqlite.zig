const std = @import("std");
const c = @import("c");
const builtin = @import("builtin");

const migrations = @import("migrations.zig");
const types = @import("../types.zig");
const utils = @import("../util.zig");

// Workaround: Zig 0.16 translate-C fails on darwin when casting SQLITE_TRANSIENT (-1) to a
// function pointer due to alignment checks on @ptrFromInt. Use a C helper on darwin only.
extern fn sqlite3_bind_text_transient(?*c.sqlite3_stmt, c_int, [*c]const u8, c_int) c_int;

fn bindTextTransient(stmt: ?*c.sqlite3_stmt, col: c_int, ptr: [*c]const u8, len: c_int) c_int {
    if (comptime builtin.os.tag.isDarwin()) {
        return sqlite3_bind_text_transient(stmt, col, ptr, len);
    } else {
        return c.sqlite3_bind_text(stmt, col, ptr, len, c.SQLITE_TRANSIENT);
    }
}

const Self = @This();

allocator: std.mem.Allocator,
handle: *c.sqlite3,

fn checkError(rc: c_int, db: ?*c.sqlite3) !void {
    if (rc != c.SQLITE_OK) {
        if (db) |d| {
            const msg = std.mem.span(c.sqlite3_errmsg(d));
            std.log.err("SQLite error: {s}", .{msg});
        } else {
            std.log.err("SQLite error: (null db handle)", .{});
        }
        return types.SqlError.SqlError;
    }
}

pub fn init(allocator: std.mem.Allocator, dbPath: [:0]const u8) !*Self {
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(dbPath.ptr, &db);
    errdefer {
        if (db) |d| _ = c.sqlite3_close(d);
    }
    try checkError(rc, db);

    const createTable = @embedFile("./queries/sqlite/create_table.sql");
    var errMsg: [*c]u8 = null;
    const rc2 = c.sqlite3_exec(db, createTable, null, null, &errMsg);
    if (rc2 != c.SQLITE_OK) {
        const msg = if (errMsg) |e| std.mem.span(e) else "unknown error";
        std.log.err("SQLite exec error: {s}", .{msg});
        if (errMsg) |e| c.sqlite3_free(e);
        return types.SqlError.SqlError;
    }

    migrations.run(db.?);

    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .handle = db.?,
    };
    return self;
}

pub fn close(self: *Self) void {
    _ = c.sqlite3_close(self.handle);
    self.allocator.destroy(self);
}

pub fn beginTransaction(self: *Self) !void {
    var errMsg: [*c]u8 = null;
    const rc = c.sqlite3_exec(self.handle, "BEGIN", null, null, &errMsg);
    if (rc != c.SQLITE_OK) {
        if (errMsg) |e| {
            std.log.err("SQLite BEGIN error: {s}", .{std.mem.span(e)});
            c.sqlite3_free(e);
        }
        return types.SqlError.SqlError;
    }
}

pub fn commitTransaction(self: *Self) !void {
    var errMsg: [*c]u8 = null;
    const rc = c.sqlite3_exec(self.handle, "COMMIT", null, null, &errMsg);
    if (rc != c.SQLITE_OK) {
        if (errMsg) |e| {
            std.log.err("SQLite COMMIT error: {s}", .{std.mem.span(e)});
            c.sqlite3_free(e);
        }
        return types.SqlError.SqlError;
    }
}

pub fn rollbackTransaction(self: *Self) !void {
    var errMsg: [*c]u8 = null;
    const rc = c.sqlite3_exec(self.handle, "ROLLBACK", null, null, &errMsg);
    if (rc != c.SQLITE_OK) {
        if (errMsg) |e| {
            std.log.err("SQLite ROLLBACK error: {s}", .{std.mem.span(e)});
            c.sqlite3_free(e);
        }
        return types.SqlError.SqlError;
    }
}

pub fn addTask(self: *Self, io: std.Io, desc: []const u8) !void {
    _ = io;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = @embedFile("./queries/sqlite/addTask.sql");
    const rc = c.sqlite3_prepare_v2(self.handle, sql, @intCast(sql.len + 1), &stmt, null);
    try checkError(rc, self.handle);
    defer _ = c.sqlite3_finalize(stmt);

    _ = bindTextTransient(stmt, 1, desc.ptr, @intCast(desc.len));
    const rc2 = c.sqlite3_step(stmt);
    if (rc2 != c.SQLITE_DONE) {
        try checkError(rc2, self.handle);
    }
}

pub fn queryTasks(self: *Self, showAll: bool, allocator: std.mem.Allocator) !std.ArrayList(types.Task) {
    var tasks: std.ArrayList(types.Task) = .empty;
    errdefer {
        for (tasks.items) |task| {
            allocator.free(task.id);
            allocator.free(task.title);
            allocator.free(task.status);
        }
        tasks.deinit(allocator);
    }
    const s = self.handle;

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = if (showAll)
        @embedFile("./queries/sqlite/showAllTasks.sql")
    else
        @embedFile("./queries/sqlite/showIncompleteTasks.sql");
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
    return tasks;
}

pub fn queryAllTasksForSync(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(types.SyncTask) {
    var tasks: std.ArrayList(types.SyncTask) = .empty;
    errdefer {
        for (tasks.items) |task| {
            allocator.free(task.title);
            allocator.free(task.status);
            if (task.remote_id) |r| allocator.free(r);
        }
        tasks.deinit(allocator);
    }
    const s = self.handle;

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = @embedFile("./queries/sqlite/queryAll.sql");
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
            const due_time = c.sqlite3_column_int64(stmt, 3);
            const completed_time: ?i64 = if (c.sqlite3_column_type(stmt, 4) == c.SQLITE_NULL)
                null
            else
                c.sqlite3_column_int64(stmt, 4);
            const deletedPtr = c.sqlite3_column_text(stmt, 5);
            const deleted_str = if (deletedPtr) |p| std.mem.span(p) else "N";
            const is_deleted = std.mem.eql(u8, deleted_str, "Y");
            const remoteIdPtr = c.sqlite3_column_text(stmt, 6);
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
                .due_time = due_time,
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
    return tasks;
}

pub fn upsertTask(self: *Self, io: std.Io, task: types.SyncTask, allocator: std.mem.Allocator) !types.UpsertResultWithId {
    _ = io;
    const s = self.handle;

    const use_remote_id = task.remote_id != null;
    const check_sql = if (use_remote_id)
        @embedFile("./queries/sqlite/searchIncompleteByTaskId.sql")
    else
        @embedFile("./queries/sqlite/searchIncompleteByTitle.sql");

    var check_stmt: ?*c.sqlite3_stmt = null;
    const rc1 = c.sqlite3_prepare_v2(s, check_sql, @intCast(check_sql.len + 1), &check_stmt, null);
    try checkError(rc1, s);
    defer _ = c.sqlite3_finalize(check_stmt);

    if (use_remote_id) {
        const rid = task.remote_id.?;
        _ = bindTextTransient(check_stmt, 1, rid.ptr, @intCast(rid.len));
    } else {
        _ = bindTextTransient(check_stmt, 1, task.title.ptr, @intCast(task.title.len));
    }
    const step = c.sqlite3_step(check_stmt);

    if (step == c.SQLITE_ROW) {
        const existing_lm = c.sqlite3_column_int64(check_stmt, 0);
        if (task.last_modified > existing_lm) {
            const upd_sql = if (use_remote_id)
                @embedFile("./queries/sqlite/updateByRemoteId.sql")
            else
                @embedFile("./queries/sqlite/updateByTitle.sql");

            var upd_stmt: ?*c.sqlite3_stmt = null;
            const rc2 = c.sqlite3_prepare_v2(s, upd_sql, @intCast(upd_sql.len + 1), &upd_stmt, null);
            try checkError(rc2, s);
            defer _ = c.sqlite3_finalize(upd_stmt);

            _ = bindTextTransient(upd_stmt, 1, task.title.ptr, @intCast(task.title.len));
            _ = bindTextTransient(upd_stmt, 2, task.status.ptr, @intCast(task.status.len));
            if (task.completed_time) |ct| {
                _ = c.sqlite3_bind_int64(upd_stmt, 3, ct);
            } else {
                _ = c.sqlite3_bind_null(upd_stmt, 3);
            }
            _ = c.sqlite3_bind_int64(upd_stmt, 4, task.last_modified);
            if (use_remote_id) {
                const rid = task.remote_id.?;
                _ = bindTextTransient(upd_stmt, 5, rid.ptr, @intCast(rid.len));
            } else {
                _ = bindTextTransient(upd_stmt, 5, task.title.ptr, @intCast(task.title.len));
            }

            const rc3 = c.sqlite3_step(upd_stmt);
            if (rc3 != c.SQLITE_DONE) {
                try checkError(rc3, s);
            }
            return .{
                .result = .updated,
                .task_id = try allocator.dupe(u8, "0"),
            };
        } else {
            return .{
                .result = .skipped,
                .task_id = try allocator.dupe(u8, "0"),
            };
        }
    } else if (step == c.SQLITE_DONE) {
        var ins_stmt: ?*c.sqlite3_stmt = null;
        const ins_sql = @embedFile("./queries/sqlite/addTaskInUpsert.sql");
        const rc2 = c.sqlite3_prepare_v2(s, ins_sql, @intCast(ins_sql.len + 1), &ins_stmt, null);
        try checkError(rc2, s);
        defer _ = c.sqlite3_finalize(ins_stmt);

        _ = bindTextTransient(ins_stmt, 1, task.title.ptr, @intCast(task.title.len));
        _ = bindTextTransient(ins_stmt, 2, task.status.ptr, @intCast(task.status.len));
        _ = c.sqlite3_bind_int64(ins_stmt, 3, task.last_modified);
        _ = c.sqlite3_bind_int64(ins_stmt, 4, task.due_time);
        if (task.completed_time) |ct| {
            _ = c.sqlite3_bind_int64(ins_stmt, 5, ct);
        } else {
            _ = c.sqlite3_bind_null(ins_stmt, 5);
        }
        if (task.remote_id) |rid| {
            _ = bindTextTransient(ins_stmt, 6, rid.ptr, @intCast(rid.len));
        } else {
            _ = c.sqlite3_bind_null(ins_stmt, 6);
        }

        const rc3 = c.sqlite3_step(ins_stmt);
        if (rc3 != c.SQLITE_DONE) {
            try checkError(rc3, s);
        }
        return .{
            .result = .inserted,
            .task_id = try allocator.dupe(u8, "0"),
        };
    } else {
        try checkError(step, s);
        return .{
            .result = .skipped,
            .task_id = try allocator.dupe(u8, "0"),
        };
    }
}

pub fn setRemoteTaskId(self: *Self, local_title: []const u8, remote_id: []const u8) !void {
    const s = self.handle;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = @embedFile("./queries/sqlite/setRemoteTaskId.sql");
    const rc = c.sqlite3_prepare_v2(s, sql, @intCast(sql.len + 1), &stmt, null);
    try checkError(rc, s);
    defer _ = c.sqlite3_finalize(stmt);

    _ = bindTextTransient(stmt, 1, remote_id.ptr, @intCast(remote_id.len));
    _ = bindTextTransient(stmt, 2, local_title.ptr, @intCast(local_title.len));

    const rc2 = c.sqlite3_step(stmt);
    if (rc2 != c.SQLITE_DONE) {
        try checkError(rc2, s);
    }
}

pub fn changeCompletionStatus(self: *Self, io: std.Io, id_str: []const u8, complete: bool) !void {
    const s = self.handle;
    const id = try std.fmt.parseInt(i64, id_str, 10);

    // Check existence first
    var check_stmt: ?*c.sqlite3_stmt = null;
    const check_sql = @embedFile("./queries/sqlite/searchForTaskId.sql");
    const check_rc = c.sqlite3_prepare_v2(s, check_sql, @intCast(check_sql.len + 1), &check_stmt, null);
    try checkError(check_rc, s);
    defer _ = c.sqlite3_finalize(check_stmt);
    _ = c.sqlite3_bind_int64(check_stmt, 1, id);
    const check_step = c.sqlite3_step(check_stmt);
    if (check_step == c.SQLITE_DONE) {
        std.log.err("no task found with id '{s}'", .{id_str});
        return error.TaskNotFound;
    } else if (check_step != c.SQLITE_ROW) {
        try checkError(check_step, s);
    }

    // Task exists — proceed with UPDATE
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = @embedFile("./queries/sqlite/changeCompletionStatus.sql");
    const rc = c.sqlite3_prepare_v2(s, sql, @intCast(sql.len + 1), &stmt, null);
    try checkError(rc, s);
    defer _ = c.sqlite3_finalize(stmt);

    const statusVal: []const u8 = if (complete) "completed" else "needsAction";
    _ = bindTextTransient(stmt, 1, statusVal.ptr, @intCast(statusVal.len));
    if (complete) {
        const ts = std.Io.Timestamp.now(io, .real);
        const millis = @as(i64, @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms)));
        _ = c.sqlite3_bind_int64(stmt, 2, millis);
    } else {
        _ = c.sqlite3_bind_null(stmt, 2);
    }
    _ = c.sqlite3_bind_int64(stmt, 3, id);
    const rc2 = c.sqlite3_step(stmt);
    if (rc2 != c.SQLITE_DONE) {
        try checkError(rc2, s);
    }
}

pub fn deleteTask(self: *Self, io: std.Io, id_str: []const u8) !void {
    _ = io;
    const s = self.handle;
    const id = try std.fmt.parseInt(i64, id_str, 10);

    // Check existence first
    var check_stmt: ?*c.sqlite3_stmt = null;
    const check_sql = @embedFile("./queries/sqlite/searchForTaskId.sql");
    const check_rc = c.sqlite3_prepare_v2(s, check_sql, @intCast(check_sql.len + 1), &check_stmt, null);
    try checkError(check_rc, s);
    defer _ = c.sqlite3_finalize(check_stmt);
    _ = c.sqlite3_bind_int64(check_stmt, 1, id);
    const check_step = c.sqlite3_step(check_stmt);
    if (check_step == c.SQLITE_DONE) {
        std.log.err("no task found with id '{s}'", .{id_str});
        return error.TaskNotFound;
    } else if (check_step != c.SQLITE_ROW) {
        try checkError(check_step, s);
    }

    // Soft delete
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = @embedFile("./queries/sqlite/softDelete.sql");
    const rc = c.sqlite3_prepare_v2(s, sql, @intCast(sql.len + 1), &stmt, null);
    try checkError(rc, s);
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, id);
    const rc2 = c.sqlite3_step(stmt);
    if (rc2 != c.SQLITE_DONE) {
        try checkError(rc2, s);
    }
}
