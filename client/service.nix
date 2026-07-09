# Modular service (https://nixos.org/manual/nixos/unstable/#modular-services)
# for steamless-hidraw-client. Instantiate via:
#
#   system.services.steamless-hidraw-client = {
#     imports = [ pkgs.steamless-hidraw-client.services.default ];
#     steamless-hidraw-client.host = "jeeves.example.net";
#   };
#
# The daemon is unprivileged: DynamicUser plus a supplementary group that is
# granted access to the captured hidraw node by the host's udev rules (see
# nix/modules/steamless-hidraw-client.nix for the privileged capture side).
{
  config,
  options,
  lib,
  ...
}:
let
  cfg = config.steamless-hidraw-client;
  hex = value: "0x${lib.toHexString value}";
in
{
  _class = "service";

  options.steamless-hidraw-client = {
    package = lib.mkOption {
      type = lib.types.package;
      description = "Package providing the steamless-hidraw-client executable.";
    };

    device = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/dev/hidraw3";
      description = "hidraw device to bridge. Defaults to discovery by vendorId/productId.";
    };

    vendorId = lib.mkOption {
      type = lib.types.int;
      default = 10462; # 0x28de, Valve
      description = "HID vendor ID used for device discovery.";
    };

    productId = lib.mkOption {
      type = lib.types.int;
      default = 4867; # 0x1303, Triton BLE
      description = "HID product ID used for device discovery.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "steamless-uhid-server (or iroh proxy) address to connect to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3244;
      description = "steamless-uhid-server TCP port.";
    };

    reconnectMs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2000;
      description = "Delay between device/connection retries, in milliseconds.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "debug" "info" "warning" "error" ];
      default = "info";
      description = "Daemon log level.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra command-line arguments passed to steamless-hidraw-client.";
    };

    deviceGroup = lib.mkOption {
      type = lib.types.str;
      default = "steamless-hidraw";
      description = ''
        Supplementary group granting access to the captured hidraw node.
        Must match the group used by the host's udev capture rules.
      '';
    };
  };

  config = {
    process.argv = [
      (lib.getExe cfg.package)
      "--vid"
      (hex cfg.vendorId)
      "--pid"
      (hex cfg.productId)
      "--host"
      cfg.host
      "--port"
      (toString cfg.port)
      "--reconnect-ms"
      (toString cfg.reconnectMs)
      "--log-level"
      cfg.logLevel
    ]
    ++ lib.optionals (cfg.device != null) [
      "--device"
      cfg.device
    ]
    ++ cfg.extraArgs;
  }
  // lib.optionalAttrs (options ? systemd) {
    systemd.service = {
      after = [ "network.target" ];
      serviceConfig = {
        Restart = "always";
        RestartSec = 2;

        DynamicUser = true;
        SupplementaryGroups = [ cfg.deviceGroup ];

        # Least privilege: the daemon only needs hidraw nodes and a TCP socket.
        CapabilityBoundingSet = "";
        DevicePolicy = "closed";
        DeviceAllow = [ "char-hidraw rw" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        UMask = "0077";
      };
    };
  };
}
