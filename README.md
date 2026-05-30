# SteamlessLink

Android/Kotlin bridge for using a Steam Controller / Triton controller with a remote Linux Steam host.

Preferred path:

```text
Steam Controller BLE -> Android GATT -> raw Triton reports -> TCP -> Steamless UHID bridge -> Linux UHID/hidraw -> Steam
```

Fallback paths:

```text
Steam Controller BLE/USB -> Android -> Triton parser -> VIIPER xbox360 stream
Steam Controller BLE/USB -> Android -> Triton parser -> local /dev/uinput Xbox gamepad
```

The raw UHID path preserves the controller as a Valve/Steam Controller device, so Steam can use native Steam Controller configuration, battery queries, ping, and haptics. The VIIPER path is a known-good remote Xbox 360 fallback. The local uinput path is for Android games/apps on the phone and requires Shizuku shell access or root.

## Build / install Android app

```sh
nix develop -c gradle :app:testDebugUnitTest
nix develop -c gradle :app:installDebug
```

The Zig/JNI protocol mapper is experimental and opt-in. The Kotlin mapper is
used by default; build an APK with the native mapper only when testing it:

```sh
nix develop -c gradle -Psteamless.buildZig=true :app:testZigProtocol :app:assembleDebug
```

Local Android uinput mode needs a small privileged helper packaged as an APK
asset. Build that helper into the debug APK with:

```sh
nix develop -c gradle -Psteamless.buildUinputHelper=true :app:assembleDebug
```

The helper is a standalone Zig/Linux executable built for Android targets
(`aarch64-linux-android`, `x86_64-linux-android`) and launched through Shizuku
(shell mode) or `su`. It opens `/dev/uinput` and creates an Android-visible Xbox
360-style evdev gamepad.

APK:

```text
app/build/outputs/apk/debug/app-debug.apk
```

## Test Android raw mode in an emulator

The emulator cannot expose a real Steam Controller over BLE/USB, so the debug
APK includes a fake Triton transport that emits numbered `0x45` reports. Run the
host-side emulator smoke test with:

```sh
nix run .#android-emulator-uhid-test
```

That command builds the debug APK, boots a headless Android emulator, starts the
app in fake/raw-UHID mode through `MainActivity`, and verifies that the app
connects to a host TCP server and sends raw `0x45` input frames.

To test the same Android fake transport against the repo's NixOS UHID service
module and real Linux `hidraw`/UHID plumbing, run the optional VM integration
app:

```sh
nix run .#android-emulator-uhid-vm-test
```

Both emulator commands require KVM and intentionally stay out of default flake
checks/CI.

## Android app configuration

Remote raw UHID and VIIPER modes need a server host/IP and port. Local uinput
mode does not use a remote server.

Default port conventions used by the UI:

- Raw UHID bridge: `3244`
- VIIPER Xbox fallback: `3242`

The main UI has a BLE/USB transport toggle plus mode buttons:

- `Raw` — preferred raw UHID path
- `Xbox` — VIIPER Xbox 360 fallback
- `Local Xbox` — local Android virtual Xbox 360 gamepad via Shizuku/root `/dev/uinput`
- `Stop`

USB is experimental/input-only; avoid it if the phone/controller USB setup is unstable.

## Server-side bridge

This repository now ships the UHID bridge under [`server/`](server/):

- [`server/src/main.zig`](server/src/main.zig): standalone Zig UHID daemon
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
        ({ pkgs, ... }: {
          services.steamless-uhid = {
            enable = true;
            package = steamlesslink.packages.${pkgs.system}.steamless-uhid-server;
            user = "steam";          # the user that runs Steam
            listenHost = "0.0.0.0";  # or keep 127.0.0.1 behind a TCP proxy/tunnel
            listenPort = 3244;
            openFirewall = true;
          };
        })
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
