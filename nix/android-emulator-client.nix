{
  writeShellApplication,
  androidSdk,
  androidApk,
  coreutils,
  gnugrep,
  gnused,
}:

writeShellApplication {
  name = "steamless-android-emulator-client";
  excludeShellChecks = [ "SC2329" ];
  runtimeInputs = [
    androidSdk
    coreutils
    gnugrep
    gnused
  ];
  text = ''
    set -euo pipefail

    export ANDROID_HOME=${androidSdk}/libexec/android-sdk
    export ANDROID_SDK_ROOT="$ANDROID_HOME"

    avdmanager="$(command -v avdmanager)"
    adb="$(command -v adb)"
    emulator="$(command -v emulator)"
    for tool in "$avdmanager" "$adb" "$emulator"; do
      if [ ! -x "$tool" ]; then
        echo "error: Android SDK tool not found: $tool" >&2
        exit 1
      fi
    done

    project_root="''${STEAMLESSLINK_ROOT:-$PWD}"
    package_name="xyz.reo101.steamlesslink"
    avd_name="steamlesslink-e2e"
    system_image="system-images;android-35;google_apis;x86_64"
    host_port="''${STEAMLESS_ANDROID_TEST_PORT:-33244}"
    adb_serial="''${STEAMLESS_ANDROID_TEST_SERIAL:-emulator-5554}"
    bridge_host="''${STEAMLESS_ANDROID_BRIDGE_HOST:-127.0.0.1}"
    ready_file="''${STEAMLESS_ANDROID_READY_FILE:-}"
    stop_file="''${STEAMLESS_ANDROID_STOP_FILE:-}"
    hold="''${STEAMLESS_ANDROID_HOLD:-0}"
    tmp_parent="''${STEAMLESS_ANDROID_TEST_TMPDIR:-$project_root/.tmp/android-emulator}"
    mkdir -p "$tmp_parent"
    workdir="$(mktemp -d "$tmp_parent/run.XXXXXXXX")"
    export ANDROID_AVD_HOME="$workdir/avd"
    export ANDROID_EMULATOR_HOME="$workdir/emulator-home"
    export ADB_VENDOR_KEYS="$workdir/adb-keys"

    emulator_pid=""
    cleanup() {
      set +e
      "$adb" -s "$adb_serial" emu kill >/dev/null 2>&1 || true
      if [ -n "$emulator_pid" ]; then wait "$emulator_pid" 2>/dev/null || true; fi
      rm -rf "$workdir"
    }
    trap cleanup EXIT

    if [ ! -e /dev/kvm ] && [ "''${STEAMLESS_ANDROID_TEST_REQUIRE_KVM:-1}" = 1 ]; then
      echo "error: /dev/kvm is required for the emulator test" >&2
      echo "       set STEAMLESS_ANDROID_TEST_REQUIRE_KVM=0 to try without KVM" >&2
      exit 1
    fi

    cd "$project_root"
    apk="''${STEAMLESSLINK_APK:-${androidApk}/app-debug.apk}"

    mkdir -p "$ANDROID_AVD_HOME" "$ANDROID_EMULATOR_HOME"
    printf 'no\n' | "$avdmanager" create avd \
      --force \
      --name "$avd_name" \
      --package "$system_image" \
      --device pixel >/dev/null
    sed -i \
      -e 's/^disk[.]dataPartition[.]size=.*/disk.dataPartition.size=2G/' \
      -e 's/^hw[.]ramSize=.*/hw.ramSize=1536/' \
      -e 's/^vm[.]heapSize=.*/vm.heapSize=256/' \
      "$ANDROID_AVD_HOME/$avd_name.avd/config.ini"

    "$adb" start-server >/dev/null
    "$emulator" \
      -avd "$avd_name" \
      -no-window \
      -no-snapshot \
      -no-audio \
      -no-boot-anim \
      -gpu swiftshader_indirect \
      -no-metrics \
      -partition-size 2048 \
      -port 5554 \
      -netdelay none \
      -netspeed full \
      >"$workdir/emulator.log" 2>&1 &
    emulator_pid=$!

    device_deadline=$((SECONDS + 60))
    while [ "$SECONDS" -lt "$device_deadline" ]; do
      if "$adb" -s "$adb_serial" get-state >/dev/null 2>&1; then
        break
      fi
      if ! kill -0 "$emulator_pid" 2>/dev/null; then
        echo "error: emulator exited before adb saw $adb_serial" >&2
        tail -100 "$workdir/emulator.log" >&2 || true
        exit 1
      fi
      sleep 2
    done
    if ! "$adb" -s "$adb_serial" get-state >/dev/null 2>&1; then
      echo "error: adb did not see $adb_serial" >&2
      tail -100 "$workdir/emulator.log" >&2 || true
      exit 1
    fi

    boot_deadline=$((SECONDS + 180))
    booted=""
    while [ "$SECONDS" -lt "$boot_deadline" ]; do
      booted="$($adb -s "$adb_serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
      if [ "$booted" = 1 ]; then break; fi
      sleep 2
    done
    if [ "$booted" != 1 ]; then
      echo "error: emulator did not boot" >&2
      tail -100 "$workdir/emulator.log" >&2 || true
      exit 1
    fi

    "$adb" -s "$adb_serial" install -r "$apk" >/dev/null
    "$adb" -s "$adb_serial" install -r "''${STEAMLESSLINK_TEST_APK:-${androidApk}/app-debug-androidTest.apk}" >/dev/null
    "$adb" -s "$adb_serial" shell pm grant "$package_name" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
    "$adb" -s "$adb_serial" shell pm grant "$package_name" android.permission.BLUETOOTH_CONNECT >/dev/null 2>&1 || true
    "$adb" -s "$adb_serial" shell pm grant "$package_name" android.permission.BLUETOOTH_SCAN >/dev/null 2>&1 || true
    "$adb" -s "$adb_serial" reverse "tcp:$host_port" "tcp:$host_port" >/dev/null
    "$adb" -s "$adb_serial" logcat -c >/dev/null || true

    "$adb" -s "$adb_serial" shell wm dismiss-keyguard >/dev/null 2>&1 || true
    "$adb" -s "$adb_serial" shell am instrument -w \
      -e class xyz.reo101.steamlesslink.testing.BridgeAutomationInstrumentationTest \
      -e remoteBridge true -e host "$bridge_host" -e port "$host_port" -e mode uhid-raw \
      -e durationSeconds 300 \
      "$package_name.test/androidx.test.runner.AndroidJUnitRunner" >"$workdir/forwarding.log" &

    ready_deadline=$((SECONDS + 45))
    while [ "$SECONDS" -lt "$ready_deadline" ]; do
      logs="$($adb -s "$adb_serial" logcat -d -v time -s ControllerBridge AndroidRuntime 2>/dev/null || true)"
      if printf '%s\n' "$logs" | grep -q 'Connected to Steamless Link host'; then
        if [ -n "$ready_file" ]; then printf 'ready\n' > "$ready_file"; fi
        if [ "$hold" = 1 ]; then
          while true; do
            if [ -n "$stop_file" ] && [ -e "$stop_file" ]; then exit 0; fi
            sleep 1
          done
        fi
        exit 0
      fi
      if printf '%s\n' "$logs" | grep -q 'FATAL EXCEPTION'; then
        printf '%s\n' "$logs" >&2
        exit 1
      fi
      sleep 1
    done

    echo "error: Android app did not connect to the Steamless Link host" >&2
    "$adb" -s "$adb_serial" logcat -d -v time -s ControllerBridge FakeTritonTransport AndroidRuntime >&2 || true
    exit 1
  '';
}
