const std = @import("std");
const db = @import("db");

// --- Types ---

/// Controls which direction tasks flow during sync.
pub const SyncDirection = enum { push, pull, both };

/// The action to take for a single task based on presence and recency on each side.
pub const SyncVerdict = enum {
    create_remote,
    create_local,
    update_remote,
    update_local,
    already_synced,
};

/// Cumulative counters for a completed sync operation.
pub const SyncReport = struct {
    created_local: u32 = 0,
    created_remote: u32 = 0,
    updated_local: u32 = 0,
    updated_remote: u32 = 0,
    skipped: u32 = 0,
    errors: u32 = 0,
};

// --- Classification ---

/// Determines the sync action for a task based on its presence and recency
/// on each side. Pure function with no I/O or side effects.
pub fn classifyTask(
    local_version: ?db.SyncTask,
    remote_version: ?db.SyncTask,
    direction: SyncDirection,
) SyncVerdict {
    if (local_version != null and remote_version == null) {
        return switch (direction) {
            .push, .both => .create_remote,
            .pull => .already_synced,
        };
    }

    if (local_version == null and remote_version != null) {
        return switch (direction) {
            .pull, .both => .create_local,
            .push => .already_synced,
        };
    }

    if (local_version != null and remote_version != null) {
        const local = local_version.?;
        const remote = remote_version.?;

        if (local.last_modified > remote.last_modified) {
            return switch (direction) {
                .push, .both => .update_remote,
                .pull => .already_synced,
            };
        } else if (remote.last_modified > local.last_modified) {
            return switch (direction) {
                .pull, .both => .update_local,
                .push => .already_synced,
            };
        } else {
            return .already_synced;
        }
    }

    // Both null — should not happen, but handle gracefully
    return .already_synced;
}

// --- Sync execution ---

/// Performs bidirectional sync between local and remote databases.
/// Matches tasks by remote_id (preferred) or title (backfill fallback).
/// In dry-run mode, reports what would change without writing.
pub fn syncTasks(
    io: std.Io,
    local_db: db.Db,
    remote_db: db.Db,
    direction: SyncDirection,
    dry_run: bool,
    allocator: std.mem.Allocator,
) !SyncReport {
    var report = SyncReport{};

    // Query all tasks from both sides
    var local_tasks = try db.queryAllTasksForSync(local_db, allocator);
    defer {
        for (local_tasks.items) |task| {
            allocator.free(task.title);
            allocator.free(task.status);
            if (task.remote_id) |r| allocator.free(r);
        }
        local_tasks.deinit(allocator);
    }

    var remote_tasks = try db.queryAllTasksForSync(remote_db, allocator);
    defer {
        for (remote_tasks.items) |task| {
            allocator.free(task.title);
            allocator.free(task.status);
            if (task.remote_id) |r| allocator.free(r);
        }
        remote_tasks.deinit(allocator);
    }

    // Build HashMaps for O(1) lookup of remote tasks.
    // Primary: by remote_id (task_id). Fallback: by title (for backfill).
    var remote_by_id = std.StringHashMap(db.SyncTask).init(allocator);
    defer remote_by_id.deinit();
    var remote_by_title = std.StringHashMap(db.SyncTask).init(allocator);
    defer remote_by_title.deinit();

    for (remote_tasks.items) |task| {
        if (task.remote_id) |rid| {
            const gop = remote_by_id.getOrPut(rid) catch continue;
            if (gop.found_existing) {
                std.log.warn("Warning: duplicate remote id '{s}', skipping", .{rid});
            } else {
                gop.value_ptr.* = task;
            }
        }
        // Always populate by-title for backfill lookups
        const tgop = remote_by_title.getOrPut(task.title) catch continue;
        if (tgop.found_existing) {
            std.log.warn("Warning: duplicate remote title '{s}', skipping", .{task.title});
        } else {
            tgop.value_ptr.* = task;
        }
    }

    // Track which remote tasks are matched (by remote_id) so the second loop
    // knows which ones are truly remote-only.
    var matched_remote_ids = std.StringHashMap(void).init(allocator);
    defer matched_remote_ids.deinit();

    // Begin transactions for batch-commit semantics.
    // Individual upsert failures (caught and counted) do NOT trigger rollback;
    // only a hard error propagating out of this function does.
    if (!dry_run) {
        try db.beginTransaction(local_db);
        errdefer db.rollbackTransaction(local_db) catch {};
        try db.beginTransaction(remote_db);
        errdefer db.rollbackTransaction(remote_db) catch {};
    }

    // Process all local tasks (find matches in remote)
    var seen_local = std.StringHashMap(void).init(allocator);
    defer seen_local.deinit();
    for (local_tasks.items) |local_task| {
        // Deduplicate: use remote_id if available, otherwise title
        const dedup_key = local_task.remote_id orelse local_task.title;
        const gop = seen_local.getOrPut(dedup_key) catch continue;
        if (gop.found_existing) continue;

        // Look up remote match: prefer remote_id, fall back to title
        var remote_match: ?db.SyncTask = null;
        var matched_via_backfill = false;
        if (local_task.remote_id) |rid| {
            remote_match = remote_by_id.get(rid);
            if (remote_match != null) {
                matched_remote_ids.put(rid, {}) catch {};
            }
        }
        if (remote_match == null) {
            // Backfill: match by title
            remote_match = remote_by_title.get(local_task.title);
            if (remote_match != null) {
                matched_via_backfill = true;
                if (remote_match.?.remote_id) |rid| {
                    matched_remote_ids.put(rid, {}) catch {};
                }
            }
        }

        const verdict = classifyTask(local_task, remote_match, direction);

        switch (verdict) {
            .create_remote => {
                if (!dry_run) {
                    _ = db.upsertTask(io, remote_db, local_task) catch {
                        std.log.err("Error: failed to sync task '{s}' to remote.", .{local_task.title});
                        report.errors += 1;
                        continue;
                    };
                }
                report.created_remote += 1;
            },
            .update_remote => {
                if (!dry_run) {
                    // When updating remote, propagate the remote_id so upsertTask
                    // matches by task_id rather than title.
                    const task_to_push = if (local_task.remote_id == null and remote_match != null)
                        db.SyncTask{
                            .title = local_task.title,
                            .status = local_task.status,
                            .last_modified = local_task.last_modified,
                            .completed_time = local_task.completed_time,
                            .is_deleted = local_task.is_deleted,
                            .remote_id = remote_match.?.remote_id,
                        }
                    else
                        local_task;
                    _ = db.upsertTask(io, remote_db, task_to_push) catch {
                        std.log.err("Error: failed to sync task '{s}' to remote.", .{local_task.title});
                        report.errors += 1;
                        continue;
                    };
                }
                report.updated_remote += 1;
            },
            .update_local => {
                if (!dry_run) {
                    _ = db.upsertTask(io, local_db, remote_match.?) catch {
                        std.log.err("Error: failed to sync task '{s}' from remote.", .{remote_match.?.title});
                        report.errors += 1;
                        continue;
                    };
                }
                report.updated_local += 1;
            },
            .create_local => {
                // Should not happen here (local exists in this loop)
                report.skipped += 1;
            },
            .already_synced => {
                report.skipped += 1;
            },
        }

        // Backfill: if local had no remote_id but we matched by title,
        // stamp the remote's task_id onto the local row.
        if (!dry_run and matched_via_backfill and local_task.remote_id == null) {
            if (remote_match.?.remote_id) |rid| {
                db.setRemoteTaskId(local_db, local_task.title, rid) catch {
                    std.log.warn("Warning: failed to backfill remote_task_id for '{s}'", .{local_task.title});
                };
            }
        }
    }

    // Process remote tasks that were not matched above (truly remote-only)
    var seen_remote = std.StringHashMap(void).init(allocator);
    defer seen_remote.deinit();
    for (remote_tasks.items) |remote_task| {
        // Skip if this remote task was already matched to a local task
        if (remote_task.remote_id) |rid| {
            if (matched_remote_ids.contains(rid)) continue;
        }

        const rgop = seen_remote.getOrPut(remote_task.title) catch continue;
        if (rgop.found_existing) continue; // duplicate title, already processed

        const verdict = classifyTask(null, remote_task, direction);
        switch (verdict) {
            .create_local => {
                if (!dry_run) {
                    _ = db.upsertTask(io, local_db, remote_task) catch {
                        std.log.err("Error: failed to sync task '{s}' from remote.", .{remote_task.title});
                        report.errors += 1;
                        continue;
                    };
                }
                report.created_local += 1;
            },
            else => {
                report.skipped += 1;
            },
        }
    }

    // Commit remote first (failure-prone side), then local.
    // If remote commit fails, both errdefers fire and rollback cleanly.
    // If remote succeeds but local fails, next sync reconciles via last_modified.
    if (!dry_run) {
        try db.commitTransaction(remote_db);
        try db.commitTransaction(local_db);
    }

    // Print summary
    var stdout_buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &stdout_buf);
    if (dry_run) {
        w.interface.print("[dry-run] ", .{}) catch {};
    }
    w.interface.print("Sync complete: +{d} local, +{d} remote, ~{d} updated local, ~{d} updated remote, {d} skipped, {d} errors\n", .{
        report.created_local,
        report.created_remote,
        report.updated_local,
        report.updated_remote,
        report.skipped,
        report.errors,
    }) catch {};
    w.interface.flush() catch {};

    return report;
}

// ---------------------------------------------------------------------------
// Unit tests for classifyTask
// ---------------------------------------------------------------------------

const make_task = struct {
    fn f(lm: i64) db.SyncTask {
        return .{ .title = "test", .status = "needsAction", .last_modified = lm, .completed_time = null, .is_deleted = false };
    }
}.f;

test "classifyTask: local-only + push => create_remote" {
    try std.testing.expectEqual(SyncVerdict.create_remote, classifyTask(make_task(100), null, .push));
}

test "classifyTask: local-only + pull => already_synced" {
    try std.testing.expectEqual(SyncVerdict.already_synced, classifyTask(make_task(100), null, .pull));
}

test "classifyTask: local-only + both => create_remote" {
    try std.testing.expectEqual(SyncVerdict.create_remote, classifyTask(make_task(100), null, .both));
}

test "classifyTask: remote-only + pull => create_local" {
    try std.testing.expectEqual(SyncVerdict.create_local, classifyTask(null, make_task(100), .pull));
}

test "classifyTask: remote-only + push => already_synced" {
    try std.testing.expectEqual(SyncVerdict.already_synced, classifyTask(null, make_task(100), .push));
}

test "classifyTask: remote-only + both => create_local" {
    try std.testing.expectEqual(SyncVerdict.create_local, classifyTask(null, make_task(100), .both));
}

test "classifyTask: both exist, local newer + push => update_remote" {
    try std.testing.expectEqual(SyncVerdict.update_remote, classifyTask(make_task(200), make_task(100), .push));
}

test "classifyTask: both exist, local newer + pull => already_synced" {
    try std.testing.expectEqual(SyncVerdict.already_synced, classifyTask(make_task(200), make_task(100), .pull));
}

test "classifyTask: both exist, local newer + both => update_remote" {
    try std.testing.expectEqual(SyncVerdict.update_remote, classifyTask(make_task(200), make_task(100), .both));
}

test "classifyTask: both exist, remote newer + pull => update_local" {
    try std.testing.expectEqual(SyncVerdict.update_local, classifyTask(make_task(100), make_task(200), .pull));
}

test "classifyTask: both exist, remote newer + push => already_synced" {
    try std.testing.expectEqual(SyncVerdict.already_synced, classifyTask(make_task(100), make_task(200), .push));
}

test "classifyTask: both exist, remote newer + both => update_local" {
    try std.testing.expectEqual(SyncVerdict.update_local, classifyTask(make_task(100), make_task(200), .both));
}

test "classifyTask: both exist, equal timestamps + push => already_synced" {
    try std.testing.expectEqual(SyncVerdict.already_synced, classifyTask(make_task(100), make_task(100), .push));
}

test "classifyTask: both exist, equal timestamps + pull => already_synced" {
    try std.testing.expectEqual(SyncVerdict.already_synced, classifyTask(make_task(100), make_task(100), .pull));
}

test "classifyTask: both exist, equal timestamps + both => already_synced" {
    try std.testing.expectEqual(SyncVerdict.already_synced, classifyTask(make_task(100), make_task(100), .both));
}

test "classifyTask: both null => already_synced" {
    try std.testing.expectEqual(SyncVerdict.already_synced, classifyTask(null, null, .push));
    try std.testing.expectEqual(SyncVerdict.already_synced, classifyTask(null, null, .pull));
    try std.testing.expectEqual(SyncVerdict.already_synced, classifyTask(null, null, .both));
}
