#!/usr/bin/env bash
set -euo pipefail

# Integration test for the `todo sync` command.
# Invoked by test/test-mariadb.sh which provides TEST_MARIADB_* env vars.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."
TODO_BIN="$PROJECT_ROOT/zig-out/bin/todo"
WORKDIR=$(mktemp -d /tmp/todo-sync-test.XXXXXX)

# Export env vars so runSync skips SSH tunnel
export TODO_MARIADB_PORT="$TEST_MARIADB_PORT"
export TODO_MARIADB_HOST="$TEST_MARIADB_HOST"

PASSED=0
FAILED=0

cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- Preflight ---

if [[ ! -x "$TODO_BIN" ]]; then
    echo "ERROR: todo binary not found at $TODO_BIN"
    echo "Run 'zig build' first."
    exit 1
fi

echo "=== Sync Command Integration Test ==="
echo "  Binary:  $TODO_BIN"
echo "  Workdir: $WORKDIR"
echo ""

# --- Helpers ---

assert_contains() {
    local label="$1"
    local response="$2"
    local expected="$3"
    if echo "$response" | grep -qF "$expected"; then
        echo "PASS: $label"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL: $label"
        echo "  expected to contain: $expected"
        echo "  got: $response"
        FAILED=$((FAILED + 1))
    fi
}

assert_not_contains() {
    local label="$1"
    local response="$2"
    local unexpected="$3"
    if echo "$response" | grep -qF "$unexpected"; then
        echo "FAIL: $label"
        echo "  expected NOT to contain: $unexpected"
        echo "  got: $response"
        FAILED=$((FAILED + 1))
    else
        echo "PASS: $label"
        PASSED=$((PASSED + 1))
    fi
}

# Helper to clean both databases
reset_dbs() {
    # Delete test rows from MariaDB
    mariadb --socket="$TEST_MARIADB_SOCKET" -N -e "DELETE FROM supernotedb.t_schedule_task WHERE title LIKE 'test-sync-%'"
    # Remove and recreate local SQLite
    rm -f "$WORKDIR/todo.db"
}

# Helper to add tasks to remote via SQL
add_remote_task() {
    local task_id="$1" title="$2"
    mariadb --socket="$TEST_MARIADB_SOCKET" -N -e "INSERT INTO supernotedb.t_schedule_task (task_id, title, status, last_modified, is_deleted, user_id, due_time) VALUES ('$task_id', '$title', 'needsAction', ROUND(UNIX_TIMESTAMP(NOW(3)) * 1000), 'N', 0, 0)"
}

# Helper to query remote tasks
query_remote() {
    mariadb --socket="$TEST_MARIADB_SOCKET" -N -e "SELECT title FROM supernotedb.t_schedule_task WHERE title LIKE 'test-sync-%' ORDER BY title"
}

# Helper to query local tasks
query_local() {
    sqlite3 "$WORKDIR/todo.db" "SELECT title FROM tasks WHERE title LIKE 'test-sync-%' AND is_deleted != 'Y' ORDER BY title"
}

# Helper to add a local task via the CLI
add_local_task() {
    local title="$1"
    (cd "$WORKDIR" && "$TODO_BIN" -b sqlite add "$title")
}

# --- Test 1: dry-run push ---

echo "--- Test 1: dry-run push ---"
reset_dbs
add_local_task "test-sync-local-1"
add_remote_task "remote-1" "test-sync-remote-1"

OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" -r 127.0.0.1 sync push --dry-run 2>&1) || true
assert_contains "dry-run output contains [dry-run]" "$OUTPUT" "[dry-run]"

REMOTE_TASKS=$(query_remote)
assert_contains "remote still has test-sync-remote-1" "$REMOTE_TASKS" "test-sync-remote-1"
assert_not_contains "remote does NOT have test-sync-local-1 (dry-run)" "$REMOTE_TASKS" "test-sync-local-1"

# --- Test 2: push ---

echo ""
echo "--- Test 2: push ---"
reset_dbs
add_local_task "test-sync-local-1"
add_remote_task "remote-1" "test-sync-remote-1"

OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" -r 127.0.0.1 sync push 2>&1) || true

REMOTE_TASKS=$(query_remote)
assert_contains "remote has test-sync-local-1 after push" "$REMOTE_TASKS" "test-sync-local-1"
assert_contains "remote still has test-sync-remote-1" "$REMOTE_TASKS" "test-sync-remote-1"

LOCAL_TASKS=$(query_local)
assert_not_contains "local does NOT have test-sync-remote-1 (push only)" "$LOCAL_TASKS" "test-sync-remote-1"

# --- Test 3: pull ---

echo ""
echo "--- Test 3: pull ---"
reset_dbs
add_local_task "test-sync-local-2"
add_remote_task "remote-2" "test-sync-remote-2"

OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" -r 127.0.0.1 sync pull 2>&1) || true

LOCAL_TASKS=$(query_local)
assert_contains "local has test-sync-local-2 after pull" "$LOCAL_TASKS" "test-sync-local-2"
assert_contains "local has test-sync-remote-2 after pull" "$LOCAL_TASKS" "test-sync-remote-2"

REMOTE_TASKS=$(query_remote)
assert_not_contains "remote does NOT have test-sync-local-2 (pull only)" "$REMOTE_TASKS" "test-sync-local-2"

# --- Test 4: both ---

echo ""
echo "--- Test 4: both ---"
reset_dbs
add_local_task "test-sync-local-3"
add_remote_task "remote-3" "test-sync-remote-3"

OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" -r 127.0.0.1 sync both 2>&1) || true

LOCAL_TASKS=$(query_local)
assert_contains "local has test-sync-local-3 after both" "$LOCAL_TASKS" "test-sync-local-3"
assert_contains "local has test-sync-remote-3 after both" "$LOCAL_TASKS" "test-sync-remote-3"

REMOTE_TASKS=$(query_remote)
assert_contains "remote has test-sync-local-3 after both" "$REMOTE_TASKS" "test-sync-local-3"
assert_contains "remote has test-sync-remote-3 after both" "$REMOTE_TASKS" "test-sync-remote-3"

# --- Test 5: idempotent re-sync ---

echo ""
echo "--- Test 5: idempotent re-sync ---"
# Don't reset — run sync both again on the same data
OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" -r 127.0.0.1 sync both 2>&1) || true
assert_contains "re-sync shows 0 created" "$OUTPUT" "+0 local, +0 remote"
assert_contains "re-sync shows 0 updated" "$OUTPUT" "~0 updated local, ~0 updated remote"

# --- Summary ---

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if (( FAILED > 0 )); then
    exit 1
fi
