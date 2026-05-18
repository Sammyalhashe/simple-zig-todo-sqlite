{ pkgs }:
let
  test-unit = pkgs.writeShellScriptBin "test-unit" ''
    set -euo pipefail
    echo "=== Running unit tests ==="
    zig build test
  '';

  test-integration = pkgs.writeShellScriptBin "test-integration" ''
    set -euo pipefail
    echo "=== Running integration tests (MariaDB) ==="

    # Locate test harness relative to the project root
    SCRIPT="''${TEST_HARNESS_DIR:-./test}/test-mariadb.sh"
    if [[ ! -x "$SCRIPT" ]]; then
      echo "ERROR: Cannot find test-mariadb.sh at $SCRIPT"
      echo "Run this from the project root, or set TEST_HARNESS_DIR."
      exit 1
    fi

    "$SCRIPT" zig build integration-test
  '';

  test-serve = pkgs.writeShellScriptBin "test-serve" ''
    set -euo pipefail
    echo "=== Running serve integration test ==="

    SCRIPT="''${TEST_HARNESS_DIR:-./test}/test-serve.sh"
    if [[ ! -x "$SCRIPT" ]]; then
      echo "ERROR: Cannot find test-serve.sh at $SCRIPT"
      echo "Run this from the project root, or set TEST_HARNESS_DIR."
      exit 1
    fi

    # Ensure the binary is built
    zig build

    "$SCRIPT"
  '';

  test-sync = pkgs.writeShellScriptBin "test-sync" ''
    set -euo pipefail
    echo "=== Running sync integration test ==="

    SCRIPT="''${TEST_HARNESS_DIR:-./test}/test-mariadb.sh"
    if [[ ! -x "$SCRIPT" ]]; then
      echo "ERROR: Cannot find test-mariadb.sh at $SCRIPT"
      echo "Run this from the project root, or set TEST_HARNESS_DIR."
      exit 1
    fi

    # Ensure the binary is built
    zig build

    "$SCRIPT" ./test/test-sync.sh
  '';

  test-mariadb-cli = pkgs.writeShellScriptBin "test-mariadb-cli" ''
    set -euo pipefail
    echo "=== Running MariaDB CLI integration test ==="

    SCRIPT="''${TEST_HARNESS_DIR:-./test}/test-mariadb.sh"
    if [[ ! -x "$SCRIPT" ]]; then
      echo "ERROR: Cannot find test-mariadb.sh at $SCRIPT"
      echo "Run this from the project root, or set TEST_HARNESS_DIR."
      exit 1
    fi

    # Ensure the binary is built
    zig build

    "$SCRIPT" ./test/test-mariadb-cli.sh
  '';

  test-all = pkgs.writeShellScriptBin "test-all" ''
    set -euo pipefail
    echo "=== Running all tests ==="
    echo ""

    test-unit
    echo ""
    test-serve
    echo ""
    test-integration
    echo ""
    test-sync
    echo ""
    test-mariadb-cli
  '';
in
{
  inherit
    test-unit
    test-integration
    test-serve
    test-sync
    test-mariadb-cli
    test-all
    ;
  all = [
    test-unit
    test-integration
    test-serve
    test-sync
    test-mariadb-cli
    test-all
  ];
}
