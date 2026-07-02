#!/usr/bin/env bash
set -euo pipefail

# Integration test for the read-only HTTP command.
# Requires: curl, the todo binary already built. Uses local SQLite only.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."
TODO_BIN="$PROJECT_ROOT/zig-out/bin/todo"
PORT=$((20000 + RANDOM % 20000))
BASE="http://127.0.0.1:$PORT"

# --- Preflight ---

if [[ ! -x "$TODO_BIN" ]]; then
    echo "ERROR: todo binary not found at $TODO_BIN"
    echo "Run 'zig build' first."
    exit 1
fi

if ! command -v curl &>/dev/null; then
    echo "ERROR: curl not found."
    exit 1
fi

# --- Setup ---

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/todo-http-test.XXXXXX")

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "=== HTTP Command Integration Test ==="
echo "  Binary:  $TODO_BIN"
echo "  URL:     $BASE"
echo "  Workdir: $WORKDIR"
echo ""

# --- Start server ---

cd "$WORKDIR"
"$TODO_BIN" -b sqlite http --port "$PORT" &
SERVER_PID=$!

SECONDS=0
until curl -s -o /dev/null "$BASE/healthz"; do
    if (( SECONDS >= 5 )); then
        echo "FAIL: Server did not answer within 5 seconds"
        exit 1
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "FAIL: Server process died before listening"
        exit 1
    fi
    sleep 0.1
done
echo "Server ready (PID $SERVER_PID, took ${SECONDS}s)"
echo ""

# --- Tests ---

PASSED=0
FAILED=0

assert_eq() {
    local label="$1"
    local actual="$2"
    local expected="$3"
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

status_of() {
    curl -s -o /dev/null -w '%{http_code}' "$@"
}

# Test 1: empty db returns an empty JSON array
assert_eq "GET /tasks empty db" "$(curl -s "$BASE/tasks")" "[]"
assert_contains "GET /tasks is JSON" "$(curl -s -D - -o /dev/null "$BASE/tasks")" "Content-Type: application/json"

# Test 2: a seeded task shows up (the server reads the same todo.db)
"$TODO_BIN" -b sqlite add "buy milk" 2>/dev/null
RESP=$(curl -s "$BASE/tasks")
assert_contains "GET /tasks has seeded task" "$RESP" "buy milk"
assert_contains "GET /tasks shows needsAction" "$RESP" "needsAction"

# Test 3: health check
assert_eq "GET /healthz body" "$(curl -s "$BASE/healthz")" "ok"
assert_eq "GET /healthz status" "$(status_of "$BASE/healthz")" "200"

# Test 4: unknown path and query strings
assert_eq "unknown path is 404" "$(status_of "$BASE/nope")" "404"
assert_eq "query string ignored" "$(status_of "$BASE/tasks?limit=5")" "200"

# Test 5: writes are refused
assert_eq "POST is 405" "$(status_of -X POST "$BASE/tasks")" "405"
assert_contains "405 sends Allow: GET" "$(curl -s -D - -o /dev/null -X POST "$BASE/tasks")" "Allow: GET"

# Test 6: oversized headers are rejected and the server keeps serving
BIG=$(head -c 9000 /dev/zero | tr '\0' 'a')
assert_eq "oversized header is 431" "$(status_of -H "X-Big: $BIG" "$BASE/healthz")" "431"
assert_eq "server still serves after 431" "$(status_of "$BASE/healthz")" "200"

# Test 7: a silent client and a half-sent request do not block later requests
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
exec 4<>"/dev/tcp/127.0.0.1/$PORT"
printf 'GET /healthz HTTP/1.1\r\nHost: x\r\n' >&4
SECONDS=0
assert_eq "served behind stalled clients" "$(status_of --max-time 15 "$BASE/healthz")" "200"
if (( SECONDS <= 12 )); then
    echo "PASS: stalled clients timed out (${SECONDS}s)"
    PASSED=$((PASSED + 1))
else
    echo "FAIL: stalled clients held the server for ${SECONDS}s"
    FAILED=$((FAILED + 1))
fi
exec 3>&- 4>&-

# Test 8: cleanup
kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
if kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FAIL: server still running after kill"
    FAILED=$((FAILED + 1))
else
    echo "PASS: server stopped"
    PASSED=$((PASSED + 1))
fi

# --- Summary ---

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if (( FAILED > 0 )); then
    exit 1
fi
