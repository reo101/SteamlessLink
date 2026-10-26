# SteamlessLink

Android/Kotlin bridge for using a Steam Controller / Triton controller with a remote Linux Steam host.

Preferred path:

```text
Steam Controller BLE -> Android GATT -> raw Triton reports -> TCP -> Steamless Link host -> virtual controller -> Steam
```

Alternative paths:

```text
Steam Controller BLE/USB -> Android -> Zig generic-HID mapper -> TCP -> Steamless Link host -> generic UHID gamepad -> Steam
Steam Controller BLE/USB -> Android -> Zig extended-HID mapper -> TCP -> gamepad + two touchpads + IIO motion sensors
Steam Controller BLE/USB -> Android -> Zig Triton mapper -> local /dev/uinput Xbox gamepad
```

The Steamless Link path preserves the controller as a Valve/Steam Controller device, so Steam can use native Steam Controller configuration, battery queries, ping, and haptics. `Generic HID Gamepad` instead creates a standard Linux HID gamepad, with ordinary buttons, sticks, triggers, and a hat switch. It has no output or haptics yet. The local uinput path is for Android games/apps on the phone and requires Shizuku shell access or root.

## Build / install Android app

```sh
nix build .#android-apk
adb install result/app-debug.apk
```

The Nix derivation builds both Android ABIs and runs Android lint, JVM tests,
core Zig tests, and JNI adapter tests. It installs `app-debug.apk` and
`app-debug-androidTest.apk` in its output. Gradle dependencies have content
hashes in `nix/gradle-dependencies.json`. Zig dependencies come from the fixed-output
`native-dependencies` package. The APK build does not fetch dependencies.

Debug APKs use the public test key in `app/debug.keystore` (password `android`).
Do not use this key for releases or authentication. If an installed APK uses
a different debug key, Android rejects an update. Uninstalling that APK deletes
its app data. This change does not uninstall anything automatically.

For incremental development and installation, use:

```sh
nix develop -c gradle :app:check
nix develop -c gradle :app:installDebug
```

CI builds `.#android-apk` in the Nix sandbox. Relevant source changes select
emulator and Linux kernel integration jobs. Weekly and opt-in runs execute the
full matrix. See [validation and measurements](docs/VALIDATION.md) and the
[release procedure](docs/RELEASE.md). Physical USB and privileged Android tests remain opt-in.
`devShells.build` omits language servers and developer diagnostics. The default
shell extends it with those tools; both share the SDK, Zig, Gradle, and JNI configuration.
The flake uses Zig 0.17.0 for Android and Linux builds, with ZLS 0.17.0 in the
default shell. The Iroh proxy uses Rust Iroh 1.4.1. Android uses Kotlin/FFI
1.2.0, whose native dependency is also Iroh 1.4.1. The Android initializer is
vendored from that release. Nix builds the Iroh JNI library for both Android
ABIs. Gradle delegates the protocol JNI library and uinput helper to Zig build
steps. Generated source APIs connect their outputs to Android compilation,
lint, and packaging.

`native/build.zig` builds the JNI library and generates its types and function
table per target. `native/build.zig.zon` pins AOSP `libnativehelper`
(Android 15.0.0_r1) and Codeberg's `ziglang/translate-c` 2.0.2 by revision and
content hash. Zig fetches these dependencies into `native/zig-pkg/`. The
`translate-c` package runs on the build host and translates `include_jni/jni.h`
for the selected Android target. It does not build `libnativehelper` or link
libc into the JNI library. No NDK installation is required.

Gradle invokes `zig build` for each Android ABI. To build the JNI library alone:

```sh
cd native
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe -Dstrip=true
```

The library is installed to `native/zig-out/lib/libsteamless_protocol.so`.
If the dependencies are already fetched, use `--system zig-pkg` to disable network
fetching. Sandboxed Nix builds receive a prefetched package directory through
`STEAMLESS_ZIG_PACKAGES`. To refresh Gradle dependency hashes after a dependency
change, run the Nix-provided updater from the repository root:

```sh
$(nix build --no-link --print-out-paths .#android-apk.mitmCache.updateScript)
```

If the Zig dependency manifests change, update the fixed-output hash in
`nix/native-dependencies.nix` too.

The debug APK bundles the Zig/JNI mapper by default for `arm64-v8a` and
`x86_64`. Both generic HID profiles and local Xbox mode report that they are unavailable
when the native library cannot load; raw transport still works. Omit it only for a
raw-transport-only build:

```sh
nix develop -c gradle -Psteamless.buildZig=false :app:assembleDebug
```

Local Android uinput mode bundles its small privileged helper by default. It
only works through Shizuku or root on devices that expose `/dev/uinput`; other
devices report that the local mode is unavailable. Omit the helper only when
needed:

```sh
nix develop -c gradle -Psteamless.buildUinputHelper=false :app:assembleDebug
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

That command uses the Nix-built app and test APKs, boots a headless Android emulator,
runs the instrumentation suite, then uses the test APK to start fake controller
mode and checks raw `0x45` input frames. Exported activity requests require
confirmation; they cannot silently start or replace a bridge.

To exercise the generic profile's device-info frame and its 10-byte HID reports
instead:

```sh
STEAMLESS_ANDROID_TEST_MODE=uhid-generic-gamepad nix run .#android-emulator-link-test
```

The extended profile test also checks the four-device handshake, indexed sensor
feature requests/replies, and all five input reports:

```sh
STEAMLESS_ANDROID_TEST_MODE=uhid-extended-gamepad nix run .#android-emulator-link-test
```

The host kernel test exercises real Zig-generated descriptors and samples through
UHID: rear buttons, both touchpads, sensor controls, direct and buffered IIO reads,
and device removal on disconnect:

```sh
nix build .#checks.x86_64-linux.steamless-link-host-nixos
```

To test the same Android fake transport against the repo's NixOS host module
and real Linux controller plumbing, run the optional VM integration app:

```sh
nix run .#android-emulator-link-vm-test
```

Both emulator commands require KVM. CI runs them weekly or when the workflow's
`integration` input is enabled. They stay out of default flake checks. Use
`STEAMLESSLINK_APK` and `STEAMLESSLINK_TEST_APK` to override the APK paths.

## Android app configuration

Remote Steamless Link and both generic HID modes need a host/IP and port.
Local uinput mode does not use a remote server.

The UI defaults the remote controller modes to Steamless Link port `3244`.

The main UI has a BLE/USB transport toggle, a connection method dropdown, and Start/Stop buttons:

- `Steamless Link` — preferred controller path over TCP host/IP + port
- `Steamless Link Iroh` — controller path over an Iroh endpoint ticket
- `Generic HID Gamepad` — standard HID gamepad over direct raw TCP; no haptics yet
- `Extended Generic HID` - gamepad with rear buttons, two independent absolute touchpads, and standards-based gyro/accelerometer sensors over TCP
- `Local Xbox (Shizuku/root)` — local Android virtual Xbox 360 gamepad via `/dev/uinput`

USB requires Android's USB-device permission. Raw TCP and Iroh modes forward the
wired controller's actual identity and HID descriptor, input reports, feature
GET/SET requests, and interrupt output reports. Steam owns controller settings in
raw modes; mapped modes refresh lizard-mode suppression locally. The bridge waits
for USB input before opening the remote stream. After unplugging/reconnecting the
controller, tap Start again. A capture failure stops the session and closes its
output device or remote stream. It does not reconnect capture automatically.
Raw modes forward numbered input reports even when the diagnostic parser does
not recognize their report ID.

The opt-in USB instrumentation tests require a wired controller with permission
already granted. Stop the bridge, install both debug APKs, then run:

```sh
adb shell am instrument -w -r -e usbHardware true \
  -e class xyz.reo101.steamlesslink.usb.UsbTritonTransportInstrumentationTest \
  xyz.reo101.steamlesslink.test/androidx.test.runner.AndroidJUnitRunner
```

These tests cover permission-receiver lifecycle, real USB input and identity,
a controller-info feature query/reply, and zero-rumble interrupt output. They are
skipped in normal emulator runs.

### Controller testing ground

Open **Testing ground** from the main screen. It observes the active BLE/USB
bridge without changing its output mode. Four pages separate:

- **Captured input:** normalized Triton state reports, raw bytes, sticks,
  triggers, pad coordinates/pressure, raw IMU fields, and a latched button mask.
  BLE report IDs are reconstructed by the transport; these are not radio packets.
- **Translated / outgoing:** the actual report sample offered to the active
  output, plus independent default Xbox, saved local Xbox, generic HID, and
  extended HID previews. Queue acceptance is not remote delivery. Extended
  previews include sensors even when host controls suppress actual streaming.
- **Android receipt:** gamepad key/motion events actually delivered to this
  foreground activity, with device identity, held buttons and recent key history.
  Enumerated devices alone do not prove input delivery. Test gamepad buttons are
  consumed so they do not operate the UI; use the on-screen Back button to leave.
- **Local mapping profile:** bind L4/L5/R4/R5 to standard Xbox buttons, map the
  touched right pad to the right stick, and add right-pad-touch-activated gyro
  yaw/pitch to that stick. Gyro sensitivity is the angular speed for full stick
  deflection (30-720 degrees/s). Defaults preserve the original Xbox mapping.

**Capture BLE/USB** explicitly replaces the current bridge with capture-only
mode: no server, Shizuku, or virtual gamepad required. This mode enables IMU
reports for previews. Observing an existing raw bridge does not enable IMU or
change controller settings. Save the local profile and restart local output to
apply it; remote raw/basic/extended outputs ignore these settings.

Samples refresh at most 10 Hz while the tester is resumed. **Freeze sample**
freezes only capture/output previews, not the bridge or Android event collection.
**Clear** resets the display/latches. No recording is saved to disk. Sample age
indicates stale input. Only recognized Triton state reports are displayed.

The local mapper is a prototype: device-local angular velocity, no gyro bias
calibration or orientation fusion, no mouse/trackball output, no native sensor
passthrough, and no rumble. The virtual Xbox device retains its existing roughly
12.5% stick flat zone. Gyro contribution is added to the physical/pad stick and
clamped. Pad mapping disengages on touch release.

Run the instrumentation suite with the phone unlocked. It tests fake capture,
raw/generic/extended TCP output against a loopback receiver, and native mapping.
To also verify a synthetic mapped rear-button press/release through the real
local helper and Android's input framework, opt in with authorized Shizuku/root:

```sh
adb shell am instrument -w -r -e localHardware true \
  xyz.reo101.steamlesslink.test/androidx.test.runner.AndroidJUnitRunner
```

Instrumentation stops the running bridge and closes the app when it finishes.
Restart your desired bridge afterward. USB hardware tests remain a separate
`usbHardware` opt-in.

### Extended Generic HID

This is a separate standards-first profile, not Sony/Xbox emulation. It requires
an updated host that acknowledges the four-device bundle. The existing small
Generic HID Gamepad and legacy raw protocol remain available unchanged.

Linux exposes the gamepad and each touchpad through evdev. Motion binds to
`hid-sensor-hub` and the `hid-sensor-accel-3d` / `hid-sensor-gyro-3d` IIO drivers.
A consumer reads motion through IIO, not the gamepad's evdev node. **Steam does
not automatically associate these independent devices or use these IIO sensors
as controller gyro.** This profile does not add haptics or an SDL driver.

BLE/USB capture enables Triton's raw accel/gyro reports in this mode. Sensor
streaming is independently controlled by the host for each sensor; it defaults
to off. See [the host protocol and report layout](server/README.md#extended-generic-hid-profile).

### Steamless Link over Iroh

Build the APK with the Android Iroh JNI library:

```sh
export IROH_JNI=$(nix build --print-out-paths .#iroh-android-jni)
nix develop -c gradle :app:assembleDebug
```

In Android, tap **Show Iroh controller ID**. The app copies its public ID.
Its private identity remains in app-private, non-backed-up storage and survives
connection and process restarts. Uninstalling the app removes that identity.

On the Steam host, allow that controller ID, run the host service, then run the
Iroh proxy and paste its endpoint ticket into Android's `Iroh endpoint ticket` field:

```sh
steamless-link-host --listen-host 127.0.0.1 --listen-port 3244
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/steamless-link-iroh-proxy"
install -d -m 700 "$state_dir"
nix run .#steamless-link-iroh-proxy -- \
  --identity-key "$state_dir/identity.key" --ticket-file "$state_dir/ticket" \
  --allow-peer "$CONTROLLER_ID" 127.0.0.1:3244
```

Repeat `--allow-peer` for each authorized controller. An empty allowlist is
rejected. Unknown peers cannot open a TCP connection to the host. An Iroh ticket
provides routing information; it does not grant controller access.

The host identity key is 32 secret bytes, mode `0600`. `STEAMLESS_IROH_IDENTITY_KEY`
sets the same path for service managers; `--identity-key` takes precedence.
`--ticket-file` (or `STEAMLESS_IROH_TICKET_FILE`) writes the current ticket as a
private file for the host's raw-TCP bootstrap action. Reuse the identity key
across restarts so existing tickets keep the same endpoint identity. Back it up
only to migrate the host, keep it private, and do not run two hosts with the
same key at once.

In Android, set the direct raw TCP host and port, then tap `Fetch Iroh ticket &
Start`. It retrieves the ticket once over that trusted direct path, saves it,
and reconnects through Iroh.

With the NixOS module, enable both services and read the ticket from the proxy
journal:

```nix
services.steamless-link-host = {
  enable = true;
  user = "steam";
  listenHost = "127.0.0.1";
  listenPort = 3244;

  iroh = {
    enable = true;
    allowedPeers = [ "CONTROLLER_PUBLIC_ID" ];
  };
};
```

```sh
journalctl -u steamless-link-iroh-proxy -b -o cat | grep '^Forwarding Iroh ' | tail -1 | awk '{print $3}'
```

The NixOS module wires its private ticket file into the host automatically.
Only let trusted LAN/VPN peers reach the raw TCP port, they can request this
Iroh route.

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
              allowedPeers = [ "CONTROLLER_PUBLIC_ID" ];
              package = steamlesslink.packages.${pkgs.system}.steamless-link-iroh-proxy;
            };
          };
        })
      ];
    };
  };
}
```

The Iroh proxy stores its identity in `/var/lib/steamless-link-iroh-proxy/identity.key`; systemd creates the directory with mode `0700` and the proxy writes the key with mode `0600`. Back up that key only to migrate the host, and never run two hosts with the same key simultaneously.

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
- enable notifications for the current Valve state characteristic, preferring
  `100f6c7c` (`0x47`) and falling back to `100f6c7a` (`0x45`)
- reconstruct the missing BLE report ID from its characteristic UUID
- forward numbered `0x47` or legacy `0x45` Triton BLE input reports to the
  Steamless Link host
- proxy Steam feature reports through BLE report characteristic `100f6c34`
- proxy Steam output reports through BLE output characteristics `100f6cb5` through `100f6cbe`

In Steamless Link mode, including Iroh, the app does **not** run its own periodic lizard-mode refresh; Steam owns feature/report traffic. In Generic HID Gamepad and Local Xbox modes the app periodically sends lizard-mode-off itself.

Useful logs while developing:

```sh
journalctl -u steamless-link-host -n 120 --no-pager
tail -160 ~/.local/share/Steam/logs/controller.txt
adb logcat -d -v time -s ControllerBridge BluetoothGatt AndroidRuntime
```
