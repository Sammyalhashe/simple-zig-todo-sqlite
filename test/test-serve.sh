#!/usr/bin/env bash
set -euo pipefail

# Integration test for the JSON-RPC serve command.
# Requires: socat (available in devShell), the todo binary already built.
# No MariaDB needed -- uses local SQLite only.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."
TODO_BIN="$PROJECT_ROOT/zig-out/bin/todo"
SOCKET_PATH="/tmp/todo.sock"

# --- Preflight ---

if [[ ! -x "$TODO_BIN" ]]; then
    echo "ERROR: todo binary not found at $TODO_BIN"
    echo "Run 'zig build' first."
    exit 1
fi

if ! command -v socat &>/dev/null; then
    echo "ERROR: socat not found. Run inside the devShell (nix develop)."
    exit 1
fi

# --- Setup ---

# Work in a temp directory so todo.db is isolated
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/todo-serve-test.XXXXXX")

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET_PATH"
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "=== Serve Command Integration Test ==="
echo "  Binary:  $TODO_BIN"
echo "  Socket:  $SOCKET_PATH"
echo "  Workdir: $WORKDIR"
echo ""

# Remove stale socket
rm -f "$SOCKET_PATH"

# --- Start server ---

cd "$WORKDIR"
"$TODO_BIN" -b sqlite serve &
SERVER_PID=$!

# Wait for socket to appear (max 5 seconds)
SECONDS=0
while [[ ! -S "$SOCKET_PATH" ]]; do
    if (( SECONDS >= 5 )); then
        echo "FAIL: Server did not create socket within 5 seconds"
        exit 1
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "FAIL: Server process died before creating socket"
        exit 1
    fi
    sleep 0.1
done
echo "Server ready (PID $SERVER_PID, took ${SECONDS}s)"
echo ""

# --- Helper: send a JSON-RPC request, return response ---

send_request() {
    local request="$1"
    # -t0.5: after stdin EOF, wait up to 0.5s for response then close
    # timeout 5: hard kill if socat hangs for any reason
    echo "$request" | timeout 5 socat -t0.5 - UNIX-CONNECT:"$SOCKET_PATH"
}

# --- Tests ---

PASSED=0
FAILED=0

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

# Test 1: listTasks on empty db returns empty array
RESP=$(send_request '{"method":"listTasks","showAll":false}')
assert_contains "listTasks empty db" "$RESP" "[]"

# Test 2: addTask succeeds
RESP=$(send_request '{"method":"addTask","title":"buy milk"}')
assert_contains "addTask returns ok" "$RESP" '"ok":true'

# Test 3: listTasks now returns the added task
RESP=$(send_request '{"method":"listTasks","showAll":false}')
assert_contains "listTasks has task" "$RESP" "buy milk"
assert_contains "listTasks shows needsAction" "$RESP" "needsAction"

# Test 4: addTask a second task
RESP=$(send_request '{"method":"addTask","title":"walk the dog"}')
assert_contains "addTask second returns ok" "$RESP" '"ok":true'

# Test 5: listTasks returns both tasks
RESP=$(send_request '{"method":"listTasks","showAll":false}')
assert_contains "listTasks has both tasks (milk)" "$RESP" "buy milk"
assert_contains "listTasks has both tasks (dog)" "$RESP" "walk the dog"

# Test 6: complete a task (need to extract the id first)
# Extract the first task's id from the listTasks response
TASK_ID=$(echo "$RESP" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
if [[ -n "$TASK_ID" ]]; then
    RESP=$(send_request "{\"method\":\"complete\",\"id\":\"$TASK_ID\"}")
    assert_contains "complete returns ok" "$RESP" '"ok":true'

    # Test 7: listTasks without showAll should hide completed task
    RESP=$(send_request '{"method":"listTasks","showAll":false}')
    assert_not_contains "completed task hidden from default list" "$RESP" "buy milk"
    assert_contains "incomplete task still visible" "$RESP" "walk the dog"

    # Test 8: listTasks with showAll should show completed task
    RESP=$(send_request '{"method":"listTasks","showAll":true}')
    assert_contains "completed task visible with showAll" "$RESP" "buy milk"
    assert_contains "listTasks showAll has completed status" "$RESP" "completed"

    # Test 9: incomplete - mark it back
    RESP=$(send_request "{\"method\":\"incomplete\",\"id\":\"$TASK_ID\"}")
    assert_contains "incomplete returns ok" "$RESP" '"ok":true'

    RESP=$(send_request '{"method":"listTasks","showAll":false}')
    assert_contains "task visible again after incomplete" "$RESP" "buy milk"
else
    echo "FAIL: could not extract task ID from listTasks response"
    FAILED=$((FAILED + 1))
fi

# Test 10: error cases
RESP=$(send_request '{"method":"addTask"}')
assert_contains "addTask missing title" "$RESP" '"error"'

RESP=$(send_request '{"method":"complete"}')
assert_contains "complete missing id" "$RESP" '"error"'

RESP=$(send_request '{"method":"bogusMethod"}')
assert_contains "unknown method" "$RESP" '"error"'

RESP=$(send_request '{"no_method_field":true}')
assert_contains "missing method field" "$RESP" '"error"'

# Test 11: shutdown
RESP=$(send_request '{"method":"shutdown"}')
assert_contains "shutdown returns ok" "$RESP" "shutting down"

# Wait for server to exit
sleep 0.5
if kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FAIL: server did not exit after shutdown"
    FAILED=$((FAILED + 1))
else
    echo "PASS: server exited cleanly after shutdown"
    PASSED=$((PASSED + 1))
fi

# Verify socket was cleaned up by the server
if [[ ! -S "$SOCKET_PATH" ]]; then
    echo "PASS: socket cleaned up by server"
    PASSED=$((PASSED + 1))
else
    echo "FAIL: socket still exists after shutdown"
    FAILED=$((FAILED + 1))
fi

# --- Summary ---

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if (( FAILED > 0 )); then
    exit 1
fi
