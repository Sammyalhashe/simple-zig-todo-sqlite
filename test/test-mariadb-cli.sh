#!/usr/bin/env bash
set -euo pipefail

# Integration test for the `todo` CLI against a real MariaDB backend.
# Invoked by test/test-mariadb.sh which provides TEST_MARIADB_* env vars.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."
TODO_BIN="$PROJECT_ROOT/zig-out/bin/todo"
WORKDIR=$(mktemp -d /tmp/todo-cli-test.XXXXXX)

# Export env vars so createDatabase skips SSH tunnel
export TODO_MARIADB_PORT="$TEST_MARIADB_PORT"
export TODO_MARIADB_HOST="$TEST_MARIADB_HOST"

TODO_REMOTE="-r $TEST_MARIADB_HOST"

PASSED=0
FAILED=0

# --- Helpers ---

reset_remote() {
    mariadb --socket="$TEST_MARIADB_SOCKET" -N -e \
        "DELETE FROM supernotedb.t_schedule_task WHERE title LIKE 'test-cli-%'"
}

cleanup() {
    reset_remote 2>/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

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

query_count() {
    local sql="$1"
    mariadb --socket="$TEST_MARIADB_SOCKET" -N -e "$sql"
}

assert_db_count() {
    local label="$1"
    local sql="$2"
    local expected="$3"
    local actual
    actual=$(query_count "$sql")
    if [[ "$actual" -eq "$expected" ]]; then
        echo "PASS: $label"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL: $label"
        echo "  expected count: $expected"
        echo "  got: $actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_db_value() {
    local label="$1"
    local sql="$2"
    local expected="$3"
    local actual
    actual=$(query_count "$sql")
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS: $label"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL: $label"
        echo "  expected: $expected"
        echo "  got: $actual"
        FAILED=$((FAILED + 1))
    fi
}

# --- Preflight ---

if [[ ! -x "$TODO_BIN" ]]; then
    echo "ERROR: todo binary not found at $TODO_BIN"
    echo "Run 'zig build' first."
    exit 1
fi

echo "=== MariaDB CLI Integration Test ==="
echo "  Binary:  $TODO_BIN"
echo "  Workdir: $WORKDIR"
echo "  Host:    $TEST_MARIADB_HOST"
echo "  Port:    $TEST_MARIADB_PORT"
echo ""

reset_remote

# --- Test 1: add task to remote ---

echo "--- Test 1: add task to remote ---"
# shellcheck disable=SC2086
OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" $TODO_REMOTE add "test-cli-task-1" 2>&1) || true
assert_contains "add output contains 'Task added.'" "$OUTPUT" "Task added."
assert_db_count "row exists in MariaDB after add" \
    "SELECT COUNT(*) FROM supernotedb.t_schedule_task WHERE title = 'test-cli-task-1'" \
    1

# --- Test 2: list tasks from remote ---

echo ""
echo "--- Test 2: list tasks from remote ---"
# shellcheck disable=SC2086
OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" $TODO_REMOTE list 2>&1) || true
assert_contains "list output contains 'test-cli-task-1'" "$OUTPUT" "test-cli-task-1"

# --- Test 3: list --json from remote ---

echo ""
echo "--- Test 3: list --json from remote ---"
# shellcheck disable=SC2086
OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" $TODO_REMOTE list --json 2>&1) || true
# Valid JSON starts with '[' or '{' — just check it contains the task title
assert_contains "list --json contains 'test-cli-task-1'" "$OUTPUT" "test-cli-task-1"

# --- Test 4: complete a task on remote ---

echo ""
echo "--- Test 4: complete a task on remote ---"
TASK_ID=$(mariadb --socket="$TEST_MARIADB_SOCKET" -N -e \
    "SELECT task_id FROM supernotedb.t_schedule_task WHERE title = 'test-cli-task-1' LIMIT 1")
if [[ -z "$TASK_ID" ]]; then
    echo "FAIL: could not retrieve task_id for test-cli-task-1"
    FAILED=$((FAILED + 1))
else
    # shellcheck disable=SC2086
    OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" $TODO_REMOTE complete "$TASK_ID" 2>&1) || true
    assert_contains "complete output contains 'marked as completed'" "$OUTPUT" "marked as completed"
    assert_db_value "MariaDB row has status = 'completed'" \
        "SELECT status FROM supernotedb.t_schedule_task WHERE task_id = '$TASK_ID'" \
        "completed"
fi

# --- Test 5: completed task hidden from default list ---

echo ""
echo "--- Test 5: completed task hidden from default list ---"
# shellcheck disable=SC2086
OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" $TODO_REMOTE list 2>&1) || true
assert_not_contains "test-cli-task-1 NOT in default list" "$OUTPUT" "test-cli-task-1"

# --- Test 6: completed task visible with --all ---

echo ""
echo "--- Test 6: completed task visible with --all ---"
# shellcheck disable=SC2086
OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" $TODO_REMOTE list --all 2>&1) || true
assert_contains "test-cli-task-1 IS in list --all" "$OUTPUT" "test-cli-task-1"

# --- Test 7: incomplete a task on remote ---

echo ""
echo "--- Test 7: incomplete a task on remote ---"
if [[ -n "${TASK_ID:-}" ]]; then
    # shellcheck disable=SC2086
    OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" $TODO_REMOTE incomplete "$TASK_ID" 2>&1) || true
    assert_contains "incomplete output contains 'marked as incomplete'" "$OUTPUT" "marked as incomplete"
    assert_db_value "MariaDB row has status = 'needsAction'" \
        "SELECT status FROM supernotedb.t_schedule_task WHERE task_id = '$TASK_ID'" \
        "needsAction"
else
    echo "SKIP: Test 7 skipped (no TASK_ID from Test 4)"
    FAILED=$((FAILED + 1))
fi

# --- Test 8: add multiple tasks and list all ---

echo ""
echo "--- Test 8: add multiple tasks and list all ---"
# shellcheck disable=SC2086
(cd "$WORKDIR" && "$TODO_BIN" $TODO_REMOTE add "test-cli-task-2" 2>&1) || true
# shellcheck disable=SC2086
(cd "$WORKDIR" && "$TODO_BIN" $TODO_REMOTE add "test-cli-task-3" 2>&1) || true
# shellcheck disable=SC2086
OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" $TODO_REMOTE list 2>&1) || true
assert_contains "list shows test-cli-task-1 (back to needsAction)" "$OUTPUT" "test-cli-task-1"
assert_contains "list shows test-cli-task-2" "$OUTPUT" "test-cli-task-2"
assert_contains "list shows test-cli-task-3" "$OUTPUT" "test-cli-task-3"

# --- Test 9: complete nonexistent task ---

echo ""
echo "--- Test 9: complete nonexistent task ---"
# shellcheck disable=SC2086
OUTPUT=$(cd "$WORKDIR" && "$TODO_BIN" $TODO_REMOTE complete "nonexistent-id-xyz" 2>&1) || true
assert_contains "error message for nonexistent task" "$OUTPUT" "no task found"

# --- Summary ---

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if (( FAILED > 0 )); then
    exit 1
fi
