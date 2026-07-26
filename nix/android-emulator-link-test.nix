{
  lib,
  writeShellApplication,
  androidSdk,
  gradle,
  jdk17,
  python3,
  steamlessIrohJni,
  steamlessLinkIrohProxy,
}:

writeShellApplication {
  name = "steamless-android-emulator-link-test";
  excludeShellChecks = [ "SC2329" ];
  runtimeInputs = [
    androidSdk
    gradle
    jdk17
    python3
  ];
  text = ''
    set -euo pipefail

    export ANDROID_HOME=${androidSdk}/libexec/android-sdk
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
    export JAVA_HOME=${jdk17.home}
    export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/35.0.0/aapt2 ''${GRADLE_OPTS:-}"
    export IROH_JNI=${steamlessIrohJni}

    avdmanager="$ANDROID_HOME/cmdline-tools/20.0/bin/avdmanager"
    if [ ! -x "$avdmanager" ]; then
      echo "error: avdmanager not found at $avdmanager" >&2
      exit 1
    fi

    project_root="''${STEAMLESSLINK_ROOT:-$PWD}"
    package_name="xyz.reo101.steamlesslink"
    avd_name="steamlesslink-e2e"
    system_image="system-images;android-35;google_apis;x86_64"
    host_port="''${STEAMLESS_ANDROID_TEST_PORT:-33244}"
    iroh_port="''${STEAMLESS_ANDROID_IROH_PORT:-34244}"
    iroh_mode="''${STEAMLESS_ANDROID_TEST_IROH:-0}"
    adb_serial="''${STEAMLESS_ANDROID_TEST_SERIAL:-emulator-5554}"
    tmp_parent="''${STEAMLESS_ANDROID_TEST_TMPDIR:-$project_root/.tmp/android-emulator}"
    mkdir -p "$tmp_parent"
    workdir="$(mktemp -d "$tmp_parent/run.XXXXXXXX")"
    export ANDROID_AVD_HOME="$workdir/avd"
    export ANDROID_EMULATOR_HOME="$workdir/emulator-home"
    export ADB_VENDOR_KEYS="$workdir/adb-keys"

    emulator_pid=""
    server_pid=""
    proxy_pid=""
    cleanup() {
      set +e
      if [ -n "$proxy_pid" ]; then kill "$proxy_pid" 2>/dev/null || true; fi
      if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
      "$ANDROID_HOME/platform-tools/adb" -s "$adb_serial" emu kill >/dev/null 2>&1 || true
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
    gradle --no-daemon :app:assembleDebug

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

    "$ANDROID_HOME/platform-tools/adb" start-server >/dev/null
    "$ANDROID_HOME/emulator/emulator" \
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
      if "$ANDROID_HOME/platform-tools/adb" -s "$adb_serial" get-state >/dev/null 2>&1; then
        break
      fi
      if ! kill -0 "$emulator_pid" 2>/dev/null; then
        echo "error: emulator exited before adb saw $adb_serial" >&2
        tail -100 "$workdir/emulator.log" >&2 || true
        exit 1
      fi
      sleep 2
    done
    if ! "$ANDROID_HOME/platform-tools/adb" -s "$adb_serial" get-state >/dev/null 2>&1; then
      echo "error: adb did not see $adb_serial" >&2
      tail -100 "$workdir/emulator.log" >&2 || true
      exit 1
    fi

    boot_deadline=$((SECONDS + 180))
    booted=""
    while [ "$SECONDS" -lt "$boot_deadline" ]; do
      booted="$($ANDROID_HOME/platform-tools/adb -s "$adb_serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
      if [ "$booted" = 1 ]; then break; fi
      sleep 2
    done
    if [ "$booted" != 1 ]; then
      echo "error: emulator did not boot" >&2
      tail -100 "$workdir/emulator.log" >&2 || true
      exit 1
    fi

    cat > "$workdir/raw-server.py" <<'PY'
    import pathlib, socket, struct, sys, time

    port = int(sys.argv[1])
    result = pathlib.Path(sys.argv[2])
    log = pathlib.Path(sys.argv[3])
    deadline = time.monotonic() + 45
    reports = 0
    saw_report = False

    def write_frame(sock, frame_type, payload):
        sock.sendall(bytes([frame_type]) + struct.pack('!H', len(payload)) + payload)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(('127.0.0.1', port))
        server.listen(1)
        server.settimeout(45)
        conn, addr = server.accept()
        with conn:
            conn.settimeout(1)
            log.write_text(f'client={addr}\n')
            while time.monotonic() < deadline and reports < 10:
                try:
                    header = conn.recv(3)
                except socket.timeout:
                    continue
                if not header:
                    break
                while len(header) < 3:
                    chunk = conn.recv(3 - len(header))
                    if not chunk:
                        raise EOFError('short frame header')
                    header += chunk
                frame_type = header[0]
                size = struct.unpack('!H', header[1:])[0]
                payload = b""
                while len(payload) < size:
                    chunk = conn.recv(size - len(payload))
                    if not chunk:
                        raise EOFError('short frame payload')
                    payload += chunk
                log.write_text(log.read_text() + f'type=0x{frame_type:02x} len={size} head={payload[:8].hex()}\n')
                if frame_type == 0x01:
                    reports += 1
                    assert size == 46, size
                    assert payload[0] == 0x45, payload.hex()
                    if not saw_report:
                        write_frame(conn, 0x81, bytes([0x01, 0x80, 1, 2, 3, 4]))
                        saw_report = True
            assert reports >= 10, reports
    result.write_text(f'ok reports={reports}\n')
    PY
    python3 "$workdir/raw-server.py" "$host_port" "$workdir/server-result" "$workdir/server.log" &
    server_pid=$!

    apk="$project_root/app/build/outputs/apk/debug/app-debug.apk"
    "$ANDROID_HOME/platform-tools/adb" -s "$adb_serial" install -r "$apk" >/dev/null
    "$ANDROID_HOME/platform-tools/adb" -s "$adb_serial" shell pm grant "$package_name" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
    "$ANDROID_HOME/platform-tools/adb" -s "$adb_serial" shell pm grant "$package_name" android.permission.BLUETOOTH_CONNECT >/dev/null 2>&1 || true
    "$ANDROID_HOME/platform-tools/adb" -s "$adb_serial" shell pm grant "$package_name" android.permission.BLUETOOTH_SCAN >/dev/null 2>&1 || true

    if [ "$iroh_mode" = 1 ]; then
      STEAMLESS_IROH_BIND_ADDR="0.0.0.0:$iroh_port" \
        STEAMLESS_IROH_EXTERNAL_ADDR="10.0.2.2:$iroh_port" \
        ${steamlessLinkIrohProxy}/bin/steamless-link-iroh-proxy "127.0.0.1:$host_port" >"$workdir/iroh-ticket" 2>"$workdir/iroh-proxy.log" &
      proxy_pid=$!
      for _ in $(seq 1 100); do [ -s "$workdir/iroh-ticket" ] && break; sleep 0.1; done
      ticket=$(head -n1 "$workdir/iroh-ticket")
      test -n "$ticket"
      mode=uhid-raw-iroh
      ticket_args=(--es xyz.reo101.steamlesslink.extra.IROH_TICKET "$ticket")
    else
      "$ANDROID_HOME/platform-tools/adb" -s "$adb_serial" reverse "tcp:$host_port" "tcp:$host_port" >/dev/null
      mode=uhid-raw
      ticket_args=()
    fi

    "$ANDROID_HOME/platform-tools/adb" -s "$adb_serial" shell am start \
      -n "$package_name/.MainActivity" \
      --ez xyz.reo101.steamlesslink.extra.AUTOSTART true \
      --es xyz.reo101.steamlesslink.extra.HOST 127.0.0.1 \
      --ei xyz.reo101.steamlesslink.extra.PORT "$host_port" \
      --es xyz.reo101.steamlesslink.extra.TRANSPORT fake \
      --es xyz.reo101.steamlesslink.extra.MODE "$mode" \
      "''${ticket_args[@]}" >/dev/null

    result_deadline=$((SECONDS + 60))
    while [ "$SECONDS" -lt "$result_deadline" ]; do
      if [ -e "$workdir/server-result" ]; then
        cat "$workdir/server-result"
        exit 0
      fi
      if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "error: fake raw server exited before success" >&2
        cat "$workdir/server.log" >&2 || true
        cat "$workdir/iroh-proxy.log" >&2 2>/dev/null || true
        "$ANDROID_HOME/platform-tools/adb" -s "$adb_serial" logcat -d -v time -s ControllerBridge FakeTritonTransport AndroidRuntime IrohRawUhid AndroidRuntime >&2 || true
        exit 1
      fi
      sleep 1
    done

    echo "error: timed out waiting for Android app raw reports" >&2
    cat "$workdir/server.log" >&2 || true
    cat "$workdir/iroh-proxy.log" >&2 2>/dev/null || true
    "$ANDROID_HOME/platform-tools/adb" -s "$adb_serial" logcat -d -v time -s ControllerBridge FakeTritonTransport IrohRawUhid AndroidRuntime >&2 || true
    exit 1
  '';
}
