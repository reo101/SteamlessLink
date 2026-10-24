{
  writeShellApplication,
  androidApk,
  coreutils,
  testDriver,
}:

writeShellApplication {
  name = "steamless-android-emulator-link-vm-test";
  runtimeInputs = [ coreutils ];
  text = ''
    set -euo pipefail

    project_root="''${STEAMLESSLINK_ROOT:-$PWD}"
    cd "$project_root"

    export STEAMLESSLINK_APK="''${STEAMLESSLINK_APK:-${androidApk}/app-debug.apk}"
    export STEAMLESS_ANDROID_TEST_TMPDIR="''${STEAMLESS_ANDROID_TEST_TMPDIR:-$project_root/.tmp/android-emulator-vm}"
    mkdir -p "$STEAMLESS_ANDROID_TEST_TMPDIR"

    exec ${testDriver}/bin/nixos-test-driver
  '';
}
