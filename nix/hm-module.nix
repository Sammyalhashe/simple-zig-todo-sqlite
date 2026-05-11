{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.todo;
in
{
  options.services.todo = {
    enable = lib.mkEnableOption "todo daemon (JSON-RPC over Unix socket)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.system}.default;
      description = "The todo package to use.";
    };

    socketPath = lib.mkOption {
      type = lib.types.str;
      default = "%t/todo.sock";
      description = "Path to the Unix socket. %t resolves to XDG_RUNTIME_DIR.";
    };

    remoteDb = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SSH remote address for MariaDB tunnel (e.g. user@host).";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to file containing SSH password for remote DB.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.todo-daemon = {
      Unit = {
        Description = "Todo daemon (JSON-RPC over Unix socket)";
        After = [ "network.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart =
          let
            args = lib.concatStringsSep " " (
              lib.optional (cfg.remoteDb != null) "-r ${cfg.remoteDb}"
              ++ [ "serve" ]
            );
          in
          "${cfg.package}/bin/todo ${args}";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = lib.optionalAttrs (cfg.passwordFile != null) {
          TODO_PASSWORD_FILE = cfg.passwordFile;
        };
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
