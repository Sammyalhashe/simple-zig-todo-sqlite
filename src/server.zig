const std = @import("std");
const db = @import("db");
const net = std.Io.net;

const allocator = std.heap.page_allocator;

pub fn serve(io: std.Io, database: db.Db, socket_path: []const u8) !void {
    // Remove stale socket file via C unlink
    const c_path = @as([*:0]const u8, @ptrCast(socket_path.ptr));
    _ = std.c.unlink(c_path);

    const ua = try net.UnixAddress.init(socket_path);
    var server = try ua.listen(io, .{});
    defer server.deinit(io);

    std.debug.print("Listening on {s}\n", .{socket_path});

    while (true) {
        var stream = server.accept(io) catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };
        defer stream.close(io);

        handleConnection(io, database, &stream) catch |err| {
            std.debug.print("Connection error: {}\n", .{err});
        };
    }
}

fn handleConnection(io: std.Io, database: db.Db, stream: *net.Stream) !void {
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
            return;
        };
        if (n == 0) return;

        if (chunk[0] == '\n') {
            // Process complete line
            const response = processRequest(database, line_buf[0..line_len]) catch "{\"error\":\"internal error\"}\n";
            try writer.interface.writeAll(response);
            try writer.interface.flush();
            line_len = 0;
        } else {
            if (line_len < line_buf.len) {
                line_buf[line_len] = chunk[0];
                line_len += 1;
            }
        }
    }
}

fn processRequest(database: db.Db, line: []const u8) ![]const u8 {
    // Simple JSON parsing: look for "method" field
    const method = extractJsonString(line, "method") orelse return "{\"error\":\"missing method\"}\n";

    if (std.mem.eql(u8, method, "listTasks")) {
        const show_all = extractJsonBool(line, "showAll") orelse false;
        var tasks = try db.queryTasks(database, show_all, allocator);
        defer {
            for (tasks.items) |task| {
                allocator.free(task.id);
                allocator.free(task.title);
                allocator.free(task.status);
            }
            tasks.deinit(allocator);
        }

        // Build JSON response
        var resp = std.ArrayList(u8).empty;
        defer resp.deinit(allocator);
        try resp.appendSlice(allocator, "[");
        for (tasks.items, 0..) |task, i| {
            if (i > 0) try resp.appendSlice(allocator, ",");
            try resp.appendSlice(allocator, "{\"id\":\"");
            try resp.appendSlice(allocator, task.id);
            try resp.appendSlice(allocator, "\",\"title\":\"");
            try appendEscaped(&resp, task.title);
            try resp.appendSlice(allocator, "\",\"status\":\"");
            try resp.appendSlice(allocator, task.status);
            try resp.appendSlice(allocator, "\"}");
        }
        try resp.appendSlice(allocator, "]\n");
        return try allocator.dupe(u8, resp.items);
    } else if (std.mem.eql(u8, method, "addTask")) {
        const title = extractJsonString(line, "title") orelse return "{\"error\":\"missing title\"}\n";
        db.addTask(database, title) catch return "{\"error\":\"addTask failed\"}\n";
        return "{\"ok\":true}\n";
    } else if (std.mem.eql(u8, method, "complete")) {
        const id = extractJsonString(line, "id") orelse return "{\"error\":\"missing id\"}\n";
        // changeCompletionStatus needs io for timestamps — use a fallback
        _ = db.changeCompletionStatusNoIo(database, id, true) catch return "{\"error\":\"complete failed\"}\n";
        return "{\"ok\":true}\n";
    } else if (std.mem.eql(u8, method, "incomplete")) {
        const id = extractJsonString(line, "id") orelse return "{\"error\":\"missing id\"}\n";
        _ = db.changeCompletionStatusNoIo(database, id, false) catch return "{\"error\":\"incomplete failed\"}\n";
        return "{\"ok\":true}\n";
    } else if (std.mem.eql(u8, method, "shutdown")) {
        return "{\"ok\":\"shutting down\"}\n";
    }

    return "{\"error\":\"unknown method\"}\n";
}

fn appendEscaped(list: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            else => try list.append(allocator, ch),
        }
    }
}

// Minimal JSON string extractor: finds "key":"value" pattern
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key":"
    var i: usize = 0;
    while (i + key.len + 4 < json.len) : (i += 1) {
        if (json[i] == '"' and i + 1 + key.len < json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            // Found key, now find value after :"
            var j = i + 1 + key.len + 1; // past closing quote
            // Skip : and whitespace
            while (j < json.len and (json[j] == ':' or json[j] == ' ')) : (j += 1) {}
            if (j < json.len and json[j] == '"') {
                j += 1; // past opening quote of value
                const start = j;
                while (j < json.len and json[j] != '"') : (j += 1) {}
                return json[start..j];
            }
        }
    }
    return null;
}

// Minimal JSON bool extractor: finds "key":true/false pattern
fn extractJsonBool(json: []const u8, key: []const u8) ?bool {
    var i: usize = 0;
    while (i + key.len + 4 < json.len) : (i += 1) {
        if (json[i] == '"' and i + 1 + key.len < json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            var j = i + 1 + key.len + 1;
            while (j < json.len and (json[j] == ':' or json[j] == ' ')) : (j += 1) {}
            if (j + 4 <= json.len and std.mem.eql(u8, json[j .. j + 4], "true")) return true;
            if (j + 5 <= json.len and std.mem.eql(u8, json[j .. j + 5], "false")) return false;
        }
    }
    return null;
}
