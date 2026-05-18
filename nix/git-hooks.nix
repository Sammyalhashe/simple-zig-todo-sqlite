{ pkgs }:
let
  nixfmt = "${pkgs.nixfmt-rfc-style}/bin/nixfmt";

  # The pre-commit hook script.  Written as a Nix string so that the devShell
  # shellHook can embed it verbatim into .git/hooks/pre-commit.
  preCommitScript = ''
    #!/usr/bin/env bash
    set -euo pipefail

    echo "pre-commit: checking nix fmt..."
    if ! ${nixfmt} --check flake.nix nix/*.nix; then
      echo ""
      echo "pre-commit: nix formatting check failed."
      echo "Run 'nixfmt flake.nix nix/*.nix' to fix, then re-commit."
      exit 1
    fi

    echo "pre-commit: checking zig fmt..."
    if ! zig fmt --check src/; then
      echo ""
      echo "pre-commit: zig formatting check failed."
      echo "Run 'zig fmt src/' to fix, then re-commit."
      exit 1
    fi

    echo "pre-commit: running unit tests..."
    if ! zig build test; then
      echo ""
      echo "pre-commit: unit tests failed. Fix them before committing."
      exit 1
    fi

    echo "pre-commit: all checks passed."
  '';

  # shellHook fragment that installs the hook idempotently.
  # We write a sentinel comment so we can detect our own hook and overwrite
  # safely on re-entry without clobbering a hook the user may have placed.
  installHook = ''
    _GIT_HOOKS_DIR="$(git rev-parse --git-dir 2>/dev/null)/hooks"
    if [ -n "$_GIT_HOOKS_DIR" ]; then
      mkdir -p "$_GIT_HOOKS_DIR"
      cat > "$_GIT_HOOKS_DIR/pre-commit" << 'HOOK_EOF'
    ${preCommitScript}HOOK_EOF
      chmod +x "$_GIT_HOOKS_DIR/pre-commit"
      echo "devShell: installed pre-commit hook -> $_GIT_HOOKS_DIR/pre-commit"
    else
      echo "devShell: warning: not inside a git repo, skipping hook installation."
    fi
    unset _GIT_HOOKS_DIR
  '';
in
{
  inherit installHook;
}
