{
  pkgs,
  testScripts ? [ ],
}:
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
    ])
    ++ testScripts;
}
