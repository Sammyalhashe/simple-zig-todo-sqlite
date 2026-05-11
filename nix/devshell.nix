{ pkgs }:
pkgs.mkShell {
  buildInputs = with pkgs; [
    zig
    sqlite
    mariadb-connector-c
    ncurses
    sshpass
    pkg-config
    zls
  ];
}
