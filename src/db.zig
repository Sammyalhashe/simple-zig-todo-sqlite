const std = @import("std");
const c = @import("c");
pub const json = @import("json");

// Re-export shared types so callers keep using `db.Task`, `db.SyncTask`, etc.
pub const types = @import("types.zig");
pub const SqlError = types.SqlError;
pub const Task = types.Task;
pub const SyncTask = types.SyncTask;
pub const UpsertResult = types.UpsertResult;

// Backend implementations (each file IS the struct via @This())
pub const SqliteBackend = @import("backend/sqlite.zig");
pub const MariaBackend = @import("backend/mariadb.zig");
pub const JjBackend = @import("backend/jj.zig");

/// Type-erased backend handle. Use `inline else` for zero-overhead dispatch.
pub const AnyBackend = union(enum) {
    sqlite: *SqliteBackend,
    mariadb: *MariaBackend,
    jj: *JjBackend,

    pub fn close(self: AnyBackend) void {
        switch (self) {
            inline else => |b| b.close(),
        }
    }
    pub fn beginTransaction(self: AnyBackend) !void {
        switch (self) {
            inline else => |b| return b.beginTransaction(),
        }
    }
    pub fn commitTransaction(self: AnyBackend) !void {
        switch (self) {
            inline else => |b| return b.commitTransaction(),
        }
    }
    pub fn rollbackTransaction(self: AnyBackend) !void {
        switch (self) {
            inline else => |b| return b.rollbackTransaction(),
        }
    }
    pub fn addTask(self: AnyBackend, io: std.Io, desc: []const u8) !void {
        switch (self) {
            inline else => |b| return b.addTask(io, desc),
        }
    }
    pub fn queryTasks(self: AnyBackend, showAll: bool, allocator: std.mem.Allocator) !std.ArrayList(Task) {
        switch (self) {
            inline else => |b| return b.queryTasks(showAll, allocator),
        }
    }
    pub fn queryAllTasksForSync(self: AnyBackend, allocator: std.mem.Allocator) !std.ArrayList(SyncTask) {
        switch (self) {
            inline else => |b| return b.queryAllTasksForSync(allocator),
        }
    }
    pub fn upsertTask(self: AnyBackend, io: std.Io, task: SyncTask) !UpsertResult {
        switch (self) {
            inline else => |b| return b.upsertTask(io, task),
        }
    }
    pub fn setRemoteTaskId(self: AnyBackend, local_title: []const u8, remote_id: []const u8) !void {
        switch (self) {
            inline else => |b| return b.setRemoteTaskId(local_title, remote_id),
        }
    }
    pub fn changeCompletionStatus(self: AnyBackend, io: std.Io, id_str: []const u8, complete: bool) !void {
        switch (self) {
            inline else => |b| return b.changeCompletionStatus(io, id_str, complete),
        }
    }
    pub fn deleteTask(self: AnyBackend, io: std.Io, id_str: []const u8) !void {
        switch (self) {
            inline else => |b| return b.deleteTask(io, id_str),
        }
    }
};

// Keep Db as a type alias for backward compat during the transition
pub const Db = AnyBackend;

/// Opens or creates a SQLite database at `dbPath`.
pub fn openSqlite(allocator: std.mem.Allocator, dbPath: [:0]const u8) !*SqliteBackend {
    return SqliteBackend.init(allocator, dbPath);
}

/// Connects to a remote MariaDB instance.
pub fn openMariaDb(allocator: std.mem.Allocator, host: []const u8, port: u16, password: ?[]const u8) !*MariaBackend {
    return MariaBackend.init(allocator, host, port, password);
}

/// Opens or creates a jj-backed JSON-lines task file.
pub fn openJj(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !*JjBackend {
    return JjBackend.init(allocator, io, file_path);
}

// --- Backward-compat free functions (thin wrappers so callers compile unchanged) ---

pub fn close(database: AnyBackend) void {
    database.close();
}
pub fn beginTransaction(database: AnyBackend) !void {
    return database.beginTransaction();
}
pub fn commitTransaction(database: AnyBackend) !void {
    return database.commitTransaction();
}
pub fn rollbackTransaction(database: AnyBackend) !void {
    return database.rollbackTransaction();
}
pub fn addTask(io: std.Io, database: AnyBackend, desc: []const u8) !void {
    return database.addTask(io, desc);
}
pub fn queryTasks(database: AnyBackend, showAll: bool, allocator: std.mem.Allocator) !std.ArrayList(Task) {
    return database.queryTasks(showAll, allocator);
}
pub fn queryAllTasksForSync(database: AnyBackend, allocator: std.mem.Allocator) !std.ArrayList(SyncTask) {
    return database.queryAllTasksForSync(allocator);
}
pub fn upsertTask(io: std.Io, database: AnyBackend, task: SyncTask) !UpsertResult {
    return database.upsertTask(io, task);
}
pub fn setRemoteTaskId(database: AnyBackend, local_title: []const u8, remote_id: []const u8) !void {
    return database.setRemoteTaskId(local_title, remote_id);
}
pub fn changeCompletionStatus(io: std.Io, database: AnyBackend, id_str: []const u8, complete: bool) !void {
    return database.changeCompletionStatus(io, id_str, complete);
}
pub fn deleteTask(io: std.Io, database: AnyBackend, id_str: []const u8) !void {
    return database.deleteTask(io, id_str);
}

/// listTasks stays here — it's a presentation function built on queryTasks, not backend-specific.
pub fn listTasks(io: std.Io, database: AnyBackend, showAll: bool, allocator: std.mem.Allocator) !void {
    var tasks = try queryTasks(database, showAll, allocator);
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
