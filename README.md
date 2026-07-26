# SteamlessLink

Android/Kotlin bridge for using a Steam Controller / Triton controller with a remote Linux Steam host.

Preferred path:

```text
Steam Controller BLE -> Android GATT -> raw Triton reports -> TCP -> Steamless Link host -> virtual controller -> Steam
```

Fallback paths:

```text
Steam Controller BLE/USB -> Android -> Triton parser -> VIIPER xbox360 stream
Steam Controller BLE/USB -> Android -> Triton parser -> local /dev/uinput Xbox gamepad
```

The Steamless Link path preserves the controller as a Valve/Steam Controller device, so Steam can use native Steam Controller configuration, battery queries, ping, and haptics. The VIIPER path is a known-good remote Xbox 360 fallback. The local uinput path is for Android games/apps on the phone and requires Shizuku shell access or root.

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
nix run .#android-emulator-link-test
```

That command builds the debug APK, boots a headless Android emulator, starts the
app in fake controller mode through `MainActivity`, and verifies that the app
connects to a host TCP server and sends raw `0x45` input frames.

To test the same Android fake transport against the repo's NixOS host module
and real Linux controller plumbing, run the optional VM integration app:

```sh
nix run .#android-emulator-link-vm-test
```

Both emulator commands require KVM and intentionally stay out of default flake
checks/CI.

## Android app configuration

Remote Steamless Link and VIIPER modes need a host/IP and port. Local uinput
mode does not use a remote server.

Default port conventions used by the UI:

- Steamless Link: `3244`
- VIIPER Xbox fallback: `3242`

The main UI has a BLE/USB transport toggle, a connection method dropdown, and Start/Stop buttons:

- `Steamless Link` — preferred controller path over TCP host/IP + port
- `Steamless Link Iroh` — controller path over an Iroh endpoint ticket
- `VIIPER Xbox` — VIIPER Xbox 360 fallback
- `Local Xbox` — local Android virtual Xbox 360 gamepad via Shizuku/root `/dev/uinput`

USB is experimental/input-only; avoid it if the phone/controller USB setup is unstable.

### Steamless Link over Iroh

Build the APK with the Android Iroh JNI library:

```sh
export IROH_JNI=$(nix build --print-out-paths .#iroh-android-jni)
nix develop -c gradle :app:assembleDebug
```

On the Steam host, run the host service, then run the Iroh proxy and paste its
printed endpoint ticket into the Android app's `Iroh endpoint ticket` field:

```sh
steamless-link-host --listen-host 127.0.0.1 --listen-port 3244
nix run .#steamless-link-iroh-proxy -- 127.0.0.1:3244
```

With the NixOS module, enable both services and read the ticket from the proxy
journal:

```nix
services.steamless-link-host = {
  enable = true;
  user = "steam";
  listenHost = "127.0.0.1";
  listenPort = 3244;

  iroh.enable = true;
};
```

```sh
journalctl -u steamless-link-iroh-proxy -b -o cat | grep '^endpoint' | tail -1
```

## Steam host

This repository ships the Steamless Link host under [`server/`](server/):

- [`server/src/main.zig`](server/src/main.zig): host daemon
- [`server/60-steamless-link-host.rules`](server/60-steamless-link-host.rules): udev permissions
- [`server/steamless-link-host.service`](server/steamless-link-host.service): example service
- [`nix/modules/steamless-link-host.nix`](nix/modules/steamless-link-host.nix): NixOS module

See [`server/README.md`](server/README.md) for Linux installation and protocol notes.

### NixOS module example

From a flake-based NixOS config:

```nix
{
  inputs.steamlesslink.url = "github:YOUR-USER/SteamlessLink";

  outputs = { self, nixpkgs, steamlesslink, ... }: {
    nixosConfigurations.steam-host = nixpkgs.lib.nixosSystem {
      modules = [
        steamlesslink.nixosModules.steamless-link-host
        ({ pkgs, ... }: {
          services.steamless-link-host = {
            enable = true;
            package = steamlesslink.packages.${pkgs.system}.steamless-link-host;
            user = "steam";          # the user that runs Steam
            listenHost = "0.0.0.0";  # or use 127.0.0.1 with iroh.enable
            listenPort = 3244;
            openFirewall = true;

            iroh = {
              enable = true;
              package = steamlesslink.packages.${pkgs.system}.steamless-link-iroh-proxy;
            };
          };
        })
      ];
    };
  };
}
```

The current protocol is unauthenticated raw TCP. Bind it only to trusted networks, firewall it to the Android device, or use a tunnel/proxy.

### Linux controller client

To forward a local Triton controller from one NixOS machine to another Steam
host, import `nixosModules.steamless-link-controller` and enable:

```nix
services.steamless-link-controller = {
  enable = true;
  host = "steam-host";
};
```

Capture is enabled by default: it temporarily rebinds the matching controller,
so local Steam loses access while the remote bridge runs. Toggle it at runtime:

```sh
systemctl stop steamless-link-controller-capture.service   # return it to Steam
systemctl start steamless-link-controller-capture.service  # forward remotely
```

`homeModules.steamless-link-controller` provides the same unprivileged bridge as
a user service when the desktop user already owns the hidraw device; it cannot
capture a controller from local Steam.

## BLE behavior

The app will:

- request Nearby Devices / Bluetooth permissions
- prefer bonded LE devices named `SteamController` or `Steam Ctrl*`
- otherwise scan for those names for 15 seconds
- discover Valve service `100f6c32-1735-4313-b402-38567131e5f3`
- enable notifications for Valve report characteristics `100f6c75` through `100f6c7a`
- reconstruct missing BLE report IDs from the characteristic UUID (`100f6c7a` -> `0x45`)
- forward numbered `0x45` Triton BLE input reports to the Steamless Link host
- proxy Steam feature reports through BLE report characteristic `100f6c34`
- proxy Steam output reports through BLE output characteristics `100f6cb5` through `100f6cbe`

In Steamless Link mode the app does **not** run its own periodic lizard-mode refresh; Steam owns feature/report traffic. In VIIPER fallback mode the app periodically sends lizard-mode-off itself.

Useful logs while developing:

```sh
journalctl -u steamless-link-host -n 120 --no-pager
tail -160 ~/.local/share/Steam/logs/controller.txt
adb logcat -d -v time -s ControllerBridge BluetoothGatt AndroidRuntime
```
