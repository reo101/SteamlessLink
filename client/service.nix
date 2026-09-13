# Modular service (https://nixos.org/manual/nixos/unstable/#modular-services)
# for the Steamless Link controller bridge. Instantiate via:
#
#   system.services.steamless-link-controller = {
#     imports = [ pkgs.steamless-link-controller.services.default ];
#     steamless-link-controller.host = "jeeves.example.net";
#   };
#
# The daemon is unprivileged: DynamicUser plus a supplementary group that is
# granted access to the captured hidraw node by the host's udev rules (see
# nix/modules/steamless-link-controller.nix for privileged capture).
{
  config,
  options,
  lib,
  ...
}:
let
  cfg = config.steamless-link-controller;
  controller = import ./config.nix { inherit lib; };
in
{
  _class = "service";

  options.steamless-link-controller = controller.mkOptions {
    package = lib.mkOption {
      type = lib.types.package;
      description = "Package providing the steamless-link-controller executable.";
    };
    withDeviceGroup = true;
  };

  config = {
    process.argv = controller.mkArgs cfg;
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
