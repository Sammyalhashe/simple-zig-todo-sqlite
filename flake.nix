{
  description = "Zig todo CLI with SQLite/MariaDB backend and optional daemon";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    (flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.default = import ./nix/package.nix { inherit pkgs; src = ./.; };
        devShells.default = import ./nix/devshell.nix { inherit pkgs; };
      }
    ))
    // {
      homeManagerModules.default = import ./nix/hm-module.nix { inherit self; };
    };
}
