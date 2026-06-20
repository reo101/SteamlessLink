{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.steamless-uhid;
in
{
  options.services.steamless-uhid = {
    enable = lib.mkEnableOption "SteamlessLink raw Triton-to-UHID bridge";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../server/package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./server/package.nix { }";
      description = "Package providing the steamless-uhid-server executable.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "steam";
      description = "User to run the daemon as. Usually this should be the same user that runs Steam.";
    };

    group = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional primary group for the daemon service.";
    };

    supplementaryGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "input" ];
      description = "Supplementary groups for /dev/uhid and hidraw access.";
    };

    listenHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address for the daemon to bind. Use 0.0.0.0 or a LAN IP if Android connects directly.";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 3244;
      description = "TCP port for SteamlessLink raw UHID frames.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open listenPort in the NixOS firewall.";
    };

    installUdevRules = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install udev rules for /dev/uhid and Valve UHID-created hidraw devices.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "debug" "info" "warning" "error" ];
      default = "info";
      description = "Daemon log level.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra command-line arguments passed to steamless-uhid-server.";
    };

    iroh = {
      enable = lib.mkEnableOption "Iroh endpoint-ticket proxy for the raw UHID bridge";

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Package providing the steamless-uhid-iroh-proxy executable.";
      };

      targetHost = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "TCP host the Iroh proxy forwards accepted streams to.";
      };

      targetPort = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "TCP port the Iroh proxy forwards to. Defaults to services.steamless-uhid.listenPort.";
      };

      bindAddr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "0.0.0.0:34244";
        description = "Optional local socket address for the Iroh endpoint to bind.";
      };

      externalAddr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "jeeves.example.net:34244";
        description = "Optional externally reachable address to put in the printed endpoint ticket.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.iroh.enable || cfg.iroh.package != null;
        message = "services.steamless-uhid.iroh.package must be set when services.steamless-uhid.iroh.enable is true.";
      }
    ];

    boot.kernelModules = [ "uhid" ];

    environment.systemPackages = [ cfg.package ] ++ lib.optional (cfg.iroh.enable && cfg.iroh.package != null) cfg.iroh.package;

    services.udev.extraRules = lib.mkIf cfg.installUdevRules (builtins.readFile ../../server/60-steamless-uhid.rules);

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.listenPort ];

    systemd.services.steamless-uhid-iroh-proxy = lib.mkIf (cfg.iroh.enable && cfg.iroh.package != null) {
      description = "SteamlessLink Iroh proxy for raw UHID";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "steamless-uhid.service" ];
      wants = [ "network-online.target" "steamless-uhid.service" ];
      environment = lib.optionalAttrs (cfg.iroh.bindAddr != null) {
        STEAMLESS_IROH_BIND_ADDR = cfg.iroh.bindAddr;
      } // lib.optionalAttrs (cfg.iroh.externalAddr != null) {
        STEAMLESS_IROH_EXTERNAL_ADDR = cfg.iroh.externalAddr;
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.escapeShellArgs [
          "${cfg.iroh.package}/bin/steamless-uhid-iroh-proxy"
          "${cfg.iroh.targetHost}:${toString (if cfg.iroh.targetPort == null then cfg.listenPort else cfg.iroh.targetPort)}"
        ];
        User = cfg.user;
        SupplementaryGroups = cfg.supplementaryGroups;
        Restart = "on-failure";
        RestartSec = 2;
      } // lib.optionalAttrs (cfg.group != null) {
        Group = cfg.group;
      };
    };

    systemd.services.steamless-uhid = {
      description = "SteamlessLink raw Triton UHID bridge";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "systemd-udevd.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/steamless-uhid-server"
            "--listen-host"
            cfg.listenHost
            "--listen-port"
            (toString cfg.listenPort)
            "--log-level"
            cfg.logLevel
          ]
          ++ cfg.extraArgs
        );
        User = cfg.user;
        SupplementaryGroups = cfg.supplementaryGroups;
        Restart = "on-failure";
        RestartSec = 2;
      }
      // lib.optionalAttrs (cfg.group != null) {
        Group = cfg.group;
      };
    };
  };
}
