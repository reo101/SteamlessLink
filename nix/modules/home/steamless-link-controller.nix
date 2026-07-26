# Home Manager module for the Steamless Link controller bridge.
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
  cfg = config.services.steamless-link-controller;
  hex = value: "0x${lib.toHexString value}";
in
{
  options.services.steamless-link-controller = {
    enable = lib.mkEnableOption "Steamless Link controller bridge (user service)";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Package providing the steamless-link-controller executable.";
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
      description = "Steamless Link host (or Iroh proxy) address to connect to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3244;
      description = "Steamless Link host TCP port.";
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
      description = "Extra command-line arguments passed to steamless-link-controller.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.steamless-link-controller = {
      Unit = {
        Description = "Steamless Link controller bridge";
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
