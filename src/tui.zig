const std = @import("std");
const c = @import("c");
const db = @import("db");

const allocator = std.heap.page_allocator;

const TaskState = struct {
    task: db.Task,
    original_status: []const u8,
    changed: bool,
};

pub fn run(io: std.Io, database: db.Db, showAll: bool) !void {
    std.debug.print("INTERACTIVE::run", .{});
    var tasks = try db.queryTasks(database, showAll, allocator);
    defer {
        for (tasks.items) |task| {
            allocator.free(task.id);
            allocator.free(task.title);
            allocator.free(task.status);
        }
        tasks.deinit(allocator);
    }

    if (tasks.items.len == 0) {
        std.debug.print("No tasks.\n", .{});
        return;
    }

    var states = std.ArrayList(TaskState).empty;
    defer states.deinit(allocator);
    for (tasks.items) |task| {
        try states.append(allocator, .{
            .task = task,
            .original_status = task.status,
            .changed = false,
        });
    }

    _ = c.initscr();
    defer _ = c.endwin();
    _ = c.cbreak();
    _ = c.noecho();
    _ = c.keypad(c.stdscr, true);
    _ = c.curs_set(0);

    var cursor: usize = 0;
    var scroll_offset: usize = 0;
    var quit = false;
    var cancelled = false;

    while (!quit) {
        draw(states.items, cursor, &scroll_offset);

        const ch = c.getch();
        switch (ch) {
            c.KEY_UP, 'k' => {
                if (cursor > 0) cursor -= 1;
            },
            c.KEY_DOWN, 'j' => {
                if (cursor + 1 < states.items.len) cursor += 1;
            },
            '\n', ' ' => {
                var state = &states.items[cursor];
                const is_completed = std.mem.eql(u8, state.task.status, "completed");
                const new_status: []const u8 = if (is_completed) "needsAction" else "completed";
                allocator.free(state.task.status);
                state.task.status = try allocator.dupe(u8, new_status);
                state.changed = !std.mem.eql(u8, state.task.status, state.original_status);
            },
            'q' => quit = true,
            27 => {
                cancelled = true;
                quit = true;
            },
            else => {},
        }
    }

    if (!cancelled) {
        var changed_count: usize = 0;
        for (states.items) |state| {
            if (state.changed) {
                const complete = std.mem.eql(u8, state.task.status, "completed");
                db.changeCompletionStatus(io, database, state.task.id, complete) catch {
                    std.debug.print("Error updating task {s}.\n", .{state.task.id});
                    continue;
                };
                changed_count += 1;
            }
        }

        if (changed_count > 0) {
            std.debug.print("Updated {d} task(s).\n", .{changed_count});
        }
    }

}

fn draw(states: []const TaskState, cursor: usize, scroll_offset: *usize) void {
    _ = c.erase();

    const max_rows: usize = @intCast(c.LINES - 3);

    // Adjust scroll to keep cursor visible
    if (cursor < scroll_offset.*) {
        scroll_offset.* = cursor;
    } else if (cursor >= scroll_offset.* + max_rows) {
        scroll_offset.* = cursor - max_rows + 1;
    }

    _ = c.attron(c.A_BOLD);
    _ = c.mvprintw(0, 0, " Todo List (j/k: move, Enter/Space: toggle, q: save & quit, Esc: cancel)");
    _ = c.attroff(c.A_BOLD);
    _ = c.mvprintw(1, 0, "-----------------------------------------------------------");

    const end = @min(scroll_offset.* + max_rows, states.len);
    for (states[scroll_offset.*..end], 0..) |state, i| {
        const row: c_int = @intCast(i + 3);
        const actual_idx = scroll_offset.* + i;
        const completed = std.mem.eql(u8, state.task.status, "completed");
        const check: [*c]const u8 = if (completed) "x" else " ";
        const modified: [*c]const u8 = if (state.changed) "*" else " ";

        if (actual_idx == cursor) {
            _ = c.attron(c.A_REVERSE);
        }

        _ = c.mvprintw(row, 0, " %s[%s] ", modified, check);
        // Use addnstr for safe non-null-terminated string output
        _ = c.addnstr(state.task.title.ptr, @intCast(state.task.title.len));

        if (actual_idx == cursor) {
            _ = c.attroff(c.A_REVERSE);
        }
    }

    _ = c.refresh();
}
