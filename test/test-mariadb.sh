#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."

# Create temp directory for MariaDB data
TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/mariadb-test.XXXXXX")

cleanup() {
    if [[ -n "${MARIADB_PID:-}" ]] && kill -0 "$MARIADB_PID" 2>/dev/null; then
        echo "Stopping MariaDB (PID $MARIADB_PID)..."
        kill "$MARIADB_PID" 2>/dev/null || true
        wait "$MARIADB_PID" 2>/dev/null || true
    fi
    echo "Removing temp directory: $TMPDIR"
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

# Pick a random port in range 13306-19999
TEST_MARIADB_PORT=$((RANDOM % 6694 + 13306))
TEST_MARIADB_SOCKET="$TMPDIR/mariadb.sock"
TEST_MARIADB_HOST="127.0.0.1"

DATADIR="$TMPDIR/data"
mkdir -p "$DATADIR"

echo "=== MariaDB Integration Test Harness ==="
echo "Port:   $TEST_MARIADB_PORT"
echo "Socket: $TEST_MARIADB_SOCKET"
echo "Data:   $DATADIR"
echo ""

# Initialize MariaDB data directory
echo "Initializing MariaDB data directory..."
mariadb-install-db \
    --datadir="$DATADIR" \
    --auth-root-authentication-method=normal \
    --skip-test-db \
    >/dev/null 2>&1

# Start MariaDB
echo "Starting MariaDB on port $TEST_MARIADB_PORT..."
mariadbd \
    --datadir="$DATADIR" \
    --port="$TEST_MARIADB_PORT" \
    --socket="$TEST_MARIADB_SOCKET" \
    --skip-grant-tables \
    --skip-networking=0 \
    --bind-address="$TEST_MARIADB_HOST" \
    --pid-file="$TMPDIR/mariadb.pid" \
    --log-error="$TMPDIR/mariadb.err" \
    &
MARIADB_PID=$!

# Poll until MariaDB is ready (max 15 seconds)
echo "Waiting for MariaDB to be ready..."
SECONDS=0
until mariadb --socket="$TEST_MARIADB_SOCKET" -e "SELECT 1" >/dev/null 2>&1; do
    if (( SECONDS >= 15 )); then
        echo "ERROR: MariaDB did not become ready within 15 seconds"
        echo "Error log:"
        cat "$TMPDIR/mariadb.err" 2>/dev/null || true
        exit 1
    fi
    if ! kill -0 "$MARIADB_PID" 2>/dev/null; then
        echo "ERROR: MariaDB process died"
        echo "Error log:"
        cat "$TMPDIR/mariadb.err" 2>/dev/null || true
        exit 1
    fi
    sleep 0.2
done
echo "MariaDB is ready (took ${SECONDS}s)"

# Load the schema
echo "Loading supernote.sql..."
mariadb --socket="$TEST_MARIADB_SOCKET" < "$PROJECT_ROOT/supernote.sql"

# Apply schema relaxations for test compatibility
echo "Applying schema relaxations..."
mariadb --socket="$TEST_MARIADB_SOCKET" <<'SQL'
ALTER TABLE supernotedb.t_schedule_task MODIFY user_id bigint(20) NOT NULL DEFAULT 0;
ALTER TABLE supernotedb.t_schedule_task MODIFY due_time bigint(20) NOT NULL DEFAULT 0;
-- Seed a default user so getDefaultUser() finds a row
INSERT IGNORE INTO supernotedb.u_user (user_id, user_name, email, sex, password, create_time, update_time, is_normal) VALUES (1, 'test_user', 'test@test.com', '1', 'test', NOW(), NOW(), 'Y');
SQL

echo ""
echo "=== MariaDB ready ==="
echo "  TEST_MARIADB_HOST=$TEST_MARIADB_HOST"
echo "  TEST_MARIADB_PORT=$TEST_MARIADB_PORT"
echo "  TEST_MARIADB_SOCKET=$TEST_MARIADB_SOCKET"
echo ""

# Export env vars for the test command
export TEST_MARIADB_HOST
export TEST_MARIADB_PORT
export TEST_MARIADB_SOCKET

# Run the provided command
echo "Running: $*"
echo "---"
"$@"
