const std = @import("std");
const c = @import("c");
const types = @import("../types.zig");
const util = @import("../util.zig");

const Self = @This();

allocator: std.mem.Allocator,
handle: *c.MYSQL,
user_id: ?u64,

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

fn getDefaultUser(self: *Self) !void {
    const m = self.handle;

    const select_user_sql = "SELECT user_id from u_user LIMIT 1";

    if (c.mysql_query(m, select_user_sql) != 0) {
        std.log.err("MariaDB query error: {s}", .{c.mysql_error(m)});
        return error.SqlError;
    }

    const result = c.mysql_store_result(m) orelse {
        std.log.err("MariaDB store_result error: {s}", .{c.mysql_error(m)});
        return error.SqlError;
    };
    defer c.mysql_free_result(result);

    while (c.mysql_fetch_row(result)) |row| {
        self.user_id = if (row[0] != null) try std.fmt.parseInt(u64, std.mem.span(row[0]), 10) else null;
    }

    if (self.user_id == null) {
        std.log.err("Could not infer default user, please provide", .{});
        return error.SqlError;
    }
}

pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, password: ?[]const u8) !*Self {
    const conn = c.mysql_init(null) orelse return error.OutOfMemory;
    const pw_ptr = if (password) |pw| pw.ptr else null;
    if (c.mysql_real_connect(conn, host.ptr, "root", pw_ptr, "supernotedb", port, null, 0) == null) {
        std.log.err("MariaDB connection error: {s}", .{c.mysql_error(conn)});
        return error.SqlError;
    }

    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .handle = conn,
        .user_id = null,
    };

    try self.getDefaultUser();

    return self;
}

pub fn close(self: *Self) void {
    c.mysql_close(self.handle);
    self.allocator.destroy(self);
}

pub fn beginTransaction(self: *Self) !void {
    if (c.mysql_query(self.handle, "START TRANSACTION") != 0) {
        std.log.err("MariaDB START TRANSACTION error: {s}", .{c.mysql_error(self.handle)});
        return error.SqlError;
    }
}

pub fn commitTransaction(self: *Self) !void {
    if (c.mysql_query(self.handle, "COMMIT") != 0) {
        std.log.err("MariaDB COMMIT error: {s}", .{c.mysql_error(self.handle)});
        return error.SqlError;
    }
}

pub fn rollbackTransaction(self: *Self) !void {
    if (c.mysql_query(self.handle, "ROLLBACK") != 0) {
        std.log.err("MariaDB ROLLBACK error: {s}", .{c.mysql_error(self.handle)});
        return error.SqlError;
    }
}

pub fn addTask(self: *Self, io: std.Io, desc: []const u8) !void {
    const m = self.handle;
    const uuid = util.generateUuidV4(io);
    const task_id: []const u8 = &uuid;

    const ins_sql = "INSERT INTO supernotedb.t_schedule_task (user_id, task_id, title, detail, importance, recurrence, links, status, last_modified, due_time, is_deleted) VALUES (?, ?, ?, NULL, NULL, NULL, NULL, 'needsAction', ROUND(UNIX_TIMESTAMP(NOW(3)) * 1000), 0, 'N')";
    const ins_stmt = c.mysql_stmt_init(m) orelse return error.SqlError;
    defer _ = c.mysql_stmt_close(ins_stmt);

    if (c.mysql_stmt_prepare(ins_stmt, ins_sql, ins_sql.len) != 0) {
        std.log.err("MariaDB insert prepare error: {s}", .{c.mysql_stmt_error(ins_stmt)});
        return error.SqlError;
    }

    var task_id_len: c_ulong = @intCast(uuid.len);
    var desc_len: c_ulong = @intCast(desc.len);

    var result_is_null: c.my_bool = 0;
    var result_len: c_ulong = 0;

    var ins_binds = [3]c.MYSQL_BIND{
        .{
            .buffer_type = c.MYSQL_TYPE_LONGLONG,
            .buffer = @ptrCast(&self.user_id),
            .buffer_length = @sizeOf(f64),
            .is_null = &result_is_null,
            .length = &result_len,
        },
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
    const m = self.handle;

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
    const m = self.handle;

    const sync_query = "SELECT title, status, last_modified, due_time, completed_time, is_deleted, task_id FROM supernotedb.t_schedule_task WHERE is_deleted != 'Y';";
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
        const due_time_str = if (row[3] != null) std.mem.span(row[3]) else "0";
        const due_time = std.fmt.parseInt(i64, due_time_str, 10) catch 0;
        const completed_time: ?i64 = if (row[4] != null) blk: {
            const ct_str = std.mem.span(row[4]);
            break :blk std.fmt.parseInt(i64, ct_str, 10) catch null;
        } else null;
        const deleted_str = if (row[5] != null) std.mem.span(row[5]) else "N";
        const is_deleted = std.mem.eql(u8, deleted_str, "Y");
        const remote_id_raw: ?[]const u8 = if (row[6] != null) std.mem.span(row[6]) else null;

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
    }
    return tasks;
}

pub fn upsertTask(self: *Self, io: std.Io, task: types.SyncTask, allocator: std.mem.Allocator) !types.UpsertResultWithId {
    const m = self.handle;

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
        if (task.last_modified > existing_lm) {
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
                .{
                    .buffer_type = c.MYSQL_TYPE_STRING,
                    .buffer = @ptrCast(@constCast(task.title.ptr)),
                    .buffer_length = @intCast(task.title.len),
                    .length = &upd_title_len,
                },
                .{
                    .buffer_type = c.MYSQL_TYPE_STRING,
                    .buffer = @ptrCast(@constCast(task.status.ptr)),
                    .buffer_length = @intCast(task.status.len),
                    .length = &status_len,
                },
                .{
                    .buffer_type = c.MYSQL_TYPE_LONGLONG,
                    .buffer = @ptrCast(&ct_value),
                    .buffer_length = @sizeOf(i64),
                    .is_null = &ct_is_null,
                },
                .{
                    .buffer_type = c.MYSQL_TYPE_LONGLONG,
                    .buffer = @ptrCast(&lm_value),
                    .buffer_length = @sizeOf(i64),
                },
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
            return .{
                .result = .updated,
                .task_id = if (use_remote_id) try allocator.dupe(u8, task.remote_id.?) else try allocator.dupe(u8, task.title),
            };
        } else {
            return .{
                .result = .skipped,
                .task_id = if (use_remote_id) try allocator.dupe(u8, task.remote_id.?) else try allocator.dupe(u8, task.title),
            };
        }
    } else if (fetch_rc == c.MYSQL_NO_DATA) {
        const uuid = util.generateUuidV4(io);
        const task_id: []const u8 = &uuid;

        const ins_sql = "INSERT INTO supernotedb.t_schedule_task (user_id, task_id, title, detail, importance, recurrence, links, status, last_modified, due_time, completed_time, is_deleted) VALUES (?, ?, ?, NULL, NULL, NULL, NULL, ?, ?, ?, ?, 'N')";
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
        var ins_due_value: i64 = task.due_time;
        var ins_ct_value: i64 = task.completed_time orelse 0;
        var ins_ct_is_null: c.my_bool = if (task.completed_time == null) 1 else 0;

        var ins_binds = [7]c.MYSQL_BIND{
            .{
                .buffer_type = c.MYSQL_TYPE_LONGLONG,
                .buffer = @ptrCast(&self.user_id),
                .buffer_length = @sizeOf(f64),
                .is_null = &result_is_null,
                .length = &result_len,
            },
            .{
                .buffer_type = c.MYSQL_TYPE_STRING,
                .buffer = @ptrCast(@constCast(task_id.ptr)),
                .buffer_length = @intCast(task_id.len),
                .length = &task_id_len,
            },
            .{
                .buffer_type = c.MYSQL_TYPE_STRING,
                .buffer = @ptrCast(@constCast(task.title.ptr)),
                .buffer_length = @intCast(task.title.len),
                .length = &ins_title_len,
            },
            .{
                .buffer_type = c.MYSQL_TYPE_STRING,
                .buffer = @ptrCast(@constCast(task.status.ptr)),
                .buffer_length = @intCast(task.status.len),
                .length = &ins_status_len,
            },
            .{
                .buffer_type = c.MYSQL_TYPE_LONGLONG,
                .buffer = @ptrCast(&ins_lm_value),
                .buffer_length = @sizeOf(i64),
            },
            .{
                .buffer_type = c.MYSQL_TYPE_LONGLONG,
                .buffer = @ptrCast(&ins_due_value),
                .buffer_length = @sizeOf(i64),
            },
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
        return .{
            .result = .inserted,
            .task_id = try allocator.dupe(u8, task_id),
        };
    } else {
        std.log.err("MariaDB fetch error: {s}", .{c.mysql_stmt_error(check_stmt)});
        return error.SqlError;
    }
}

pub fn setRemoteTaskId(self: *Self, local_title: []const u8, remote_id: []const u8) !void {
    // No-op: MariaDB rows already have task_id as their PK.
    _ = self;
    _ = local_title;
    _ = remote_id;
}

pub fn changeCompletionStatus(self: *Self, io: std.Io, id_str: []const u8, complete: bool) !void {
    const m = self.handle;
    try validateIdStr(id_str);

    // Check existence first
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
        std.log.err("no task found with id '{s}'", .{id_str});
        return error.TaskNotFound;
    }

    // Task exists — proceed with UPDATE
    const sql = "UPDATE supernotedb.t_schedule_task SET status = ?, completed_time = ?, last_modified = ROUND(UNIX_TIMESTAMP(NOW(3)) * 1000) WHERE task_id = ?";
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
    const millis = @as(i64, @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms)));
    var ct_value: i64 = millis;
    var ct_is_null: c.my_bool = if (complete) 0 else 1;

    var id_len: c_ulong = @intCast(id_str.len);

    var binds = [3]c.MYSQL_BIND{
        .{
            .buffer_type = c.MYSQL_TYPE_STRING,
            .buffer = @ptrCast(@constCast(statusVal.ptr)),
            .buffer_length = @intCast(statusVal.len),
            .length = &status_len,
        },
        .{
            .buffer_type = c.MYSQL_TYPE_LONGLONG,
            .buffer = @ptrCast(&ct_value),
            .buffer_length = @sizeOf(i64),
            .is_null = &ct_is_null,
        },
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
}

pub fn deleteTask(self: *Self, io: std.Io, id_str: []const u8) !void {
    _ = io;
    const m = self.handle;
    try validateIdStr(id_str);

    // Check existence first
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
        std.log.err("no task found with id '{s}'", .{id_str});
        return error.TaskNotFound;
    }

    // Soft delete
    const sql = "UPDATE supernotedb.t_schedule_task SET is_deleted = 'Y', last_modified = ROUND(UNIX_TIMESTAMP(NOW(3)) * 1000) WHERE task_id = ?";
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

    var id_len: c_ulong = @intCast(id_str.len);
    var binds = [1]c.MYSQL_BIND{.{
        .buffer_type = c.MYSQL_TYPE_STRING,
        .buffer = @ptrCast(@constCast(id_str.ptr)),
        .buffer_length = @intCast(id_str.len),
        .length = &id_len,
    }};

    if (c.mysql_stmt_bind_param(stmt, &binds) != 0) {
        std.log.err("MariaDB bind_param error: {s}", .{c.mysql_stmt_error(stmt)});
        return error.SqlError;
    }

    if (c.mysql_stmt_execute(stmt) != 0) {
        std.log.err("MariaDB execute error: {s}", .{c.mysql_stmt_error(stmt)});
        return error.SqlError;
    }
}
