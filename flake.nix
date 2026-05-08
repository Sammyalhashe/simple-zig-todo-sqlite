{
  description = "Zig tui todo application";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils = {
      url = "github:numtide/flake-utils";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          name = "todo";
          src = ./.;
          nativeBuildInputs = with pkgs; [
            zig.hook
            pkg-config
          ];
          buildInputs = with pkgs; [
            sqlite
            mariadb-connector-c
            sshpass
          ];
        };
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            sqlite
            mariadb-connector-c
            sshpass
            pkg-config
            zls
          ];
        };
      }
    );
}
