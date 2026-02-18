const std = @import("std");

// Import the SQLite C API
const c = @cImport({
    @cInclude("sqlite3.h");
});

const SqlError = error{ SqlError };

fn checkError(rc: c_int, db: ?*c.sqlite3) !void {
    if (rc != c.SQLITE_OK) {
        const msg = if (db) std.mem.span(c.sqlite3_errmsg(db)) else "unknown error";
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
    var errMsg: ?[*c]u8 = null;
    // sqlite3_exec expects a null-terminated string. Our Zig string literal is null-terminated.
    const rc2 = c.sqlite3_exec(db, createTable, null, null, &errMsg);
    if (rc2 != c.SQLITE_OK) {
        const msg = if (errMsg) std.mem.span(errMsg) else "unknown error";
        std.debug.print("SQLite exec error: {s}\n", .{msg});
        if (errMsg) c.sqlite3_free(errMsg);
        return SqlError.SqlError;
    }
    return db.?;
}

// Insert a new task
fn addTask(db: *c.sqlite3, desc: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO tasks (description) VALUES (?);";
    const rc = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len + 1), &stmt, null);
    try checkError(rc, db);
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_text(stmt, 1, desc.ptr, @intCast(desc.len), c.SQLITE_TRANSIENT);
    const rc2 = c.sqlite3_step(stmt);
    if (rc2 != c.SQLITE_DONE) {
        try checkError(rc2, db);
    }
}

// List all tasks
fn listTasks(db: *c.sqlite3) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT id, description, completed FROM tasks ORDER BY id;";
    const rc = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len + 1), &stmt, null);
    try checkError(rc, db);
    defer _ = c.sqlite3_finalize(stmt);

    const stdout = std.io.getStdOut().writer();

    while (true) {
        const step = c.sqlite3_step(stmt);
        if (step == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int(stmt, 0);
            const descPtr = c.sqlite3_column_text(stmt, 1);
            const desc = std.mem.span(descPtr);
            const completed = c.sqlite3_column_int(stmt, 2) != 0;
            try stdout.print("{d}. [{s}] {s}\n", .{
                id,
                if (completed) "x" else " ",
                desc,
            });
        } else if (step == c.SQLITE_DONE) {
            break;
        } else {
            try checkError(step, db);
        }
    }
}

// Mark a task as completed
fn completeTask(db: *c.sqlite3, id: i64) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "UPDATE tasks SET completed = 1 WHERE id = ?;";
    const rc = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len + 1), &stmt, null);
    try checkError(rc, db);
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, id);
    const rc2 = c.sqlite3_step(stmt);
    if (rc2 != c.SQLITE_DONE) {
        try checkError(rc2, db);
    }
}

pub fn main() !void {
    var argsIter = std.process.args();
    _ = argsIter.next(); // skip program name

    const cmd = argsIter.next() orelse {
        std.debug.print("Usage: todo <add|list|complete> [args]\n", .{});
        return;
    };

    // Use a C-string for sqlite3_open
    const dbPath = "todo.db\x00"; 
    const db = try initDb(dbPath);
    defer _ = c.sqlite3_close(db);

    if (std.mem.eql(u8, cmd, "add")) {
        const desc = argsIter.next() orelse {
            std.debug.print("Missing description for 'add'.\n", .{});
            return;
        };
        try addTask(db, desc);
        std.debug.print("Task added.\n", .{});
    } else if (std.mem.eql(u8, cmd, "list")) {
        try listTasks(db);
    } else if (std.mem.eql(u8, cmd, "complete")) {
        const idStr = argsIter.next() orelse {
            std.debug.print("Missing id for 'complete'.\n", .{});
            return;
        };
        const id = std.fmt.parseInt(i64, idStr, 10) catch {
            std.debug.print("Invalid id: {s}\n", .{idStr});
            return;
        };
        try completeTask(db, id);
        std.debug.print("Task {d} marked as completed.\n", .{id});
    } else {
        std.debug.print("Unknown command: {s}\n", .{cmd});
    }
}
