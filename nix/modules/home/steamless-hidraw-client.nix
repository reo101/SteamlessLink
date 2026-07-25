# Home Manager module for steamless-hidraw-client.
#
# Runs the bridge as an unprivileged systemd user service. This relies on
# the desktop user already having access to the controller's hidraw node
# (e.g. via the steam-devices uaccess rules), and cannot steal the device
# from a locally running Steam; use the NixOS module for that.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.steamless-hidraw-client;
  hex = value: "0x${lib.toHexString value}";
in
{
  options.services.steamless-hidraw-client = {
    enable = lib.mkEnableOption "SteamlessLink hidraw-to-network controller bridge (user service)";

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
      description = "HID vendor ID of the controller.";
    };

    productId = lib.mkOption {
      type = lib.types.int;
      default = 4867; # 0x1303, Triton BLE
      description = "HID product ID of the controller.";
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
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.steamless-hidraw-client = {
      Unit = {
        Description = "SteamlessLink hidraw-to-network controller bridge";
        After = [ "network.target" ];
      };
      Service = {
        ExecStart = lib.escapeShellArgs (
          [
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
          ++ cfg.extraArgs
        );
        Restart = "always";
        RestartSec = 2;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
