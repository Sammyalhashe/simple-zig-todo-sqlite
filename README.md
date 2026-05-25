# Simple Zig Todo CLI with SQLite

A tiny command‑line todo manager written in Zig (0.16.0) with three backends: SQLite (local), MariaDB (remote), and Jj (JSON-lines file).

## Features

* `todo add "task description"` – Add a new task
* `todo list` – List all tasks (showing completed status)
* `todo complete <id>` – Mark a task as completed
* `todo incomplete <id>` – Mark a task as incomplete
* `todo delete <id>` – Soft-delete a task
* `todo interactive` – Interactive ncurses TUI mode
* `todo sync` – Sync local SQLite to remote MariaDB
* `todo serve` – Start JSON-RPC daemon on Unix socket

## Prerequisites

* Zig (0.16.0)
* SQLite, MariaDB client, ncurses (system libraries)
* Jujutsu (jj) for version control

## Building

From the repository root:

```bash
zig build -Doptimize=ReleaseSafe
```

The binary will be placed in `zig-out/bin/todo`.

## Running

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

**TUI mode:**
```bash
./zig-out/bin/todo interactive
```

**Remote MariaDB:**
```bash
zig build run -r=<host> -p=<password> -- <subcommand>
```

**Jj backend (JSON-lines file):**
```bash
./zig-out/bin/todo -g=<path> add "task"
./zig-out/bin/todo -g=<path> list
```

## Nix

A Nix flake (`flake.nix`) provides a dev shell with all dependencies. Enter with `nix develop`.

## VCS

This repo uses **jj (jujutsu)**. Always use `jj` commands, never `git` directly.

## Testing

```bash
zig build test              # unit tests
./test/test-mariadb.sh zig build integration-test  # integration tests
./test/test-sync.sh         # sync tests
```
