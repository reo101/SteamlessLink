# Validation

## Automated checks

```sh
nix develop .#build -c gradle :app:check
nix build .#android-apk .#steamless-link-host .#steamless-link-controller \
  .#checks.x86_64-linux.iroh-proxy-roundtrip
nix run .#android-emulator-link-test
STEAMLESS_ANDROID_TEST_MODE=uhid-generic-gamepad nix run .#android-emulator-link-test
STEAMLESS_ANDROID_TEST_MODE=uhid-extended-gamepad nix run .#android-emulator-link-test
nix run .#android-emulator-iroh-test
nix build .#checks.x86_64-linux.steamless-link-host-nixos \
  .#checks.x86_64-linux.steamless-link-controller-nixos \
  .#checks.x86_64-linux.steamless-uinput-gamepad-nixos
```

The emulator and kernel checks require KVM. CI selects them for relevant source changes and runs the full matrix on its weekly schedule or manual integration request.

The Iroh check uses public test keys and loopback addresses. It verifies an unknown controller cannot open the TCP target, persistent identity, echo traffic, response after EOF, and target disconnect.

`core/src/testdata/triton-state-vectors.tsv` contains synthetic normalized reports shared by the Kotlin and Zig parser tests. These are not captured hardware traces. Cross-profile tests verify stick direction while preserving the internal Xbox packet convention.

## Measurements

The instrumentation suite emits `transportLatencyUs` with 300 samples at a nominal 250 Hz. It measures Android raw-TCP enqueue-to-loopback-receipt latency and a synthetic feature-query round trip. It reports p50, p95, and p99 in microseconds. These are measurements, not fixed CI timing limits.

`Steamless Link metrics:` log lines report sent samples, dropped samples, maximum queue delay, and maximum write duration. They describe this process only. A completed write does not prove remote application receipt. Queue limits drop old whole samples under congestion; the JVM test verifies the bound with a stalled writer.

Do not label emulator loopback results as BLE, USB, Iroh WAN, Android game, or Steam end-to-end latency. For those paths, collect paired capture/receipt traces or a physical input-to-display measurement. Record device model, OS, transport, sample rate, network, and load with each result. Avoid subtracting timestamps from unsynchronized hosts.

## Physical-device acceptance

Installing instrumentation and running it stops the bridge. Keep the phone unlocked. Use an explicit ADB serial when more than one device is connected. Do not uninstall an app with a different signing key without consent.

Run the normal suite, then opt in to hardware tests:

```sh
adb -s "$SERIAL" install -r result/app-debug.apk
adb -s "$SERIAL" install -r result/app-debug-androidTest.apk
adb -s "$SERIAL" shell am instrument -w -r \
  -e usbHardware true -e localHardware true \
  xyz.reo101.steamlesslink.test/androidx.test.runner.AndroidJUnitRunner
```

USB tests need a connected supported controller and granted USB permission. Local tests need authorized Shizuku/root. Record unavailable prerequisites rather than claiming hardware coverage from a passing suite with skips.

For a coordinated real-capture disconnect check, run the test below. Keep the
controller on until `hardwareReady` appears, then power it off. Use
`-e transport usb` for an unplug check. The test requires authorized local output and waits
up to 90 seconds for disconnect and virtual-device removal.

```sh
adb -s "$SERIAL" shell am instrument -w -r \
  -e captureHardware true -e localHardware true -e transport ble \
  -e class xyz.reo101.steamlesslink.testing.CaptureHardwareInstrumentationTest \
  xyz.reo101.steamlesslink.test/androidx.test.runner.AndroidJUnitRunner
```

For each supported capture/output combination, record the following:

| Check | Expected result |
| --- | --- |
| BLE and USB capture | Input advances, identity/report IDs match the transport |
| Raw TCP and Iroh | Steam receives buttons, axes, battery/feature replies, and haptics |
| Generic HID | Both sticks move in the expected physical direction; buttons release |
| Extended HID | Rear buttons and both pads work; sensor enable/disable and IIO reads work |
| Local Xbox | Android receives press/release and axis events from the virtual device |
| Controller power-off or USB unplug | Session stops, output closes, no stuck held input |
| Start after reconnect | A new session starts without late callbacks changing it |
| Bluetooth disable during setup | Capture fails closed and does not become ready later |
| Wi-Fi disconnect/reconnect | Remote connection retries against the current network |
| Host restart | Output reconnects while capture remains active |
| Stop during ticket fetch | Request closes and cannot restart the bridge |
| Screen-off and return | Record whether capture survives on this device; no stale output claims |
| Repeated Start/Stop under input | UI remains responsive and resources return to baseline |

A kernel test proves Linux input plumbing, not Steam application behavior. The Android receipt screen proves delivery to that foreground activity, not another game.

## Recorded hardening validation

The verified debug APK has SHA-256
`09a8d824cfdfa66744942d639836faf25512acfd2877420d8fd4a0462f63b8f4`.
Its `build-info.txt` identifies source `/nix/store/2yywzhqy6lj4rwcd2gmwwzfrcgmvnslb-source`.

- JVM: 38 tests, zero failures. Core: 28 tests. Host: 7. Linux client: 5. JNI adapter: 7. Rust proxy: 8.
- Nix APK/package checks, all three Linux kernel tests, and the authorized Iroh round-trip check passed.
- Raw, generic, extended, and Iroh emulator profiles passed. The emulator-to-NixOS-host test also passed, including real UHID input and reverse output traffic.
- Pixel 7 Pro: normal suite `OK (21 tests)`, with opt-in hardware cases skipped. The separate privileged test passed and verified mapped button press/release through Android.
- Real BLE capture and local-output removal on controller power-off passed on retry. The first attempt completed setup but did not expose an output sample to the observer. Its cause was not established.
- Two phone loopback runs measured p50 721/2649, p95 2189/4143, and p99 4331/5008 microseconds. Both used 300 samples with zero queue drops. These are not BLE or WAN latency measurements.
- Unsigned release assembly passed with explicit version-code/name overrides. No release key was created or used.

USB hardware acceptance is blocked by a user-reported phone kernel panic when USB devices attach. No USB test was attempted. Live Steam receipt, screen-off behavior, and physical Wi-Fi handover remain unverified.

An initial phone startup failure came from `/dev/null` being a regular file with the wrong SELinux label. Android's zygote aborted before app startup. A user-performed reboot restored the `1:3` character device and normal launch. No app change or SELinux relaxation was used for that problem.
