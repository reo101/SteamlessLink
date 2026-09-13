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
  controller = import ../../../client/config.nix { inherit lib; };
in
{
  options.services.steamless-link-controller = controller.mkOptions {
    package = lib.mkOption {
      type = lib.types.package;
      description = "Package providing the steamless-link-controller executable.";
    };
  } // {
    enable = lib.mkEnableOption "Steamless Link controller bridge (user service)";
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.steamless-link-controller = {
      Unit = {
        Description = "Steamless Link controller bridge";
        After = [ "network.target" ];
      };
      Service = {
        ExecStart = lib.escapeShellArgs (controller.mkArgs cfg);
        Restart = "always";
        RestartSec = 2;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
