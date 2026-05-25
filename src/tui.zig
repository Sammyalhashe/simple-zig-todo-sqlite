const std = @import("std");
const c = @import("c");
const db = @import("db");

// --- Types ---

/// Tracks a task's current and original status so we can detect toggles on exit.
const TaskState = struct {
    task: db.Task,
    original_status: []const u8,
    changed: bool,
};

/// Holds the TUI's runtime state so it can be passed around cleanly.
const TuiState = struct {
    cursor: usize = 0,
    scroll_offset: usize = 0,
    quit: bool = false,
    cancelled: bool = false,
    add_mode: bool = false,
    add_title: std.ArrayList(u8) = .empty,
    search_mode: bool = false,
    search_query: std.ArrayList(u8) = .empty,
    filtered_indices: std.ArrayList(usize) = .empty,
};

/// Escape key — ncurses doesn't define KEY_ESC, so we use the ASCII escape code.
const ESC = 27;

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// --- Public API ---

/// Interactive ncurses TUI for toggling task completion.
/// Commits all changes on 'q'; discards on Escape.
pub fn run(io: std.Io, database: db.AnyBackend, showAll: bool, allocator: std.mem.Allocator) !void {
    var tasks = try db.queryTasks(database, showAll, allocator);
    defer {
        for (tasks.items) |task| {
            allocator.free(task.id);
            allocator.free(task.title);
            // status ownership transfers to states on initialisation —
            // freed via the states defer below to avoid double-free on toggle.
        }
        tasks.deinit(allocator);
    }

    if (tasks.items.len == 0) {
        std.log.info("No tasks.", .{});
        return;
    }

    var states = std.ArrayList(TaskState).empty;
    defer {
        for (states.items) |state| {
            allocator.free(state.task.status);
            allocator.free(state.original_status);
        }
        states.deinit(allocator);
    }
    for (tasks.items) |task| {
        try states.append(allocator, .{
            .task = task,
            .original_status = try allocator.dupe(u8, task.status),
            .changed = false,
        });
    }

    _ = c.initscr();
    defer _ = c.endwin();
    _ = c.cbreak();
    _ = c.noecho();
    _ = c.keypad(c.stdscr, true);
    _ = c.curs_set(0);

    var ts = TuiState{};
    defer {
        ts.add_title.deinit(allocator);
        ts.search_query.deinit(allocator);
        ts.filtered_indices.deinit(allocator);
    }
    ts.filtered_indices.ensureTotalCapacity(allocator, states.items.len) catch {};
    for (0..states.items.len) |i| try ts.filtered_indices.append(allocator, i);

    while (!ts.quit) {
        draw(states.items, &ts);

        const ch = c.getch();
        if (ts.add_mode) {
            if (ch == ESC) {
                ts.add_mode = false;
                _ = c.noecho();
                ts.add_title.clearAndFree(allocator);
                ts.add_title = .empty;
            } else if (ch == '\n' or ch == '\r') {
                if (ts.add_title.items.len > 0) {
                    const title = try allocator.dupe(u8, ts.add_title.items);
                    try db.addTask(io, database, title);
                    const new_task = db.Task{
                        .id = try allocator.dupe(u8, "new"),
                        .title = title,
                        .status = try allocator.dupe(u8, "needsAction"),
                    };
                    try states.append(allocator, .{
                        .task = new_task,
                        .original_status = try allocator.dupe(u8, "needsAction"),
                        .changed = false,
                    });
                    ts.add_mode = false;
                    _ = c.noecho();
                    ts.add_title.clearAndFree(allocator);
                }
            } else if (ch == c.KEY_BACKSPACE or ch == 127 or ch == 8) {
                if (ts.add_title.items.len > 0) {
                    ts.add_title.items = ts.add_title.items[0 .. ts.add_title.items.len - 1];
                }
            } else if (ch >= 32 and ch < 127) {
                try ts.add_title.append(allocator, @intCast(ch));
            }
            draw(states.items, &ts);
        } else if (ts.search_mode) {
            if (ch == ESC) {
                ts.search_mode = false;
                _ = c.noecho();
                ts.search_query.clearAndFree(allocator);
                for (0..states.items.len) |i| ts.filtered_indices.items[i] = i;
                ts.cursor = 0;
                ts.scroll_offset = 0;
            } else if (ch == '\n' or ch == '\r') {
                ts.search_mode = false;
                _ = c.noecho();
                // Keep filter applied, cursor stays in place
            } else if (ch == c.KEY_BACKSPACE or ch == 127 or ch == 8) {
                if (ts.search_query.items.len > 0) {
                    ts.search_query.items = ts.search_query.items[0 .. ts.search_query.items.len - 1];
                    // Rebuild filtered indices
                    ts.filtered_indices.clearAndFree(allocator);
                    for (0..states.items.len) |i| {
                        if (containsIgnoreCase(states.items[i].task.title, ts.search_query.items)) {
                            try ts.filtered_indices.append(allocator, i);
                        }
                    }
                    if (ts.cursor >= ts.filtered_indices.items.len) ts.cursor = if (ts.filtered_indices.items.len > 0) ts.filtered_indices.items.len - 1 else 0;
                }
            } else if (ch >= 32 and ch < 127) {
                try ts.search_query.append(allocator, @intCast(ch));
                // Rebuild filtered indices
                ts.filtered_indices.clearAndFree(allocator);
                for (0..states.items.len) |i| {
                    if (containsIgnoreCase(states.items[i].task.title, ts.search_query.items)) {
                        try ts.filtered_indices.append(allocator, i);
                    }
                }
                if (ts.cursor >= ts.filtered_indices.items.len) ts.cursor = if (ts.filtered_indices.items.len > 0) ts.filtered_indices.items.len - 1 else 0;
            }
            draw(states.items, &ts);
        } else {
            switch (ch) {
                c.KEY_UP, 'k' => {
                    if (ts.cursor > 0) ts.cursor -= 1;
                },
                c.KEY_DOWN, 'j' => {
                    if (ts.cursor + 1 < ts.filtered_indices.items.len) ts.cursor += 1;
                },
                '\n', ' ' => {
                    const idx = ts.filtered_indices.items[ts.cursor];
                    var state = &states.items[idx];
                    const is_completed = std.mem.eql(u8, state.task.status, "completed");
                    const new_status: []const u8 = if (is_completed) "needsAction" else "completed";
                    allocator.free(state.task.status);
                    state.task.status = try allocator.dupe(u8, new_status);
                    state.changed = !std.mem.eql(u8, state.task.status, state.original_status);
                },
                'a' => {
                    ts.add_mode = true;
                    _ = c.echo();
                },
                '/' => {
                    ts.search_mode = true;
                    _ = c.echo();
                },
                'q' => ts.quit = true,
                ESC => {
                    ts.cancelled = true;
                    ts.quit = true;
                },
                else => {},
            }
        }
    }

    if (!ts.cancelled) {
        var changed_count: usize = 0;
        for (states.items) |state| {
            if (state.changed) {
                const complete = std.mem.eql(u8, state.task.status, "completed");
                db.changeCompletionStatus(io, database, state.task.id, complete) catch {
                    std.log.err("Error updating task {s}.", .{state.task.id});
                    continue;
                };
                changed_count += 1;
            }
        }

        if (changed_count > 0) {
            std.log.info("Updated {d} task(s).", .{changed_count});
        }
    }
}

// --- Rendering ---

/// Redraws the task list with scroll, cursor highlight, and change indicators.
fn draw(states: []const TaskState, ts: *TuiState) void {
    _ = c.erase();

    const max_rows: usize = @intCast(c.LINES - 3);
    const header_rows: usize = if (ts.add_mode or ts.search_mode) 4 else 3;

    // Adjust scroll to keep cursor visible
    if (ts.cursor < ts.scroll_offset) {
        ts.scroll_offset = ts.cursor;
    } else if (ts.cursor >= ts.scroll_offset + max_rows) {
        ts.scroll_offset = ts.cursor - max_rows + 1;
    }

    _ = c.attron(c.A_BOLD);
    _ = c.mvprintw(0, 0, " Todo List (j/k: move, Enter/Space: toggle, a: add, /:search, q: save & quit, Esc: cancel)");
    _ = c.attroff(c.A_BOLD);
    _ = c.mvprintw(1, 0, "-----------------------------------------------------------");

    if (ts.add_mode) {
        _ = c.mvprintw(2, 0, " Enter task title (Enter to confirm, Esc to cancel): ");
        _ = c.addnstr(ts.add_title.items.ptr, @intCast(ts.add_title.items.len));
    } else if (ts.search_mode) {
        _ = c.mvprintw(2, 0, " Search (Enter to apply, Esc to cancel): ");
        _ = c.addnstr(ts.search_query.items.ptr, @intCast(ts.search_query.items.len));
    }

    const filtered = ts.filtered_indices.items;
    const end = @min(ts.scroll_offset + max_rows, filtered.len);
    for (filtered[ts.scroll_offset..end], 0..) |task_idx, i| {
        const row: c_int = @intCast(i + header_rows);
        const actual_idx = ts.scroll_offset + i;
        const state = &states[task_idx];
        const completed = std.mem.eql(u8, state.task.status, "completed");
        const check: [*c]const u8 = if (completed) "x" else " ";
        const modified: [*c]const u8 = if (state.changed) "*" else " ";

        if (actual_idx == ts.cursor) {
            _ = c.attron(c.A_REVERSE);
        }

        _ = c.mvprintw(row, 0, " %s[%s] ", modified, check);
        // Use addnstr for safe non-null-terminated string output
        _ = c.addnstr(state.task.title.ptr, @intCast(state.task.title.len));

        if (actual_idx == ts.cursor) {
            _ = c.attroff(c.A_REVERSE);
        }
    }

    _ = c.refresh();
}
