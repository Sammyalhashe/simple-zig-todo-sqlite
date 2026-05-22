const std = @import("std");
const types = @import("../types.zig");
const util = @import("../util.zig");

const Self = @This();

const StoredTask = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    last_modified: i64,
    completed_time: ?i64,
    is_deleted: bool,
    remote_id: ?[]const u8,
};

/// JSON-parseable struct matching the file format exactly.
const TaskJson = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    last_modified: i64,
    completed_time: ?i64 = null,
    is_deleted: bool,
    remote_id: ?[]const u8 = null,
};

pub const JjError = error{ JjNotFound, GitNotFound, SubprocessFailed };

allocator: std.mem.Allocator,
io: std.Io,
file_path: []const u8, // allocator-owned
tasks: std.ArrayList(StoredTask),
in_transaction: bool,
txn_snapshot: ?[]u8, // allocator-owned raw bytes for rollback

pub fn init(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !*Self {
    // Pre-flight: check jj and git exist
    try checkToolExists(io, "jj", JjError.JjNotFound);
    try checkToolExists(io, "git", JjError.GitNotFound);

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const owned_path = try allocator.dupe(u8, file_path);
    errdefer allocator.free(owned_path);

    self.* = .{
        .allocator = allocator,
        .io = io,
        .file_path = owned_path,
        .tasks = .empty,
        .in_transaction = false,
        .txn_snapshot = null,
    };

    // Load or create file
    const file_exists = blk: {
        std.Io.Dir.cwd().access(io, file_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!file_exists) {
        try self.writeFileToDisk();
        jjTrack(io, file_path);
    } else {
        self.loadFromDisk() catch |err| {
            self.deinitTasks();
            return err;
        };
    }

    return self;
}

pub fn close(self: *Self) void {
    self.deinitTasks();
    self.allocator.free(self.file_path);
    if (self.txn_snapshot) |snap| self.allocator.free(snap);
    self.allocator.destroy(self);
}

// ── Transactions ───────────────────────────────────────────────────────

pub fn beginTransaction(self: *Self) !void {
    if (self.in_transaction) return error.SqlError;
    self.txn_snapshot = try self.serializeToBytes();
    self.in_transaction = true;
}

pub fn commitTransaction(self: *Self) !void {
    if (!self.in_transaction) return error.SqlError;
    try self.writeFileToDisk();
    if (self.txn_snapshot) |snap| self.allocator.free(snap);
    self.txn_snapshot = null;
    self.in_transaction = false;
}

pub fn rollbackTransaction(self: *Self) !void {
    const snap = self.txn_snapshot orelse return;
    // Always clean up transaction state, even if re-parse fails.
    defer {
        self.allocator.free(snap);
        self.txn_snapshot = null;
        self.in_transaction = false;
    }

    // Write snapshot bytes directly to disk via tmp+rename
    const tmp_path = try std.mem.concat(self.allocator, u8, &.{ self.file_path, ".tmp" });
    defer self.allocator.free(tmp_path);

    const dir = std.Io.Dir.cwd();
    const f = try dir.createFile(self.io, tmp_path, .{});
    try f.writeStreamingAll(self.io, snap);
    try f.sync(self.io);
    f.close(self.io);
    try std.Io.Dir.rename(dir, tmp_path, dir, self.file_path, self.io);

    // Re-parse into tasks
    self.deinitTasks();
    self.tasks = .empty;
    try self.loadFromDisk();
}

// ── CRUD ───────────────────────────────────────────────────────────────

pub fn addTask(self: *Self, io: std.Io, desc: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(desc)) return error.InvalidUtf8;
    const uuid = util.generateUuidV4(io);
    const ts = std.Io.Timestamp.now(io, .real);
    const now = @as(i64, @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s)));

    const id = try self.allocator.dupe(u8, &uuid);
    errdefer self.allocator.free(id);
    const title = try self.allocator.dupe(u8, desc);
    errdefer self.allocator.free(title);
    const status = try self.allocator.dupe(u8, "needsAction");
    errdefer self.allocator.free(status);

    try self.tasks.append(self.allocator, .{
        .id = id,
        .title = title,
        .status = status,
        .last_modified = now,
        .completed_time = null,
        .is_deleted = false,
        .remote_id = null,
    });
    try self.maybeFlush();
}

pub fn queryTasks(self: *Self, showAll: bool, allocator: std.mem.Allocator) !std.ArrayList(types.Task) {
    var result: std.ArrayList(types.Task) = .empty;
    errdefer {
        for (result.items) |t| {
            allocator.free(t.id);
            allocator.free(t.title);
            allocator.free(t.status);
        }
        result.deinit(allocator);
    }
    for (self.tasks.items) |task| {
        if (task.is_deleted) continue;
        if (!showAll and std.mem.eql(u8, task.status, "completed")) continue;
        const id = try allocator.dupe(u8, task.id);
        errdefer allocator.free(id);
        const title = try allocator.dupe(u8, task.title);
        errdefer allocator.free(title);
        const status = try allocator.dupe(u8, task.status);
        errdefer allocator.free(status);
        try result.append(allocator, .{ .id = id, .title = title, .status = status });
    }
    return result;
}

pub fn queryAllTasksForSync(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(types.SyncTask) {
    var result: std.ArrayList(types.SyncTask) = .empty;
    errdefer {
        for (result.items) |t| {
            allocator.free(t.title);
            allocator.free(t.status);
            if (t.remote_id) |r| allocator.free(r);
        }
        result.deinit(allocator);
    }
    for (self.tasks.items) |task| {
        if (task.is_deleted) continue;
        const title = try allocator.dupe(u8, task.title);
        errdefer allocator.free(title);
        const status = try allocator.dupe(u8, task.status);
        errdefer allocator.free(status);
        const remote_id: ?[]const u8 = if (task.remote_id) |r| try allocator.dupe(u8, r) else null;
        errdefer if (remote_id) |r| allocator.free(r);
        try result.append(allocator, .{
            .title = title,
            .status = status,
            .last_modified = task.last_modified,
            .completed_time = task.completed_time,
            .is_deleted = task.is_deleted,
            .remote_id = remote_id,
        });
    }
    return result;
}

pub fn upsertTask(self: *Self, io: std.Io, task: types.SyncTask) !types.UpsertResult {
    if (!std.unicode.utf8ValidateSlice(task.title)) return error.InvalidUtf8;
    if (task.remote_id) |r| if (!std.unicode.utf8ValidateSlice(r)) return error.InvalidUtf8;
    // Look for existing: prefer remote_id match, fall back to title match
    var found_idx: ?usize = null;

    if (task.remote_id) |rid| {
        for (self.tasks.items, 0..) |existing, i| {
            if (existing.is_deleted) continue;
            if (existing.remote_id) |er| {
                if (std.mem.eql(u8, er, rid)) {
                    found_idx = i;
                    break;
                }
            }
        }
    }

    if (found_idx == null) {
        for (self.tasks.items, 0..) |existing, i| {
            if (existing.is_deleted) continue;
            if (std.mem.eql(u8, existing.title, task.title)) {
                found_idx = i;
                break;
            }
        }
    }

    if (found_idx) |idx| {
        const existing = &self.tasks.items[idx];
        if (task.last_modified > existing.last_modified) {
            // Allocate all new strings first — if any alloc fails the old strings are still valid.
            const new_title = try self.allocator.dupe(u8, task.title);
            errdefer self.allocator.free(new_title);
            const new_status = try self.allocator.dupe(u8, task.status);
            errdefer self.allocator.free(new_status);
            const new_remote_id: ?[]const u8 = if (task.remote_id) |r| try self.allocator.dupe(u8, r) else null;
            errdefer if (new_remote_id) |r| self.allocator.free(r);

            // All allocations succeeded — free old strings and assign atomically.
            self.allocator.free(existing.title);
            self.allocator.free(existing.status);
            if (existing.remote_id) |r| self.allocator.free(r);
            existing.title = new_title;
            existing.status = new_status;
            existing.last_modified = task.last_modified;
            existing.completed_time = task.completed_time;
            existing.remote_id = new_remote_id;

            try self.maybeFlush();
            return .updated;
        } else {
            return .skipped;
        }
    } else {
        // Insert new
        const uuid = util.generateUuidV4(io);
        const id = try self.allocator.dupe(u8, &uuid);
        errdefer self.allocator.free(id);
        const title = try self.allocator.dupe(u8, task.title);
        errdefer self.allocator.free(title);
        const status = try self.allocator.dupe(u8, task.status);
        errdefer self.allocator.free(status);
        const remote_id: ?[]const u8 = if (task.remote_id) |r| try self.allocator.dupe(u8, r) else null;
        errdefer if (remote_id) |r| self.allocator.free(r);

        try self.tasks.append(self.allocator, .{
            .id = id,
            .title = title,
            .status = status,
            .last_modified = task.last_modified,
            .completed_time = task.completed_time,
            .is_deleted = false,
            .remote_id = remote_id,
        });
        try self.maybeFlush();
        return .inserted;
    }
}

pub fn setRemoteTaskId(self: *Self, local_title: []const u8, remote_id: []const u8) !void {
    for (self.tasks.items) |*task| {
        if (task.is_deleted) continue;
        if (task.remote_id != null) continue;
        if (std.mem.eql(u8, task.title, local_title)) {
            task.remote_id = try self.allocator.dupe(u8, remote_id);
            try self.maybeFlush();
            return;
        }
    }
}

pub fn changeCompletionStatus(self: *Self, io: std.Io, id_str: []const u8, complete: bool) !void {
    for (self.tasks.items) |*task| {
        if (std.mem.eql(u8, task.id, id_str)) {
            // Dupe new status before freeing old — keeps task valid if alloc fails.
            const new_status = try self.allocator.dupe(u8, if (complete) "completed" else "needsAction");
            self.allocator.free(task.status);
            task.status = new_status;

            const ts = std.Io.Timestamp.now(io, .real);
            const now = @as(i64, @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s)));
            task.last_modified = now;
            task.completed_time = if (complete) now else null;

            try self.maybeFlush();
            return;
        }
    }
    std.log.err("no task found with id '{s}'", .{id_str});
    return error.TaskNotFound;
}

// ── Private helpers ────────────────────────────────────────────────────

fn checkToolExists(io: std.Io, tool: []const u8, err_val: JjError) JjError!void {
    var child = std.process.spawn(io, .{
        .argv = &.{ tool, "--version" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return err_val;
    const term = child.wait(io) catch return err_val;
    switch (term) {
        .exited => |code| if (code != 0) return err_val,
        else => return err_val,
    }
}

fn runSubprocess(argv: []const []const u8, io: std.Io, cwd: []const u8) JjError!void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return JjError.SubprocessFailed;
    const term = child.wait(io) catch return JjError.SubprocessFailed;
    switch (term) {
        .exited => |code| if (code != 0) return JjError.SubprocessFailed,
        else => return JjError.SubprocessFailed,
    }
}

fn jjRun(comptime argv: []const []const u8, io: std.Io, cwd: []const u8) !void {
    comptime std.debug.assert(argv.len >= 2);
    runSubprocess(argv, io, cwd) catch {
        std.log.err(argv[0] ++ " " ++ argv[1] ++ " failed", .{});
        return JjError.SubprocessFailed;
    };
}

fn jjDescribe(io: std.Io, cwd: []const u8, message: []const u8) !void {
    const argv: [4][]const u8 = .{ "jj", "describe", "--message", message };
    runSubprocess(&argv, io, cwd) catch {
        std.log.err("jj describe failed", .{});
        return JjError.SubprocessFailed;
    };
}

fn jjBookmarkExists(io: std.Io, cwd: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "jj", "log", "-r", "master@origin", "--no-graph", "--limit", "1" },
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn jjTrack(io: std.Io, file_path: []const u8) void {
    const cwd = std.fs.path.dirname(file_path) orelse ".";
    const basename = std.fs.path.basename(file_path);
    const argv: [4][]const u8 = .{ "jj", "file", "track", basename };
    runSubprocess(&argv, io, cwd) catch {
        std.log.warn("jj file track failed", .{});
    };
}

fn makeCommitMessage(io: std.Io, buf: *[64]u8) []const u8 {
    const ts = std.Io.Timestamp.now(io, .real);
    const epoch_secs: u64 = @intCast(@max(0, @divTrunc(ts.nanoseconds, std.time.ns_per_s)));
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const epoch_day = es.getEpochDay();
    const yd = epoch_day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "todo: sync {d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
    }) catch unreachable;
}

fn deinitTasks(self: *Self) void {
    for (self.tasks.items) |task| {
        self.allocator.free(task.id);
        self.allocator.free(task.title);
        self.allocator.free(task.status);
        if (task.remote_id) |r| self.allocator.free(r);
    }
    self.tasks.deinit(self.allocator);
}

fn writeFileToDisk(self: *Self) !void {
    const bytes = try self.serializeToBytes();
    defer self.allocator.free(bytes);

    const tmp_path = try std.mem.concat(self.allocator, u8, &.{ self.file_path, ".tmp" });
    defer self.allocator.free(tmp_path);

    const dir = std.Io.Dir.cwd();
    const f = try dir.createFile(self.io, tmp_path, .{});
    errdefer dir.deleteFile(self.io, tmp_path) catch {};
    try f.writeStreamingAll(self.io, bytes);
    try f.sync(self.io);
    f.close(self.io);
    try std.Io.Dir.rename(dir, tmp_path, dir, self.file_path, self.io);
}

pub fn syncToRemote(self: *Self) void {
    const cwd = std.fs.path.dirname(self.file_path) orelse ".";

    jjRun(&.{ "jj", "git", "fetch" }, self.io, cwd) catch |err| {
        std.log.warn("jj git fetch failed: {s}", .{@errorName(err)});
        return;
    };

    if (jjBookmarkExists(self.io, cwd)) {
        jjRun(&.{ "jj", "rebase", "-d", "master@origin" }, self.io, cwd) catch |err| {
            std.log.warn("jj rebase failed: {s}", .{@errorName(err)});
        };
    } else {
        std.log.warn("master@origin not found, skipping rebase", .{});
    }

    var msg_buf: [64]u8 = undefined;
    const message = makeCommitMessage(self.io, &msg_buf);
    jjDescribe(self.io, cwd, message) catch |err| {
        std.log.warn("jj describe failed: {s}", .{@errorName(err)});
    };

    if (!jjBookmarkExists(self.io, cwd)) {
        std.log.warn("master@origin not found, skipping push", .{});
        return;
    }

    jjRun(&.{ "jj", "bookmark", "set", "master", "-r", "@" }, self.io, cwd) catch |err| {
        std.log.warn("jj bookmark set master -r @ failed: {s}", .{@errorName(err)});
    };

    jjRun(&.{ "jj", "git", "push" }, self.io, cwd) catch |err| {
        std.log.warn("jj git push failed: {s}", .{@errorName(err)});
    };
}

fn loadFromDisk(self: *Self) !void {
    const dir = std.Io.Dir.cwd();
    const f = try dir.openFile(self.io, self.file_path, .{});
    defer f.close(self.io);

    var read_buf: [8192]u8 = undefined;
    var reader = f.reader(self.io, &read_buf);
    const contents = try reader.interface.allocRemaining(self.allocator, std.Io.Limit.limited(16 * 1024 * 1024));
    defer self.allocator.free(contents);

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        const parsed = std.json.parseFromSlice(TaskJson, self.allocator, line, .{}) catch |err| {
            std.log.warn("skipping unparseable line: {}", .{err});
            continue;
        };
        defer parsed.deinit();
        const v = parsed.value;

        const id = try self.allocator.dupe(u8, v.id);
        errdefer self.allocator.free(id);
        const title = try self.allocator.dupe(u8, v.title);
        errdefer self.allocator.free(title);
        const status = try self.allocator.dupe(u8, v.status);
        errdefer self.allocator.free(status);
        const remote_id: ?[]const u8 = if (v.remote_id) |r| try self.allocator.dupe(u8, r) else null;
        errdefer if (remote_id) |r| self.allocator.free(r);

        try self.tasks.append(self.allocator, .{
            .id = id,
            .title = title,
            .status = status,
            .last_modified = v.last_modified,
            .completed_time = v.completed_time,
            .is_deleted = v.is_deleted,
            .remote_id = remote_id,
        });
    }
}

fn maybeFlush(self: *Self) !void {
    if (!self.in_transaction) {
        try self.writeFileToDisk();
        self.syncToRemote();
    }
}

fn serializeToBytes(self: *Self) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    try buf.appendSlice(self.allocator, "# jj-todo v1\n");

    for (self.tasks.items) |task| {
        try appendTaskJson(&buf, self.allocator, task);
        try buf.append(self.allocator, '\n');
    }
    return try self.allocator.dupe(u8, buf.items);
}

fn appendTaskJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, task: StoredTask) !void {
    try buf.appendSlice(allocator, "{\"id\":\"");
    try appendJsonEscaped(buf, allocator, task.id);
    try buf.appendSlice(allocator, "\",\"title\":\"");
    try appendJsonEscaped(buf, allocator, task.title);
    try buf.appendSlice(allocator, "\",\"status\":\"");
    try appendJsonEscaped(buf, allocator, task.status);
    try buf.appendSlice(allocator, "\",\"last_modified\":");
    var num_buf: [32]u8 = undefined;
    const lm_str = std.fmt.bufPrint(&num_buf, "{d}", .{task.last_modified}) catch unreachable;
    try buf.appendSlice(allocator, lm_str);
    try buf.appendSlice(allocator, ",\"completed_time\":");
    if (task.completed_time) |ct| {
        const ct_str = std.fmt.bufPrint(&num_buf, "{d}", .{ct}) catch unreachable;
        try buf.appendSlice(allocator, ct_str);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"is_deleted\":");
    try buf.appendSlice(allocator, if (task.is_deleted) "true" else "false");
    try buf.appendSlice(allocator, ",\"remote_id\":");
    if (task.remote_id) |rid| {
        try buf.append(allocator, '"');
        try appendJsonEscaped(buf, allocator, rid);
        try buf.append(allocator, '"');
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.append(allocator, '}');
}

fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    var esc_buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{ch}) catch unreachable;
                    try buf.appendSlice(allocator, hex);
                } else {
                    try buf.append(allocator, ch);
                }
            },
        }
    }
}
