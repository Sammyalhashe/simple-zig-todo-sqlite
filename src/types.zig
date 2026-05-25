const std = @import("std");
pub const json = @import("json");

pub const SqlError = error{SqlError};
pub const TaskNotFound = error{TaskNotFound};

pub const Task = json.Task;

pub const SyncTask = struct {
    title: []const u8,
    status: []const u8,
    last_modified: i64,
    completed_time: ?i64,
    is_deleted: bool,
    due_time: i64,
    remote_id: ?[]const u8 = null,
};

pub const UpsertResult = enum { inserted, updated, skipped };

pub const UpsertResultWithId = struct {
    result: UpsertResult,
    task_id: []const u8,
};
