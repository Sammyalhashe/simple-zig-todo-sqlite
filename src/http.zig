const std = @import("std");
const db = @import("db");
const json = @import("json");
const net = std.Io.net;

const max_header_bytes = 8 * 1024;
const header_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(5), .clock = .awake };

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
    var header_buf: [max_header_bytes]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    const head = readHeaders(io, stream, &header_buf) catch |err| switch (err) {
        error.HeadersTooLarge => {
            return writeResponse(w, "431 Request Header Fields Too Large", "text/plain", "headers too large\n");
        },
        else => return err,
    };
    var head_reader: std.Io.Reader = .fixed(head);
    const which = try readRequest(&head_reader);

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

/// Reads up to the blank line ending the headers. One deadline covers the whole
/// read, so a silent or trickling client cannot stall the single-threaded loop.
fn readHeaders(io: std.Io, stream: *net.Stream, buf: []u8) ![]u8 {
    const deadline = (std.Io.Timeout{ .duration = header_timeout }).toDeadline(io);
    var len: usize = 0;
    while (headersEnd(buf[0..len]) == null) {
        if (len == buf.len) return error.HeadersTooLarge;
        var slices: [1][]u8 = .{buf[len..]};
        const op = try io.operateTimeout(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &slices } }, deadline);
        const result = try op.net_read;
        if (result.data_len == 0) return error.EndOfStream;
        len += result.data_len;
    }
    return buf[0..len];
}

fn headersEnd(data: []const u8) ?usize {
    return std.mem.indexOf(u8, data, "\r\n\r\n") orelse std.mem.indexOf(u8, data, "\n\n");
}

fn readRequest(r: *std.Io.Reader) !Route {
    const first = try r.takeDelimiterInclusive('\n');
    return route(trimCrlf(first));
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

test "headersEnd finds the blank line with CRLF or bare LF" {
    try std.testing.expectEqual(@as(?usize, 14), headersEnd("GET / HTTP/1.1\r\n\r\n"));
    try std.testing.expectEqual(@as(?usize, 14), headersEnd("GET / HTTP/1.1\n\n"));
    try std.testing.expect(headersEnd("GET / HTTP/1.1\r\nHost: x\r\n") == null);
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
