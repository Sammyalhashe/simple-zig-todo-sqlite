#!/usr/bin/env bash
# check.sh — run all quality checks for the simple-zig-todo-sqlite project.
#
# Used by:
#   - the git pre-commit hook (installed by the devShell shellHook)
#   - the jj describe/new aliases in ~/.config/jj/config.toml
#
# The script locates the repo root via git so it can be invoked from any
# working directory.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

# ---------------------------------------------------------------------------
# 1. Nix formatting
# ---------------------------------------------------------------------------
echo "check: checking nix fmt..."
if command -v nixfmt >/dev/null 2>&1; then
  NIXFMT="nixfmt"
else
  # Outside the devShell: fall back to nix run (requires network/cache).
  NIXFMT="nix run nixpkgs#nixfmt-rfc-style --"
fi

if ! $NIXFMT --check "$REPO_ROOT/flake.nix" "$REPO_ROOT"/nix/*.nix; then
  echo ""
  echo "check: nix formatting check failed."
  echo "Run 'nixfmt flake.nix nix/*.nix' to fix."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Zig formatting
# ---------------------------------------------------------------------------
echo "check: checking zig fmt..."
if ! zig fmt --check "$REPO_ROOT/src/"; then
  echo ""
  echo "check: zig formatting check failed."
  echo "Run 'zig fmt src/' to fix."
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Unit tests
# ---------------------------------------------------------------------------
echo "check: running unit tests..."
if ! (cd "$REPO_ROOT" && zig build test); then
  echo ""
  echo "check: unit tests failed."
  exit 1
fi

echo "check: all checks passed."
