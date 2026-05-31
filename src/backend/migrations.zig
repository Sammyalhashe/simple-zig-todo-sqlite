const c = @import("c");
const std = @import("std");

pub fn run(db: *c.sqlite3) void {
    // Convert second-precision timestamps to milliseconds.
    // (due_time and remote_task_id are now in create_table.sql, no need to ALTER)
    _ = c.sqlite3_exec(db, "UPDATE tasks SET last_modified = last_modified * 1000 WHERE last_modified > 0 AND last_modified < 10000000000;", null, null, null);
    _ = c.sqlite3_exec(db, "UPDATE tasks SET completed_time = completed_time * 1000 WHERE completed_time IS NOT NULL AND completed_time > 0 AND completed_time < 10000000000;", null, null, null);
}
