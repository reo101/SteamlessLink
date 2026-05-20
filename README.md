# SteamlessLink

Android/Kotlin bridge for using a Steam Controller / Triton controller with a remote Steam host.

Preferred path:

```text
Steam Controller BLE -> Android GATT -> raw Triton reports -> TCP -> Steamless UHID bridge -> Linux UHID/hidraw -> Steam
```

Fallback path:

```text
Steam Controller BLE/USB -> Android -> Triton parser -> VIIPER xbox360 stream
```

The raw UHID path preserves the controller as a Valve/Steam Controller device, so Steam can use native Steam Controller configuration, battery queries, ping, and haptics. The VIIPER path is a known-good Xbox 360 fallback.

## Build / install

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

## Server-side requirements

A Steamless UHID bridge must run on the Steam host, or on a machine that can expose `/dev/uhid` to the Steam host. It needs to:

1. Listen for the app's raw TCP frame protocol.
2. Create a Linux UHID device named like a Steam Controller with Valve VID/PID `28de:1303`.
3. Inject Android `FRAME_INPUT` payloads as `UHID_INPUT2` reports.
4. Forward UHID `GET_REPORT` / `SET_REPORT` events to the Android app for BLE feature read/write passthrough.
5. Forward UHID `OUTPUT` events to the Android app for BLE output characteristic writes, used by haptics/ping/etc.
6. Ensure the Steam user can access the resulting hidraw node, usually with a udev rule matching the parent HID device and granting the `input` group or seat access.
7. Optionally expose the bridge through a TCP proxy/firewall rule if it should listen only on localhost internally.

The current server implementation is still prototyped as a NixOS module outside this Android app repository. A good next cleanup is to ship that module/daemon from this repository, so the Android app and matching UHID bridge are versioned together.

Useful logs while developing:

```sh
journalctl -u steamless-uhid -n 120 --no-pager
tail -160 ~/.local/share/Steam/logs/controller.txt
adb logcat -d -v time -s ControllerBridge BluetoothGatt AndroidRuntime
```
