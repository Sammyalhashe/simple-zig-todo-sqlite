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
        testScripts = import ./nix/test-scripts.nix { inherit pkgs; };
      in
      {
        packages.default = import ./nix/package.nix {
          inherit pkgs;
          src = ./.;
        };

        checks = import ./nix/checks.nix {
          inherit pkgs;
          src = ./.;
        };

        devShells.default = import ./nix/devshell.nix {
          inherit pkgs;
          testScripts = testScripts.all;
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/todo";
        };
      }
    ))
    // {
      homeManagerModules.default = import ./nix/hm-module.nix { inherit self; };
    };
}
