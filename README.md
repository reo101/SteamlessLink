# SteamlessLink

Android/Kotlin bridge for using a Steam Controller / Triton controller with a remote Linux Steam host.

Preferred path:

```text
Steam Controller BLE -> Android GATT -> raw Triton reports -> TCP -> Steamless UHID bridge -> Linux UHID/hidraw -> Steam
```

Fallback path:

```text
Steam Controller BLE/USB -> Android -> Triton parser -> VIIPER xbox360 stream
```

The raw UHID path preserves the controller as a Valve/Steam Controller device, so Steam can use native Steam Controller configuration, battery queries, ping, and haptics. The VIIPER path is a known-good Xbox 360 fallback.

## Build / install Android app

```sh
nix develop -c gradle :app:testDebugUnitTest
nix develop -c gradle :app:installDebug
```

APK:

```text
app/build/outputs/apk/debug/app-debug.apk
```

## Android app configuration

The app needs a server host/IP and port.

Default port conventions used by the UI:

- Raw UHID bridge: `3244`
- VIIPER Xbox fallback: `3242`

The main UI buttons are:

- `Start Raw BLE` — preferred path
- `Raw USB` — experimental; avoid if the phone/controller USB setup is unstable
- `Xbox BLE` — VIIPER Xbox 360 fallback
- `Stop`

## Server-side bridge

This repository now ships the UHID bridge under [`server/`](server/):

- [`server/steamless-uhid-server.py`](server/steamless-uhid-server.py): standalone Python daemon
- [`server/60-steamless-uhid.rules`](server/60-steamless-uhid.rules): udev permissions
- [`server/steamless-uhid.service`](server/steamless-uhid.service): example systemd service
- [`nix/modules/steamless-uhid.nix`](nix/modules/steamless-uhid.nix): NixOS module

See [`server/README.md`](server/README.md) for generic Linux install instructions, protocol notes, security notes, and links to Linux UHID/hidraw/udev/systemd documentation.

### NixOS module example

From a flake-based NixOS config:

```nix
{
  inputs.steamlesslink.url = "github:YOUR-USER/SteamlessLink";

  outputs = { self, nixpkgs, steamlesslink, ... }: {
    nixosConfigurations.steam-host = nixpkgs.lib.nixosSystem {
      modules = [
        steamlesslink.nixosModules.steamless-uhid
        {
          services.steamless-uhid = {
            enable = true;
            user = "steam";          # the user that runs Steam
            listenHost = "0.0.0.0";  # or keep 127.0.0.1 behind a TCP proxy/tunnel
            listenPort = 3244;
            openFirewall = true;
          };
        }
      ];
    };
  };
}
```

The current protocol is unauthenticated raw TCP. Bind it only to trusted networks, firewall it to the Android device, or use a tunnel/proxy.

## BLE behavior

The app will:

- request Nearby Devices / Bluetooth permissions
- prefer bonded LE devices named `SteamController` or `Steam Ctrl*`
- otherwise scan for those names for 15 seconds
- discover Valve service `100f6c32-1735-4313-b402-38567131e5f3`
- enable notifications for Valve report characteristics `100f6c75` through `100f6c7a`
- reconstruct missing BLE report IDs from the characteristic UUID (`100f6c7a` -> `0x45`)
- forward numbered `0x45` Triton BLE input reports to the UHID bridge
- proxy Steam feature reports through BLE report characteristic `100f6c34`
- proxy Steam output reports through BLE output characteristics `100f6cb5` through `100f6cbe`

In raw UHID mode the app does **not** run its own periodic lizard-mode refresh; Steam owns feature/report traffic. In VIIPER fallback mode the app periodically sends lizard-mode-off itself.

Useful logs while developing:

```sh
journalctl -u steamless-uhid -n 120 --no-pager
tail -160 ~/.local/share/Steam/logs/controller.txt
adb logcat -d -v time -s ControllerBridge BluetoothGatt AndroidRuntime
```
