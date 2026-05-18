const std = @import("std");

// --- Types ---

/// A task with string fields suitable for display and JSON serialization.
pub const Task = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
};

// --- Escaping ---

/// Appends a JSON-escaped version of `s` to `list`, using `alloc` for growth.
/// Escapes double-quote, backslash, newline, tab, and control chars below 0x20.
pub fn appendEscaped(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => {
                if (ch < 0x20) {
                    var buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable;
                    try list.appendSlice(alloc, hex);
                } else {
                    try list.append(alloc, ch);
                }
            },
        }
    }
}

/// Writes a JSON-escaped string to any writer type (std.Io.Writer, fixedBufferStream, etc.).
pub fn writeJsonEscaped(w: anytype, s: []const u8) @TypeOf(w).Error!void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.print("{c}", .{ch});
                }
            },
        }
    }
}

// --- Extraction ---

/// Extracts the string value for a given key from a JSON object (linear scan).
/// Does not handle nested objects or arrays — only top-level "key":"value" pairs.
pub fn extractJsonString(json_data: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 4 < json_data.len) : (i += 1) {
        if (json_data[i] == '"' and i + 1 + key.len < json_data.len and
            std.mem.eql(u8, json_data[i + 1 .. i + 1 + key.len], key) and
            json_data[i + 1 + key.len] == '"')
        {
            // Found key, now find value after :"
            var j = i + 1 + key.len + 1; // past closing quote
            // Skip : and whitespace
            while (j < json_data.len and (json_data[j] == ':' or json_data[j] == ' ')) : (j += 1) {}
            if (j < json_data.len and json_data[j] == '"') {
                j += 1; // past opening quote of value
                const start = j;
                while (j < json_data.len) : (j += 1) {
                    if (json_data[j] == '\\') {
                        j += 1;
                        continue;
                    }
                    if (json_data[j] == '"') break;
                }
                return json_data[start..j];
            }
        }
    }
    return null;
}

/// Extracts a boolean value for a given key from a JSON object (linear scan).
pub fn extractJsonBool(json_data: []const u8, key: []const u8) ?bool {
    var i: usize = 0;
    while (i + key.len + 4 < json_data.len) : (i += 1) {
        if (json_data[i] == '"' and i + 1 + key.len < json_data.len and
            std.mem.eql(u8, json_data[i + 1 .. i + 1 + key.len], key) and
            json_data[i + 1 + key.len] == '"')
        {
            var j = i + 1 + key.len + 1;
            while (j < json_data.len and (json_data[j] == ':' or json_data[j] == ' ')) : (j += 1) {}
            if (j + 4 <= json_data.len and std.mem.eql(u8, json_data[j .. j + 4], "true")) return true;
            if (j + 5 <= json_data.len and std.mem.eql(u8, json_data[j .. j + 5], "false")) return false;
        }
    }
    return null;
}

// --- Serialization ---

/// Serializes a slice of Tasks into a JSON array string (newline-terminated).
/// Caller owns the returned memory and must free it with `alloc`.
pub fn serializeTasksJson(tasks: []const Task, alloc: std.mem.Allocator) ![]const u8 {
    var resp = std.ArrayList(u8).empty;
    defer resp.deinit(alloc);
    try resp.appendSlice(alloc, "[");
    for (tasks, 0..) |task, i| {
        if (i > 0) try resp.appendSlice(alloc, ",");
        try resp.appendSlice(alloc, "{\"id\":\"");
        try appendEscaped(&resp, alloc, task.id);
        try resp.appendSlice(alloc, "\",\"title\":\"");
        try appendEscaped(&resp, alloc, task.title);
        try resp.appendSlice(alloc, "\",\"status\":\"");
        try appendEscaped(&resp, alloc, task.status);
        try resp.appendSlice(alloc, "\"}");
    }
    try resp.appendSlice(alloc, "]\n");
    return try alloc.dupe(u8, resp.items);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// -- extractJsonString tests -----------------------------------------------

test "extractJsonString: happy path" {
    const result = extractJsonString("{\"method\":\"listTasks\"}", "method");
    try std.testing.expectEqualStrings("listTasks", result.?);
}

test "extractJsonString: find second key" {
    const json = "{\"method\":\"add\",\"title\":\"buy milk\"}";
    const result = extractJsonString(json, "title");
    try std.testing.expectEqualStrings("buy milk", result.?);
}

test "extractJsonString: key not found returns null" {
    const result = extractJsonString("{\"method\":\"listTasks\"}", "missing");
    try std.testing.expect(result == null);
}

test "extractJsonString: empty input returns null" {
    try std.testing.expect(extractJsonString("", "method") == null);
}

test "extractJsonString: empty value" {
    const result = extractJsonString("{\"method\":\"\"}", "method");
    try std.testing.expectEqualStrings("", result.?);
}

test "extractJsonString: whitespace before value" {
    const result = extractJsonString("{\"method\" : \"listTasks\"}", "method");
    try std.testing.expectEqualStrings("listTasks", result.?);
}

test "extractJsonString: partial key collision — methodical vs method" {
    const result = extractJsonString("{\"methodical\":\"yes\"}", "method");
    try std.testing.expect(result == null);
}

test "extractJsonString: single-char key" {
    const result = extractJsonString("{\"k\":\"v\"}", "k");
    try std.testing.expectEqualStrings("v", result.?);
}

test "extractJsonString: truncated input" {
    try std.testing.expect(extractJsonString("{", "method") == null);
}

test "extractJsonString: handles escaped quotes" {
    const input =
        \\{"title":"say \"hello\"","status":"needsAction"}
    ;
    const result = extractJsonString(input, "title");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("say \\\"hello\\\"", result.?);
}

// -- extractJsonBool tests -------------------------------------------------

test "extractJsonBool: true value" {
    const result = extractJsonBool("{\"done\":true}", "done");
    try std.testing.expect(result.? == true);
}

test "extractJsonBool: false value" {
    const result = extractJsonBool("{\"done\":false}", "done");
    try std.testing.expect(result.? == false);
}

test "extractJsonBool: key not found returns null" {
    try std.testing.expect(extractJsonBool("{\"done\":true}", "missing") == null);
}

test "extractJsonBool: whitespace before value" {
    const result = extractJsonBool("{\"done\" : true}", "done");
    try std.testing.expect(result.? == true);
}

test "extractJsonBool: case sensitive — TRUE not recognized" {
    try std.testing.expect(extractJsonBool("{\"done\":TRUE}", "done") == null);
}

test "extractJsonBool: empty input returns null" {
    try std.testing.expect(extractJsonBool("", "done") == null);
}

// -- appendEscaped tests ---------------------------------------------------

test "appendEscaped: plain text passes through" {
    const alloc = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    try appendEscaped(&list, alloc, "hello world");
    try std.testing.expectEqualStrings("hello world", list.items);
}

test "appendEscaped: empty string produces empty output" {
    const alloc = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    try appendEscaped(&list, alloc, "");
    try std.testing.expect(list.items.len == 0);
}

test "appendEscaped: double-quote escaping" {
    const alloc = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    try appendEscaped(&list, alloc, "say \"hi\"");
    try std.testing.expectEqualStrings("say \\\"hi\\\"", list.items);
}

test "appendEscaped: backslash escaping" {
    const alloc = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    try appendEscaped(&list, alloc, "a\\b");
    try std.testing.expectEqualStrings("a\\\\b", list.items);
}

test "appendEscaped: newline escaping" {
    const alloc = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    try appendEscaped(&list, alloc, "line1\nline2");
    try std.testing.expectEqualStrings("line1\\nline2", list.items);
}

test "appendEscaped: tab escaping" {
    const alloc = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    try appendEscaped(&list, alloc, "col1\tcol2");
    try std.testing.expectEqualStrings("col1\\tcol2", list.items);
}

test "appendEscaped: control char < 0x20 produces \\uXXXX" {
    const alloc = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    try appendEscaped(&list, alloc, "\x01");
    try std.testing.expectEqualStrings("\\u0001", list.items);
}

// -- writeJsonEscaped tests ------------------------------------------------

/// A test-only writer that satisfies the @TypeOf(w).Error pattern.
/// Methods take self by value (const), so the struct can be passed as `anytype`
/// without Zig's const-autoref conflict on *Self methods.
/// State mutation goes through the pos pointer.
const TestBufWriter = struct {
    pub const Error = error{NoSpaceLeft};
    buf: []u8,
    pos: *usize,

    pub fn writeAll(self: TestBufWriter, bytes: []const u8) Error!void {
        const end = self.pos.* + bytes.len;
        if (end > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos.*..end], bytes);
        self.pos.* = end;
    }

    pub fn print(self: TestBufWriter, comptime fmt: []const u8, args: anytype) Error!void {
        const output = std.fmt.bufPrint(self.buf[self.pos.*..], fmt, args) catch return error.NoSpaceLeft;
        self.pos.* += output.len;
    }

    pub fn getWritten(self: TestBufWriter) []const u8 {
        return self.buf[0..self.pos.*];
    }
};

test "writeJsonEscaped: plain text" {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    const tw = TestBufWriter{ .buf = &buf, .pos = &pos };
    try writeJsonEscaped(tw, "hello");
    try std.testing.expectEqualStrings("hello", tw.getWritten());
}

test "writeJsonEscaped: double-quote escaping" {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    const tw = TestBufWriter{ .buf = &buf, .pos = &pos };
    try writeJsonEscaped(tw, "say \"hi\"");
    try std.testing.expectEqualStrings("say \\\"hi\\\"", tw.getWritten());
}

test "writeJsonEscaped: backslash escaping" {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    const tw = TestBufWriter{ .buf = &buf, .pos = &pos };
    try writeJsonEscaped(tw, "a\\b");
    try std.testing.expectEqualStrings("a\\\\b", tw.getWritten());
}

test "writeJsonEscaped: newline escaping" {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    const tw = TestBufWriter{ .buf = &buf, .pos = &pos };
    try writeJsonEscaped(tw, "line1\nline2");
    try std.testing.expectEqualStrings("line1\\nline2", tw.getWritten());
}

test "writeJsonEscaped: tab escaping" {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    const tw = TestBufWriter{ .buf = &buf, .pos = &pos };
    try writeJsonEscaped(tw, "col1\tcol2");
    try std.testing.expectEqualStrings("col1\\tcol2", tw.getWritten());
}

test "writeJsonEscaped: control char \\x01 produces \\u0001" {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    const tw = TestBufWriter{ .buf = &buf, .pos = &pos };
    try writeJsonEscaped(tw, "\x01");
    try std.testing.expectEqualStrings("\\u0001", tw.getWritten());
}

// -- serializeTasksJson tests ----------------------------------------------

test "serializeTasksJson: empty slice" {
    const alloc = std.testing.allocator;
    const result = try serializeTasksJson(&[_]Task{}, alloc);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[]\n", result);
}

test "serializeTasksJson: single task" {
    const alloc = std.testing.allocator;
    const tasks = [_]Task{
        .{ .id = "1", .title = "buy milk", .status = "pending" },
    };
    const result = try serializeTasksJson(&tasks, alloc);
    defer alloc.free(result);
    try std.testing.expectEqualStrings(
        "[{\"id\":\"1\",\"title\":\"buy milk\",\"status\":\"pending\"}]\n",
        result,
    );
}

test "serializeTasksJson: multiple tasks" {
    const alloc = std.testing.allocator;
    const tasks = [_]Task{
        .{ .id = "1", .title = "buy milk", .status = "pending" },
        .{ .id = "2", .title = "walk dog", .status = "done" },
    };
    const result = try serializeTasksJson(&tasks, alloc);
    defer alloc.free(result);
    try std.testing.expectEqualStrings(
        "[{\"id\":\"1\",\"title\":\"buy milk\",\"status\":\"pending\"},{\"id\":\"2\",\"title\":\"walk dog\",\"status\":\"done\"}]\n",
        result,
    );
}

test "serializeTasksJson: special chars in title" {
    const alloc = std.testing.allocator;
    const tasks = [_]Task{
        .{ .id = "1", .title = "say \"hi\" \\ bye", .status = "pending" },
    };
    const result = try serializeTasksJson(&tasks, alloc);
    defer alloc.free(result);
    try std.testing.expectEqualStrings(
        "[{\"id\":\"1\",\"title\":\"say \\\"hi\\\" \\\\ bye\",\"status\":\"pending\"}]\n",
        result,
    );
}
