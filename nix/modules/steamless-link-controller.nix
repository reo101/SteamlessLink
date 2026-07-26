# NixOS integration for the Steamless Link controller bridge.
#
# The daemon itself is instantiated as a modular service
# (system.services.steamless-link-controller, imported from the package's
# passthru.services.default). This module adds the privileged pieces that
# cannot be expressed portably:
#
#  - a dedicated device group and udev rules that, while capture is active,
#    hand the controller's hidraw node to that group and strip the uaccess
#    tag so a locally running Steam cannot (re)open it,
#  - a root helper that toggles capture by touching a flag in /run and
#    rebinding the HID device (revoking any already-open file descriptors,
#    including Steam's).
#
# Capture follows the steamless-link-controller-capture.service lifecycle, so
# the controller can be handed back to local Steam at runtime:
#
#   systemctl stop steamless-link-controller-capture.service    # local Steam
#   systemctl start steamless-link-controller-capture.service   # remote use
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.steamless-link-controller;

  hex8 = value: lib.fixedWidthString 8 "0" (lib.toHexString value);
  # uevent lines look like: HID_ID=0005:000028DE:00001303 (any bus).
  hidIdPattern = "^HID_ID=[0-9A-F]\\{4\\}:${hex8 cfg.vendorId}:${hex8 cfg.productId}$";

  captureFlag = "/run/steamless-link-controller/capture";

  matchHidrawScript = pkgs.writeShellScript "steamless-link-controller-match" ''
    # $1 is the udev devpath of a hidraw device, e.g.
    # /devices/.../0005:28DE:1303.0001/hidraw/hidraw0
    exec ${pkgs.gnugrep}/bin/grep -q '${hidIdPattern}' "/sys$1/device/uevent"
  '';

  captureCtl = pkgs.writeShellApplication {
    name = "steamless-link-controller-capturectl";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.systemdMinimal
    ];
    text = ''
      flag=${captureFlag}

      # Unbind and rebind every matching HID device. This destroys and
      # recreates the hidraw node, revoking all open file descriptors, and
      # lets udev re-evaluate permissions against the capture flag.
      rebind() {
        for dev in /sys/bus/hid/devices/*; do
          [ -e "$dev/uevent" ] || continue
          grep -q '${hidIdPattern}' "$dev/uevent" || continue
          [ -e "$dev/driver" ] || continue
          name=$(basename "$dev")
          driver=$(readlink -f "$dev/driver")
          echo "$name" > "$driver/unbind"
          echo "$name" > "$driver/bind"
        done
        udevadm settle --timeout=10 || true
      }

      case "''${1:-}" in
        start)
          mkdir -p "$(dirname "$flag")"
          : > "$flag"
          rebind
          ;;
        stop)
          rm -f "$flag"
          rebind
          ;;
        *)
          echo "usage: steamless-link-controller-capturectl start|stop" >&2
          exit 64
          ;;
      esac
    '';
  };

  # Runs after the steam-devices rules (which TAG+="uaccess" Valve devices)
  # but before 73-seat-late.rules applies the uaccess ACLs.
  captureUdevRules = pkgs.writeTextFile {
    name = "steamless-link-controller-udev-rules";
    destination = "/lib/udev/rules.d/72-steamless-link-controller-capture.rules";
    text = ''
      ACTION=="add|change", SUBSYSTEM=="hidraw", TEST=="${captureFlag}", PROGRAM="${matchHidrawScript} %p", OWNER="root", GROUP="${cfg.deviceGroup}", MODE="0660", TAG-="uaccess"
    '';
  };
in
{
  options.services.steamless-link-controller = {
    enable = lib.mkEnableOption "Steamless Link controller bridge";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../client/package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./client/package.nix { }";
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

    deviceGroup = lib.mkOption {
      type = lib.types.str;
      default = "steamless-link-input";
      description = "Group granted access to the captured hidraw node.";
    };

    capture = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Steal the controller from local consumers (e.g. a running Steam)
          while the bridge is active, by rebinding the HID device and
          restricting the hidraw node to the daemon's device group.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.deviceGroup} = { };

    system.services.steamless-link-controller = {
      imports = [ cfg.package.services.default ];
      steamless-link-controller = {
        package = cfg.package;
        device = cfg.device;
        vendorId = cfg.vendorId;
        productId = cfg.productId;
        host = cfg.host;
        port = cfg.port;
        reconnectMs = cfg.reconnectMs;
        logLevel = cfg.logLevel;
        extraArgs = cfg.extraArgs;
        deviceGroup = cfg.deviceGroup;
      };
    };

    environment.systemPackages = lib.mkIf cfg.capture.enable [ captureCtl ];

    services.udev.packages = lib.mkIf cfg.capture.enable [ captureUdevRules ];

    systemd.services.steamless-link-controller-capture = lib.mkIf cfg.capture.enable {
      description = "Steamless Link controller capture";
      # Capture lives and dies with the bridge, and can also be toggled
      # manually at runtime to hand the controller back to local Steam.
      partOf = [ "steamless-link-controller.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe captureCtl} start";
        ExecStop = "${lib.getExe captureCtl} stop";
      };
    };

    # Extra dependencies merged into the unit generated by the modular service.
    systemd.services.steamless-link-controller = lib.mkIf cfg.capture.enable {
      wants = [ "steamless-link-controller-capture.service" ];
      after = [ "steamless-link-controller-capture.service" ];
    };
  };
}
