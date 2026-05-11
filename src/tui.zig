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
    // Load tasks
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

    // Track original status for diffing
    var states = std.ArrayList(TaskState).empty;
    defer states.deinit(allocator);
    for (tasks.items) |task| {
        try states.append(allocator, .{
            .task = task,
            .original_status = task.status,
            .changed = false,
        });
    }

    // Init ncurses
    _ = c.initscr();
    defer _ = c.endwin();
    _ = c.cbreak();
    _ = c.noecho();
    _ = c.keypad(c.stdscr, true);
    _ = c.curs_set(0); // hide cursor

    var cursor: usize = 0;
    var quit = false;

    while (!quit) {
        draw(states.items, cursor);

        const ch = c.getch();
        switch (ch) {
            c.KEY_UP, 'k' => {
                if (cursor > 0) cursor -= 1;
            },
            c.KEY_DOWN, 'j' => {
                if (cursor + 1 < states.items.len) cursor += 1;
            },
            '\n', ' ' => {
                // Toggle completion
                var state = &states.items[cursor];
                const is_completed = std.mem.eql(u8, state.task.status, "completed");
                const new_status: []const u8 = if (is_completed) "needsAction" else "completed";
                allocator.free(state.task.status);
                state.task.status = try allocator.dupe(u8, new_status);
                state.changed = !std.mem.eql(u8, state.task.status, state.original_status);
            },
            'q' => quit = true,
            else => {},
        }
    }

    // Commit changes to DB
    var changed_count: usize = 0;
    for (states.items) |state| {
        if (state.changed) {
            const complete = std.mem.eql(u8, state.task.status, "completed");
            db.changeCompletionStatusNoIo(database, state.task.id, complete) catch {
                std.debug.print("Error updating task {s}.\n", .{state.task.id});
                continue;
            };
            changed_count += 1;
        }
    }

    if (changed_count > 0) {
        std.debug.print("Updated {d} task(s).\n", .{changed_count});
    }

    _ = io;
}

fn draw(states: []const TaskState, cursor: usize) void {
    _ = c.clear();

    // Header
    _ = c.attron(c.A_BOLD);
    _ = c.mvprintw(0, 0, " Todo List (j/k: move, Enter/Space: toggle, q: save & quit)");
    _ = c.attroff(c.A_BOLD);
    _ = c.mvprintw(1, 0, " ─────────────────────────────────────────────────────────");

    for (states, 0..) |state, i| {
        const row: c_int = @intCast(i + 3);
        const completed = std.mem.eql(u8, state.task.status, "completed");
        const check: [*c]const u8 = if (completed) "x" else " ";
        const modified: [*c]const u8 = if (state.changed) "*" else " ";

        if (i == cursor) {
            _ = c.attron(c.A_REVERSE);
        }

        _ = c.mvprintw(row, 0, " %s[%s] %s", modified, check, state.task.title.ptr);

        if (i == cursor) {
            _ = c.attroff(c.A_REVERSE);
        }
    }

    _ = c.refresh();
}
