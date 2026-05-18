const std = @import("std");
const db = @import("db");
const json = @import("json");
const net = std.Io.net;

const allocator = std.heap.page_allocator;

// --- Server lifecycle ---

/// Listens on a Unix domain socket and dispatches newline-delimited JSON-RPC requests.
/// Removes any stale socket file before binding.
pub fn serve(io: std.Io, database: db.Db, socket_path: []const u8) !void {
    const c_path = @as([*:0]const u8, @ptrCast(socket_path.ptr));
    _ = std.c.unlink(c_path);

    const ua = try net.UnixAddress.init(socket_path);
    var server = try ua.listen(io, .{});
    defer server.deinit(io);

    std.log.info("Listening on {s}", .{socket_path});

    while (true) {
        var stream = server.accept(io) catch |err| {
            std.log.err("Accept error: {}", .{err});
            continue;
        };
        defer stream.close(io);

        const shutdown = handleConnection(io, database, &stream) catch |err| {
            std.log.err("Connection error: {}", .{err});
            continue;
        };
        if (shutdown) break;
    }

    _ = std.c.unlink(c_path);
}

// --- Request handling ---

const Response = struct {
    data: []const u8,
    allocated: bool,
    shutdown: bool = false,
};

/// Reads newline-delimited messages from a single client connection, dispatching each.
/// Returns true if a shutdown was requested.
fn handleConnection(io: std.Io, database: db.Db, stream: *net.Stream) !bool {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    // Read all available data into a buffer
    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        // Read bytes one chunk at a time looking for newline
        var chunk: [1]u8 = undefined;
        var chunk_slice: [1][]u8 = .{&chunk};
        const n = reader.interface.readVec(&chunk_slice) catch {
            return false;
        };
        if (n == 0) return false;

        if (chunk[0] == '\n') {
            const response = processRequest(io, database, line_buf[0..line_len]) catch Response{
                .data = "{\"error\":\"internal error\"}\n",
                .allocated = false,
            };
            defer if (response.allocated) allocator.free(response.data);
            try writer.interface.writeAll(response.data);
            try writer.interface.flush();
            if (response.shutdown) return true;
            line_len = 0;
        } else {
            if (line_len < line_buf.len) {
                line_buf[line_len] = chunk[0];
                line_len += 1;
            } else {
                // Buffer overflow — discard line and send error
                try writer.interface.writeAll("{\"error\":\"request too large\"}\n");
                try writer.interface.flush();
                line_len = 0;
                // Drain until newline
                while (true) {
                    var drain: [1]u8 = undefined;
                    var drain_slice: [1][]u8 = .{&drain};
                    const dn = reader.interface.readVec(&drain_slice) catch return false;
                    if (dn == 0) return false;
                    if (drain[0] == '\n') break;
                }
            }
        }
    }
}

/// Routes a single JSON-RPC request to the appropriate handler based on the "method" field.
fn processRequest(io: std.Io, database: db.Db, line: []const u8) !Response {
    const method = json.extractJsonString(line, "method") orelse return .{
        .data = "{\"error\":\"missing method\"}\n",
        .allocated = false,
    };

    if (std.mem.eql(u8, method, "listTasks")) {
        const show_all = json.extractJsonBool(line, "showAll") orelse false;
        var tasks = try db.queryTasks(database, show_all, allocator);
        defer {
            for (tasks.items) |task| {
                allocator.free(task.id);
                allocator.free(task.title);
                allocator.free(task.status);
            }
            tasks.deinit(allocator);
        }

        const data = try json.serializeTasksJson(tasks.items, allocator);
        return .{ .data = data, .allocated = true };
    } else if (std.mem.eql(u8, method, "addTask")) {
        const title = json.extractJsonString(line, "title") orelse return .{
            .data = "{\"error\":\"missing title\"}\n",
            .allocated = false,
        };
        db.addTask(io, database, title) catch return .{
            .data = "{\"error\":\"addTask failed\"}\n",
            .allocated = false,
        };
        return .{ .data = "{\"ok\":true}\n", .allocated = false };
    } else if (std.mem.eql(u8, method, "complete")) {
        const id = json.extractJsonString(line, "id") orelse return .{
            .data = "{\"error\":\"missing id\"}\n",
            .allocated = false,
        };
        db.changeCompletionStatus(io, database, id, true) catch return .{
            .data = "{\"error\":\"complete failed\"}\n",
            .allocated = false,
        };
        return .{ .data = "{\"ok\":true}\n", .allocated = false };
    } else if (std.mem.eql(u8, method, "incomplete")) {
        const id = json.extractJsonString(line, "id") orelse return .{
            .data = "{\"error\":\"missing id\"}\n",
            .allocated = false,
        };
        db.changeCompletionStatus(io, database, id, false) catch return .{
            .data = "{\"error\":\"incomplete failed\"}\n",
            .allocated = false,
        };
        return .{ .data = "{\"ok\":true}\n", .allocated = false };
    } else if (std.mem.eql(u8, method, "shutdown")) {
        return .{ .data = "{\"ok\":\"shutting down\"}\n", .allocated = false, .shutdown = true };
    } else if (std.mem.eql(u8, method, "syncStatus") or std.mem.eql(u8, method, "syncTasks")) {
        return .{ .data = "{\"error\":\"sync requires both local and remote databases; use CLI sync command\"}\n", .allocated = false };
    }

    return .{ .data = "{\"error\":\"unknown method\"}\n", .allocated = false };
}
