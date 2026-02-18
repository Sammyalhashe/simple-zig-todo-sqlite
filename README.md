# Simple Zig Todo CLI with SQLite

A tiny command‑line todo manager written in Zig that stores its data in a local SQLite database (`todo.db`).

## Features

* `todo add "task description"` – Add a new task
* `todo list` – List all tasks (showing completed status)
* `todo complete <id>` – Mark a task as completed

## Prerequisites

* Zig (0.11.0 or newer)
* SQLite (system library)

## Building

From the repository root:

```bash
cd simple-zig-todo-sqlite
zig build -Doptimize=ReleaseSafe
```

The binary will be placed in `zig-out/bin/todo`.

## Usage

**Add a task:**
```bash
./zig-out/bin/todo add "Buy milk"
```

**List tasks:**
```bash
./zig-out/bin/todo list
```

**Complete a task:**
```bash
./zig-out/bin/todo complete 1
```
