{
  pkgs,
  lib,
  steamlessUhidModule,
  steamlessUhidPackage,
  androidEmulatorClient,
  androidSdk,
}:
let
  hostForwardPort = 33244;
  guestUhidPort = 3244;

  steamController = rec {
    hidBusHex = "0003";
    valveVendorHex = "28DE";
    tritonBleProductHex = "1303";
    hidDeviceGlob = "/sys/bus/hid/devices/${hidBusHex}:${valveVendorHex}:${tritonBleProductHex}.*/hidraw/hidraw*";
    hidIdUevent = "HID_ID=${hidBusHex}:0000${valveVendorHex}:0000${tritonBleProductHex}";
    reportDescriptorLength = 278;
    inputReportId = 69;
    inputReportSize = 46;
  };

  verifySteamlessHidraw = pkgs.writeTextFile {
    name = "verify-steamless-emulator-hidraw";
    executable = true;
    destination = "/bin/verify-steamless-emulator-hidraw";
    text = /* python */ ''
      #!${lib.getExe pkgs.python3}
      import glob, os, pathlib, select, time

      HID_DEVICE_GLOB = '${steamController.hidDeviceGlob}'
      EXPECTED_HID_ID_UEVENT = '${steamController.hidIdUevent}'
      EXPECTED_REPORT_DESCRIPTOR_LENGTH = ${toString steamController.reportDescriptorLength}
      EXPECTED_INPUT_REPORT_ID = ${toString steamController.inputReportId}
      EXPECTED_INPUT_REPORT_SIZE = ${toString steamController.inputReportSize}

      hidraw_sys = glob.glob(HID_DEVICE_GLOB)
      assert hidraw_sys, 'Steam Controller hidraw node not found'
      hidraw_name = os.path.basename(hidraw_sys[0])
      hid_device = pathlib.Path('/sys/class/hidraw') / hidraw_name / 'device'
      uevent = (hid_device / 'uevent').read_text()
      assert EXPECTED_HID_ID_UEVENT in uevent, uevent
      report_descriptor = (hid_device / 'report_descriptor').read_bytes()
      assert len(report_descriptor) == EXPECTED_REPORT_DESCRIPTOR_LENGTH, len(report_descriptor)
      fd = os.open('/dev/' + hidraw_name, os.O_RDWR | os.O_NONBLOCK)
      try:
          deadline = time.monotonic() + 5
          report = None
          while time.monotonic() < deadline:
              ready, _, _ = select.select([fd], [], [], 0.25)
              if ready:
                  report = os.read(fd, 64)
                  if report:
                      break
          assert report is not None, 'timed out reading hidraw input report'
          assert report[0] == EXPECTED_INPUT_REPORT_ID, report.hex()
          assert len(report) == EXPECTED_INPUT_REPORT_SIZE, len(report)
          os.write(fd, bytes([0x80, 1, 2, 3, 4]))
      finally:
          os.close(fd)
    '';
  };
in
{
  name = "steamless-android-emulator-uhid";
  globalTimeout = 10 * 60;

  nodes.steam =
    { ... }:
    {
      imports = [ steamlessUhidModule ];

      users.groups.steam = { };
      users.users.steam = {
        isSystemUser = true;
        group = "steam";
        extraGroups = [ "input" ];
      };

      virtualisation.forwardPorts = [
        {
          from = "host";
          proto = "tcp";
          host.address = "127.0.0.1";
          host.port = hostForwardPort;
          guest.port = guestUhidPort;
        }
      ];

      services.steamless-uhid = {
        enable = true;
        package = steamlessUhidPackage;
        listenHost = "0.0.0.0";
        listenPort = guestUhidPort;
        logLevel = "debug";
        openFirewall = true;
      };
    };

  testScript = ''
    import os
    import pathlib
    import subprocess
    import time

    apk = os.environ.get("STEAMLESSLINK_APK")
    if not apk:
        raise RuntimeError("STEAMLESSLINK_APK must point to app-debug.apk")

    workdir = pathlib.Path(os.environ.get("STEAMLESS_ANDROID_TEST_TMPDIR", ".tmp/android-emulator-vm"))
    workdir.mkdir(parents=True, exist_ok=True)
    ready_file = workdir / "client-ready"
    stop_file = workdir / "client-stop"
    client_log = workdir / "client.log"
    ready_file.unlink(missing_ok=True)
    stop_file.unlink(missing_ok=True)

    start_all()
    steam.wait_for_unit("multi-user.target")
    steam.wait_for_unit("steamless-uhid.service")
    steam.wait_until_succeeds("journalctl -u steamless-uhid --no-pager | grep -q 'listening on 0.0.0.0:${toString guestUhidPort}'")

    env = os.environ.copy()
    env.update({
        "STEAMLESSLINK_APK": apk,
        "STEAMLESS_ANDROID_TEST_PORT": "${toString hostForwardPort}",
        "STEAMLESS_ANDROID_BRIDGE_HOST": "127.0.0.1",
        "STEAMLESS_ANDROID_READY_FILE": str(ready_file),
        "STEAMLESS_ANDROID_STOP_FILE": str(stop_file),
        "STEAMLESS_ANDROID_HOLD": "1",
        "STEAMLESS_ANDROID_TEST_TMPDIR": str(workdir / "emulator"),
    })

    client_log_file = client_log.open("wb")
    client = subprocess.Popen(["${lib.getExe androidEmulatorClient}"], env=env, stdout=client_log_file, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline:
            if ready_file.exists():
                break
            if client.poll() is not None:
                raise RuntimeError("Android emulator client exited early; see " + str(client_log))
            time.sleep(1)
        else:
            raise RuntimeError("timed out waiting for Android emulator client; see " + str(client_log))

        steam.wait_until_succeeds("ls ${steamController.hidDeviceGlob} >/dev/null", timeout=90)
        steam.succeed("${lib.getExe verifySteamlessHidraw}")
        steam.wait_until_succeeds("journalctl -u steamless-uhid --no-pager | grep -q 'input reports='")
        steam.succeed("journalctl -u steamless-uhid --no-pager | grep -q 'UHID output'")

        adb = "${androidSdk}/libexec/android-sdk/platform-tools/adb"
        output_deadline = time.monotonic() + 20
        while time.monotonic() < output_deadline:
            logs = subprocess.run(
                [adb, "-s", "emulator-5554", "logcat", "-d", "-v", "time", "-s", "ControllerBridge", "FakeTritonTransport", "AndroidRuntime"],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            ).stdout
            if "Fake output report" in logs or "UHID output report" in logs:
                break
            time.sleep(1)
        else:
            raise RuntimeError("Android app did not log UHID output handling")
    finally:
        stop_file.write_text("stop\n")
        try:
            client.wait(timeout=20)
        except subprocess.TimeoutExpired:
            client.terminate()
            client.wait(timeout=20)
        client_log_file.close()
  '';
}
