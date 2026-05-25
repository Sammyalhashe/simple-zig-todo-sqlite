# Simple Zig Todo CLI

A command-line todo manager written in Zig (0.16.0) with three backends: SQLite (local), MariaDB (remote), and Jj (JSON-lines file). Supports sync between backends, a ncurses TUI, and a JSON-RPC server.

## Building

```bash
zig build -Doptimize=ReleaseSafe
```

Binary is placed in `zig-out/bin/todo`.

## Running

```bash
./zig-out/bin/todo add "Buy milk"
./zig-out/bin/todo list
./zig-out/bin/todo complete 1
./zig-out/bin/todo delete 1
./zig-out/bin/todo incomplete 1
./zig-out/bin/todo interactive    # TUI mode
./zig-out/bin/todo sync           # sync local SQLite to remote MariaDB
./zig-out/bin/todo serve          # start JSON-RPC daemon
```

Remote MariaDB: `zig build run -r=<host> -p=<password> -- <subcommand>`
Jj backend: `./zig-out/bin/todo -g=<path> <subcommand>`

## Nix

This project ships a Nix flake (`flake.nix`) providing a dev shell with Zig 0.16.0, SQLite, MariaDB client, ncurses, and jj. Enter with `nix develop`. The `result` symlink points to the last successful `zig build` artifact.

## VCS

This repo uses **jj (jujutsu)**, not Git. Standard workflow:

```bash
jj git fetch
jj rebase -d master@origin
jj new
jj describe -m "message"
jj bookmark set master -r @
jj git push
```

Never use `git` directly — always use `jj`.

## Testing

**Unit tests** (no external deps):
```bash
zig build test
```

**Integration tests** (require MariaDB):
```bash
./test/test-mariadb.sh zig build integration-test
./test/test-sync.sh
./test/test-serve.sh
```

**Standard**: After every large change, both unit tests and integration tests must pass before committing.

## Architecture

```
c (C interop)    json (parsing/serialization)
  \                 |
   \----+-----+
        |
       db (AnyBackend union: sqlite, mariadb, jj)
     /  |  \
server sync tui
    \   |   /
    main (CLI entrypoint)
```

- `db.zig`: `AnyBackend` union dispatches to the correct backend's methods.
- Backends: `sqlite.zig` (integer `id` + `remote_task_id`), `mariadb.zig` (UUID `task_id`), `jj.zig` (UUID `id`, JSON-lines).
- Sync uses `remote_id` matching + title fallback, `last_modified` timestamps for conflict resolution.
- Soft delete via `is_deleted` flag — deleted tasks are hidden by default and synced across backends.
