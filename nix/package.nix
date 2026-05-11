{ pkgs, src }:
pkgs.stdenv.mkDerivation {
  name = "todo";
  inherit src;
  nativeBuildInputs = with pkgs; [
    zig.hook
    pkg-config
  ];
  buildInputs = with pkgs; [
    sqlite
    mariadb-connector-c
    ncurses
    sshpass
  ];
}
