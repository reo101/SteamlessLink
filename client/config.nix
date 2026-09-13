{ lib }:
{
  mkOptions =
    {
      package,
      withDeviceGroup ? false,
    }:
    {
      inherit package;

      device = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/dev/hidraw3";
        description = "hidraw device to bridge. Defaults to discovery by vendorId/productIds.";
      };

      vendorId = lib.mkOption {
        type = lib.types.int;
        default = 10462; # 0x28de, Valve
        description = "HID vendor ID of the controller.";
      };

      productIds = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.int;
        default = [ 4867 ]; # 0x1303, Triton BLE
        description = "HID product IDs of the controller.";
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
    }
    // lib.optionalAttrs withDeviceGroup {
      deviceGroup = lib.mkOption {
        type = lib.types.str;
        default = "steamless-link-input";
        description = "Group granted access to the captured hidraw node.";
      };
    };

  mkArgs = cfg:
    [
      (lib.getExe cfg.package)
      "--vid"
      "0x${lib.toHexString cfg.vendorId}"
    ]
    ++ lib.concatMap (productId: [
      "--pid"
      "0x${lib.toHexString productId}"
    ]) cfg.productIds
    ++ [
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
