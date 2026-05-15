const std = @import("std");
const db = @import("db");
const c = @import("c");

pub const SyncDirection = enum { push, pull, both };

pub const SyncVerdict = enum {
    create_remote,
    create_local,
    update_remote,
    update_local,
    already_synced,
};

pub const SyncReport = struct {
    created_local: u32 = 0,
    created_remote: u32 = 0,
    updated_local: u32 = 0,
    updated_remote: u32 = 0,
    skipped: u32 = 0,
    errors: u32 = 0,
};

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

pub fn syncTasks(
    io: std.Io,
    local_db: *c.sqlite3,
    remote_db: *c.MYSQL,
    direction: SyncDirection,
    dry_run: bool,
    allocator: std.mem.Allocator,
) !SyncReport {
    var report = SyncReport{};

    // Query all tasks from both sides
    var local_tasks = try db.queryAllTasksForSync(.{ .sqlite = local_db }, allocator);
    defer {
        for (local_tasks.items) |task| {
            allocator.free(task.title);
            allocator.free(task.status);
        }
        local_tasks.deinit(allocator);
    }

    var remote_tasks = try db.queryAllTasksForSync(.{ .mariadb = remote_db }, allocator);
    defer {
        for (remote_tasks.items) |task| {
            allocator.free(task.title);
            allocator.free(task.status);
        }
        remote_tasks.deinit(allocator);
    }

    // Build HashMaps for O(1) lookup by title
    var remote_by_title = std.StringHashMap(db.SyncTask).init(allocator);
    defer remote_by_title.deinit();
    for (remote_tasks.items) |task| {
        const gop = remote_by_title.getOrPut(task.title) catch continue;
        if (gop.found_existing) {
            std.debug.print("Warning: duplicate remote title '{s}', skipping\n", .{task.title});
        } else {
            gop.value_ptr.* = task;
        }
    }

    var local_title_set = std.StringHashMap(void).init(allocator);
    defer local_title_set.deinit();
    for (local_tasks.items) |task| {
        const gop = local_title_set.getOrPut(task.title) catch continue;
        if (gop.found_existing) {
            std.debug.print("Warning: duplicate local title '{s}', skipping\n", .{task.title});
        }
    }

    // Process all local tasks (find matches in remote via HashMap)
    for (local_tasks.items) |local_task| {
        if (!local_title_set.contains(local_task.title)) continue; // duplicate, already removed

        const remote_match: ?db.SyncTask = remote_by_title.get(local_task.title);
        const verdict = classifyTask(local_task, remote_match, direction);

        switch (verdict) {
            .create_remote => {
                if (!dry_run) {
                    _ = db.upsertTaskByTitle(.{ .mariadb = remote_db }, local_task) catch {
                        std.debug.print("Error: failed to sync task '{s}' to remote.\n", .{local_task.title});
                        report.errors += 1;
                        continue;
                    };
                }
                report.created_remote += 1;
            },
            .update_remote => {
                if (!dry_run) {
                    _ = db.upsertTaskByTitle(.{ .mariadb = remote_db }, local_task) catch {
                        std.debug.print("Error: failed to sync task '{s}' to remote.\n", .{local_task.title});
                        report.errors += 1;
                        continue;
                    };
                }
                report.updated_remote += 1;
            },
            .update_local => {
                if (!dry_run) {
                    _ = db.upsertTaskByTitle(.{ .sqlite = local_db }, remote_match.?) catch {
                        std.debug.print("Error: failed to sync task '{s}' from remote.\n", .{remote_match.?.title});
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
    }

    // Process remote tasks that don't exist locally (HashMap lookup)
    for (remote_tasks.items) |remote_task| {
        if (!remote_by_title.contains(remote_task.title)) continue; // duplicate, already removed

        if (!local_title_set.contains(remote_task.title)) {
            const verdict = classifyTask(null, remote_task, direction);
            switch (verdict) {
                .create_local => {
                    if (!dry_run) {
                        _ = db.upsertTaskByTitle(.{ .sqlite = local_db }, remote_task) catch {
                            std.debug.print("Error: failed to sync task '{s}' from remote.\n", .{remote_task.title});
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
        // If local exists, it was already handled in the first loop
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
