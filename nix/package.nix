{ pkgs, src }:
let
  raw = pkgs.stdenv.mkDerivation {
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
      openssl
    ];
  };
  sshpass = pkgs.sshpass;
  openssl = pkgs.openssl;
in
pkgs.runCommand "todo" {
  nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
} ''
  mkdir -p $out/bin
  cp ${raw}/bin/todo $out/bin/todo
  wrapProgram $out/bin/todo \
    --prefix PATH : "${sshpass}/bin:${openssl}/bin"
''
