{
  pkgs,
  testScripts ? [ ],
}:
let
  gitHooks = import ./git-hooks.nix { inherit pkgs; };
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zig
    pkg-config
    zls
  ];

  buildInputs = with pkgs; [
    sqlite
    mariadb-connector-c
    ncurses
  ];

  packages =
    (with pkgs; [
      mariadb
      socat
      sshpass
      python3
      nixfmt-rfc-style
    ])
    ++ testScripts;

  shellHook = gitHooks.installHook;
}
