{ pkgs }:
pkgs.mkShell {
  buildInputs = with pkgs; [
    zig
    sqlite
    mariadb-connector-c
    sshpass
    pkg-config
    zls
  ];
}
