const std = @import("std");
const db = @import("db");
const json = @import("json");
const net = std.Io.net;

const max_header_bytes = 8 * 1024;

// --- Routing (pure, unit-tested) ---

pub const Route = enum { tasks, healthz, not_found, method_not_allowed, bad_request };

pub const RequestLine = struct {
    method: []const u8,
    path: []const u8,
};

/// Parses "GET /path HTTP/1.1" (CRLF already stripped). Returns null when malformed.
pub fn parseRequestLine(line: []const u8) ?RequestLine {
    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return null;
    const target = parts.next() orelse return null;
    const version = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (method.len == 0 or target.len == 0 or target[0] != '/') return null;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return null;

    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return .{ .method = method, .path = target[0..path_end] };
}

pub fn route(line: []const u8) Route {
    const req = parseRequestLine(line) orelse return .bad_request;
    if (!std.mem.eql(u8, req.method, "GET")) return .method_not_allowed;
    if (std.mem.eql(u8, req.path, "/tasks")) return .tasks;
    if (std.mem.eql(u8, req.path, "/healthz")) return .healthz;
    return .not_found;
}

// --- Server lifecycle ---

/// Listens on TCP and answers one request per connection, sequentially.
pub fn serve(io: std.Io, database: db.AnyBackend, address: []const u8, port: u16, allocator: std.mem.Allocator) !void {
    const ip = try net.IpAddress.parse(address, port);
    var server = try ip.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("Listening on http://{s}:{d}", .{ address, port });

    while (true) {
        var stream = server.accept(io) catch |err| {
            std.log.err("Accept error: {}", .{err});
            continue;
        };
        defer stream.close(io);

        handleConnection(io, database, &stream, allocator) catch |err| {
            std.log.err("Connection error: {}", .{err});
        };
    }
}

// --- Request handling ---

fn handleConnection(io: std.Io, database: db.AnyBackend, stream: *net.Stream, allocator: std.mem.Allocator) !void {
    var read_buf: [max_header_bytes]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    const which = readRequest(&reader.interface) catch |err| switch (err) {
        error.StreamTooLong, error.HeadersTooLarge => {
            return writeResponse(w, "431 Request Header Fields Too Large", "text/plain", "headers too large\n");
        },
        else => return err,
    };

    switch (which) {
        .tasks => {
            var tasks = try db.queryTasks(database, false, allocator);
            defer {
                for (tasks.items) |task| {
                    allocator.free(task.id);
                    allocator.free(task.title);
                    allocator.free(task.status);
                }
                tasks.deinit(allocator);
            }
            const body = try json.serializeTasksJson(tasks.items, allocator);
            defer allocator.free(body);
            try writeResponse(w, "200 OK", "application/json", body);
        },
        .healthz => try writeResponse(w, "200 OK", "text/plain", "ok\n"),
        .not_found => try writeResponse(w, "404 Not Found", "text/plain", "not found\n"),
        .method_not_allowed => try writeResponse(w, "405 Method Not Allowed", "text/plain", "method not allowed\n"),
        .bad_request => try writeResponse(w, "400 Bad Request", "text/plain", "bad request\n"),
    }
}

/// Reads the request line and drains headers up to the blank line, so the
/// client never sees a reset while it is still sending.
fn readRequest(r: *std.Io.Reader) !Route {
    var total: usize = 0;
    const first = try r.takeDelimiterInclusive('\n');
    total += first.len;
    const which = route(trimCrlf(first));

    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        total += line.len;
        if (total > max_header_bytes) return error.HeadersTooLarge;
        if (trimCrlf(line).len == 0) break;
    }
    return which;
}

fn trimCrlf(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r\n");
}

fn writeResponse(w: *std.Io.Writer, status: []const u8, content_type: []const u8, body: []const u8) !void {
    try w.print("HTTP/1.1 {s}\r\n", .{status});
    if (std.mem.startsWith(u8, status, "405")) try w.writeAll("Allow: GET\r\n");
    try w.print("Content-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ content_type, body.len });
    try w.writeAll(body);
    try w.flush();
}

// --- Tests ---

test "parseRequestLine splits method and path, dropping the query" {
    const req = parseRequestLine("GET /tasks?x=1 HTTP/1.1").?;
    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expectEqualStrings("/tasks", req.path);
}

test "parseRequestLine rejects malformed lines" {
    try std.testing.expect(parseRequestLine("") == null);
    try std.testing.expect(parseRequestLine("GET /tasks") == null);
    try std.testing.expect(parseRequestLine("GET tasks HTTP/1.1") == null);
    try std.testing.expect(parseRequestLine("GET /tasks HTTP/1.1 extra") == null);
    try std.testing.expect(parseRequestLine("GET /tasks SPDY/3") == null);
}

test "route maps requests" {
    try std.testing.expectEqual(Route.tasks, route("GET /tasks HTTP/1.1"));
    try std.testing.expectEqual(Route.healthz, route("GET /healthz HTTP/1.0"));
    try std.testing.expectEqual(Route.not_found, route("GET / HTTP/1.1"));
    try std.testing.expectEqual(Route.not_found, route("GET /tasks/ HTTP/1.1"));
    try std.testing.expectEqual(Route.method_not_allowed, route("POST /tasks HTTP/1.1"));
    try std.testing.expectEqual(Route.method_not_allowed, route("DELETE /healthz HTTP/1.1"));
    try std.testing.expectEqual(Route.bad_request, route("garbage"));
}
