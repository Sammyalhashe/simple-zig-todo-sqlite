const c = @import("c");
const std = @import("std");

pub fn run(db: *c.sqlite3) void {
    // Add remote_task_id column for sync identity tracking.
    _ = c.sqlite3_exec(db, "ALTER TABLE tasks ADD COLUMN remote_task_id TEXT", null, null, null);

    // Add due_time column for deadline tracking.
    _ = c.sqlite3_exec(db, "ALTER TABLE tasks ADD COLUMN due_time INTEGER NOT NULL DEFAULT 0", null, null, null);

    // Enforce at most one local row per remote identity.
    const idx_rc = c.sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_remote_task_id ON tasks(remote_task_id) WHERE remote_task_id IS NOT NULL;", null, null, null);
    if (idx_rc != c.SQLITE_OK) {
        std.log.warn("Warning: could not create unique index on remote_task_id (possible duplicates in existing data)", .{});
    }

    // Convert second-precision timestamps to milliseconds.
    _ = c.sqlite3_exec(db, "UPDATE tasks SET last_modified = last_modified * 1000 WHERE last_modified > 0 AND last_modified < 10000000000;", null, null, null);
    _ = c.sqlite3_exec(db, "UPDATE tasks SET completed_time = completed_time * 1000 WHERE completed_time IS NOT NULL AND completed_time > 0 AND completed_time < 10000000000;", null, null, null);
}
