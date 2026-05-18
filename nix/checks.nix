{ pkgs, src }:
{
  unit-tests = pkgs.stdenv.mkDerivation {
    name = "todo-unit-tests";
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

    # zig.hook runs `zig build` by default; override to run tests instead
    zigBuildFlags = [ "test" ];

    # Tests don't produce installable output -- write a sentinel so
    # the derivation is not considered to have failed the install phase.
    installPhase = ''
      mkdir -p $out
      touch $out/tests-passed
    '';
  };
}
