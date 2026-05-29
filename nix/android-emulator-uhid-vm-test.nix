{
  writeShellApplication,
  gradle,
  jdk17,
  androidSdk,
  testDriver,
}:

writeShellApplication {
  name = "steamless-android-emulator-uhid-vm-test";
  runtimeInputs = [
    gradle
    jdk17
    androidSdk
  ];
  text = ''
    set -euo pipefail

    export ANDROID_HOME=${androidSdk}/libexec/android-sdk
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
    export JAVA_HOME=${jdk17.home}
    export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/35.0.0/aapt2 ''${GRADLE_OPTS:-}"

    project_root="''${STEAMLESSLINK_ROOT:-$PWD}"
    cd "$project_root"

    gradle --no-daemon :app:assembleDebug
    export STEAMLESSLINK_APK="''${STEAMLESSLINK_APK:-$project_root/app/build/outputs/apk/debug/app-debug.apk}"
    export STEAMLESS_ANDROID_TEST_TMPDIR="''${STEAMLESS_ANDROID_TEST_TMPDIR:-$project_root/.tmp/android-emulator-vm}"
    mkdir -p "$STEAMLESS_ANDROID_TEST_TMPDIR"

    exec ${testDriver}/bin/nixos-test-driver
  '';
}
