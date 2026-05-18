const std = @import("std");
const db = @import("db");
const c = @import("c");
const sync = @import("sync");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Connects to the ephemeral MariaDB instance started by test/test-mariadb.sh.
/// Returns null when the env vars are absent (i.e. not running under the test
/// harness), so the caller can print "skipped" and exit 0.
fn getTestMariaDb() ?*c.MYSQL {
    const host_ptr = std.c.getenv("TEST_MARIADB_HOST") orelse return null;
    const host: [:0]const u8 = std.mem.span(host_ptr);
    const port_ptr = std.c.getenv("TEST_MARIADB_PORT") orelse return null;
    const port_str: [:0]const u8 = std.mem.span(port_ptr);
    const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
    return db.initMariaDb(host, port, null) catch null;
}

/// Deletes all test rows (task_id starting with "test-") to isolate tests.
fn cleanupTestRows(conn: *c.MYSQL) void {
    _ = c.mysql_query(conn, "DELETE FROM supernotedb.t_schedule_task WHERE task_id LIKE 'test-%'");
}

/// Inserts a task with a known test-prefixed task_id directly via SQL, bypassing
/// UUID generation. This allows tests to control the task_id for verification.
fn insertTestTask(conn: *c.MYSQL, task_id: []const u8, title: []const u8, status: []const u8, last_modified: i64) !void {
    const sql = "INSERT INTO supernotedb.t_schedule_task (task_id, title, status, last_modified, is_deleted, user_id, due_time) VALUES (?, ?, ?, ?, 'N', 0, 0)";
    const stmt = c.mysql_stmt_init(conn) orelse return error.SqlError;
    defer _ = c.mysql_stmt_close(stmt);

    if (c.mysql_stmt_prepare(stmt, sql, sql.len) != 0) {
        std.debug.print("prepare error: {s}\n", .{c.mysql_stmt_error(stmt)});
        return error.SqlError;
    }

    var task_id_len: c_ulong = @intCast(task_id.len);
    var title_len: c_ulong = @intCast(title.len);
    var status_len: c_ulong = @intCast(status.len);
    var lm_value: i64 = last_modified;

    var binds = [4]c.MYSQL_BIND{
        .{
            .buffer_type = c.MYSQL_TYPE_STRING,
            .buffer = @ptrCast(@constCast(task_id.ptr)),
            .buffer_length = @intCast(task_id.len),
            .length = &task_id_len,
        },
        .{
            .buffer_type = c.MYSQL_TYPE_STRING,
            .buffer = @ptrCast(@constCast(title.ptr)),
            .buffer_length = @intCast(title.len),
            .length = &title_len,
        },
        .{
            .buffer_type = c.MYSQL_TYPE_STRING,
            .buffer = @ptrCast(@constCast(status.ptr)),
            .buffer_length = @intCast(status.len),
            .length = &status_len,
        },
        .{
            .buffer_type = c.MYSQL_TYPE_LONGLONG,
            .buffer = @ptrCast(&lm_value),
            .buffer_length = @sizeOf(i64),
        },
    };

    if (c.mysql_stmt_bind_param(stmt, &binds) != 0) {
        std.debug.print("bind error: {s}\n", .{c.mysql_stmt_error(stmt)});
        return error.SqlError;
    }
    if (c.mysql_stmt_execute(stmt) != 0) {
        std.debug.print("execute error: {s}\n", .{c.mysql_stmt_error(stmt)});
        return error.SqlError;
    }
}

/// Frees a list of tasks obtained from db.queryTasks.
fn freeTasks(tasks: *std.ArrayList(db.Task), allocator: std.mem.Allocator) void {
    for (tasks.items) |task| {
        allocator.free(task.id);
        allocator.free(task.title);
        allocator.free(task.status);
    }
    tasks.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Test functions
// ---------------------------------------------------------------------------

fn testAddTask(io: std.Io, conn: *c.MYSQL, allocator: std.mem.Allocator) !void {
    cleanupTestRows(conn);
    defer cleanupTestRows(conn);

    const title = "test-addTask-integration";
    try db.addTask(io, .{ .mariadb = conn }, title);

    // Verify: query back by title
    var tasks = try db.queryTasks(.{ .mariadb = conn }, true, allocator);
    defer freeTasks(&tasks, allocator);

    var found = false;
    for (tasks.items) |task| {
        if (std.mem.eql(u8, task.title, title)) {
            found = true;
            if (!std.mem.eql(u8, task.status, "needsAction")) {
                return error.TestExpectedEqual;
            }
            break;
        }
    }
    if (!found) return error.TestExpectedEqual;
}

fn testQueryTasks(io: std.Io, conn: *c.MYSQL, allocator: std.mem.Allocator) !void {
    cleanupTestRows(conn);
    defer cleanupTestRows(conn);

    try db.addTask(io, .{ .mariadb = conn }, "test-query-1");
    try db.addTask(io, .{ .mariadb = conn }, "test-query-2");

    var tasks = try db.queryTasks(.{ .mariadb = conn }, true, allocator);
    defer freeTasks(&tasks, allocator);

    // Count our test tasks
    var count: usize = 0;
    for (tasks.items) |task| {
        if (std.mem.startsWith(u8, task.title, "test-query-")) count += 1;
    }
    if (count != 2) return error.TestExpectedEqual;
}

fn testChangeCompletionStatus(io: std.Io, conn: *c.MYSQL, allocator: std.mem.Allocator) !void {
    cleanupTestRows(conn);
    defer cleanupTestRows(conn);

    // Insert a task with known task_id
    try insertTestTask(conn, "test-complete-001", "test-complete-task", "needsAction", 1000);

    // Mark it complete
    try db.changeCompletionStatus(io, .{ .mariadb = conn }, "test-complete-001", true);

    // Verify status changed
    var tasks = try db.queryTasks(.{ .mariadb = conn }, true, allocator);
    defer freeTasks(&tasks, allocator);

    for (tasks.items) |task| {
        if (std.mem.eql(u8, task.id, "test-complete-001")) {
            if (!std.mem.eql(u8, task.status, "completed")) {
                return error.TestExpectedEqual;
            }
            return;
        }
    }
    // Task should be found (showAll=true includes completed)
    return error.TestUnexpectedResult;
}

fn testUpsertInsert(io: std.Io, conn: *c.MYSQL) !void {
    cleanupTestRows(conn);
    defer cleanupTestRows(conn);

    const task = db.SyncTask{
        .title = "test-upsert-new",
        .status = "needsAction",
        .last_modified = 5000,
        .completed_time = null,
        .is_deleted = false,
        .remote_id = null,
    };

    const result = try db.upsertTask(io, .{ .mariadb = conn }, task);
    if (result != .inserted) return error.TestExpectedEqual;
}

fn testUpsertUpdate(io: std.Io, conn: *c.MYSQL) !void {
    cleanupTestRows(conn);
    defer cleanupTestRows(conn);

    // Insert a task with last_modified=1000
    try insertTestTask(conn, "test-upsert-upd", "test-upsert-update", "needsAction", 1000);

    // Upsert with higher last_modified, matching by remote_id (task_id)
    const task = db.SyncTask{
        .title = "test-upsert-update",
        .status = "completed",
        .last_modified = 2000,
        .completed_time = 2000,
        .is_deleted = false,
        .remote_id = "test-upsert-upd",
    };

    const result = try db.upsertTask(io, .{ .mariadb = conn }, task);
    if (result != .updated) return error.TestExpectedEqual;
}

fn testUpsertSkip(io: std.Io, conn: *c.MYSQL) !void {
    cleanupTestRows(conn);
    defer cleanupTestRows(conn);

    // Insert a task with last_modified=2000
    try insertTestTask(conn, "test-upsert-skip", "test-upsert-skip-title", "needsAction", 2000);

    // Upsert with lower last_modified
    const task = db.SyncTask{
        .title = "test-upsert-skip-title",
        .status = "completed",
        .last_modified = 1000,
        .completed_time = 1000,
        .is_deleted = false,
        .remote_id = "test-upsert-skip",
    };

    const result = try db.upsertTask(io, .{ .mariadb = conn }, task);
    if (result != .skipped) return error.TestExpectedEqual;
}

fn testTransactionCommit(io: std.Io, conn: *c.MYSQL, allocator: std.mem.Allocator) !void {
    cleanupTestRows(conn);
    defer cleanupTestRows(conn);

    const database: db.Db = .{ .mariadb = conn };

    try db.beginTransaction(database);
    try db.addTask(io, database, "test-txn-commit");
    try db.commitTransaction(database);

    // Verify task persists after commit
    var tasks = try db.queryTasks(database, true, allocator);
    defer freeTasks(&tasks, allocator);

    var found = false;
    for (tasks.items) |task| {
        if (std.mem.eql(u8, task.title, "test-txn-commit")) {
            found = true;
            break;
        }
    }
    if (!found) return error.TestExpectedEqual;
}

fn testTransactionRollback(io: std.Io, conn: *c.MYSQL, allocator: std.mem.Allocator) !void {
    cleanupTestRows(conn);
    defer cleanupTestRows(conn);

    const database: db.Db = .{ .mariadb = conn };

    try db.beginTransaction(database);
    try db.addTask(io, database, "test-txn-rollback");
    try db.rollbackTransaction(database);

    // Verify task is absent after rollback
    var tasks = try db.queryTasks(database, true, allocator);
    defer freeTasks(&tasks, allocator);

    for (tasks.items) |task| {
        if (std.mem.eql(u8, task.title, "test-txn-rollback")) {
            // Should NOT be found
            return error.TestUnexpectedResult;
        }
    }
}

fn testSyncEndToEnd(io: std.Io, conn: *c.MYSQL, allocator: std.mem.Allocator) !void {
    cleanupTestRows(conn);
    defer cleanupTestRows(conn);

    // Set up local SQLite in-memory database
    const sqlite = try db.initDb(":memory:");
    defer db.close(.{ .sqlite = sqlite });

    const local_db: db.Db = .{ .sqlite = sqlite };
    const remote_db: db.Db = .{ .mariadb = conn };

    // Add a task to local only
    try db.addTask(io, local_db, "test-sync-local-only");

    // Add a task to remote only
    try insertTestTask(conn, "test-sync-remote-001", "test-sync-remote-only", "needsAction", 3000);

    // Sync both directions
    const report = try sync.syncTasks(io, local_db, remote_db, .both, false, allocator);

    // Verify: local-only task was pushed to remote (created_remote >= 1)
    if (report.created_remote < 1) return error.TestExpectedEqual;
    // Verify: remote-only task was pulled to local (created_local >= 1)
    if (report.created_local < 1) return error.TestExpectedEqual;

    // Double-check: query local for the remote task
    var local_tasks = try db.queryTasks(local_db, true, allocator);
    defer freeTasks(&local_tasks, allocator);

    var found_remote_in_local = false;
    for (local_tasks.items) |task| {
        if (std.mem.eql(u8, task.title, "test-sync-remote-only")) {
            found_remote_in_local = true;
            break;
        }
    }
    if (!found_remote_in_local) return error.TestExpectedEqual;

    // Double-check: query remote for the local task
    var remote_tasks = try db.queryTasks(remote_db, true, allocator);
    defer freeTasks(&remote_tasks, allocator);

    var found_local_in_remote = false;
    for (remote_tasks.items) |task| {
        if (std.mem.eql(u8, task.title, "test-sync-local-only")) {
            found_local_in_remote = true;
            break;
        }
    }
    if (!found_local_in_remote) return error.TestExpectedEqual;
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

const TestEntry = struct {
    name: []const u8,
    func: *const fn (std.Io, *c.MYSQL, std.mem.Allocator) anyerror!void,
};

/// Wraps a test function that doesn't need the allocator parameter.
fn wrapNoAlloc(comptime f: fn (std.Io, *c.MYSQL) anyerror!void) *const fn (std.Io, *c.MYSQL, std.mem.Allocator) anyerror!void {
    const S = struct {
        fn wrapper(io: std.Io, conn: *c.MYSQL, _: std.mem.Allocator) anyerror!void {
            return f(io, conn);
        }
    };
    return &S.wrapper;
}

const tests = [_]TestEntry{
    .{ .name = "mariadb: addTask inserts a row", .func = testAddTask },
    .{ .name = "mariadb: queryTasks returns tasks", .func = testQueryTasks },
    .{ .name = "mariadb: changeCompletionStatus", .func = testChangeCompletionStatus },
    .{ .name = "mariadb: upsertTask inserts new", .func = wrapNoAlloc(testUpsertInsert) },
    .{ .name = "mariadb: upsertTask updates newer", .func = wrapNoAlloc(testUpsertUpdate) },
    .{ .name = "mariadb: upsertTask skips older", .func = wrapNoAlloc(testUpsertSkip) },
    .{ .name = "mariadb: transaction commit", .func = testTransactionCommit },
    .{ .name = "mariadb: transaction rollback", .func = testTransactionRollback },
    .{ .name = "mariadb: syncTasks end-to-end", .func = testSyncEndToEnd },
};

fn stdoutWrite(io: std.Io, data: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, data) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    const conn = getTestMariaDb() orelse {
        stdoutWrite(io, "MariaDB not available, skipping integration tests\n");
        return;
    };
    defer db.close(.{ .mariadb = conn });

    var passed: usize = 0;
    var failed: usize = 0;

    for (tests) |t| {
        t.func(io, conn, allocator) catch |err| {
            failed += 1;
            stdoutWrite(io, "FAIL: ");
            stdoutWrite(io, t.name);
            stdoutWrite(io, " (");
            stdoutWrite(io, @errorName(err));
            stdoutWrite(io, ")\n");
            continue;
        };
        passed += 1;
        stdoutWrite(io, "PASS: ");
        stdoutWrite(io, t.name);
        stdoutWrite(io, "\n");
    }

    stdoutWrite(io, "\n");
    if (failed > 0) {
        stdoutWrite(io, "FAILED\n");
        return error.TestsFailed;
    }
    stdoutWrite(io, "ALL PASSED\n");
}
