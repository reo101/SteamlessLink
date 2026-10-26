# Release procedure

## Build and identify artifacts

1. Record the Jujutsu commit ID and confirm that the working copy has no changes.
2. Run `nix build .#android-apk`. Keep `build-info.txt` with the APKs. It records the version and the Nix source path, which identifies the source content.
3. Run the emulator and kernel commands in [VALIDATION.md](VALIDATION.md).
4. Complete the physical-device checks in that document. Record skips as skips, not passes.
5. If a dependency changes, update the Gradle dependency manifest or native fixed-output hash as described in the main README.

Debug APKs use the public repository key. They are signed test artifacts, not release artifacts.

## Sign a release outside the Nix store

Keep the release keystore outside this repository and outside all Nix derivations. Do not pass private key material through a Nix expression, source file, command argument, or build log.

Build an unsigned release in the development shell. Set an increasing version code and the release version:

```sh
nix develop .#build

gradle -Psteamless.versionCode=2 -Psteamless.versionName=0.2.0 :app:assembleRelease
"$ANDROID_HOME/build-tools/35.0.0/zipalign" -p -f 4 \
  app/build/outputs/apk/release/app-release-unsigned.apk \
  app/build/outputs/apk/release/app-release-aligned.apk
"$ANDROID_HOME/build-tools/35.0.0/apksigner" sign \
  --ks "$RELEASE_KEYSTORE" --ks-key-alias "$RELEASE_KEY_ALIAS" \
  --out app/build/outputs/apk/release/app-release.apk \
  app/build/outputs/apk/release/app-release-aligned.apk
"$ANDROID_HOME/build-tools/35.0.0/apksigner" verify --verbose --print-certs \
  app/build/outputs/apk/release/app-release.apk
```

The signing tool prompts for passwords. This procedure does not create a keystore or select a signing identity. Record the public signing certificate fingerprint and artifact SHA-256 hashes with the commit ID.

If the installed app uses another signing key, Android rejects an update. Do not uninstall it as a workaround without the user's consent. Uninstallation deletes preferences and the controller identity. A new installation needs a new host allowlist entry.

## Compatibility and security

- The app supports Android API 26 and later. BLE scanning on API 26–30 needs location permission and the platform's location service. API 31 and later use Nearby Devices permissions.
- Local output needs a usable `/dev/uinput` and authorized Shizuku/root. A successful process launch is not sufficient; the helper must report readiness.
- Raw TCP remains unauthenticated. Keep it on loopback or a restricted LAN/VPN.
- Iroh requires an explicit controller-ID allowlist. Encryption does not grant authorization.
- Host and Android releases must agree on the device-bundle protocol. Old raw single-device clients remain supported.
- Extended HID exposes independent gamepad, touchpad, and IIO devices. It does not provide automatic Steam gyro integration or haptics.
