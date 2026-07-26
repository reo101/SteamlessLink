{
  pkgs,
  lib,
  steamlessLinkHostModule,
  steamlessLinkHostPackage,
  steamlessLinkControllerModule,
  steamlessLinkControllerPackage,
}:
let
  testNetwork = {
    vlan = 1;
    prefixLength = 24;
    steam = {
      hostName = "steam";
      ipv4 = "192.168.1.1";
    };
    handheld = {
      hostName = "handheld";
      ipv4 = "192.168.1.2";
    };
  };

  uhidServer = {
    listenHost = "0.0.0.0";
    listenPort = 3244;
    logLevel = "debug";
  };

  # The fake controller on the handheld appears on the Bluetooth bus (0005);
  # the server-created virtual device on the steam node uses USB (0003).
  fakeController = {
    hidDeviceGlob = "/sys/bus/hid/devices/0005:28DE:1303.*";
    outputPath = "/tmp/fake-controller-output";
    setFeaturePath = "/tmp/fake-controller-set-feature";
    readyPath = "/tmp/fake-controller-ready";
    featureByte = "0x5a";
  };

  steamHidDeviceGlob = "/sys/bus/hid/devices/0003:28DE:1303.*/hidraw/hidraw*";

  handheldHidrawStat = pkgs.writeShellScript "handheld-hidraw-stat" ''
    dev=$(ls ${fakeController.hidDeviceGlob}/hidraw/ | head -n1)
    test -n "$dev"
    stat -c '%U %G %a' "/dev/$dev"
  '';

  fakeControllerDaemon = pkgs.writeTextFile {
    name = "steamless-fake-controller";
    executable = true;
    destination = "/bin/steamless-fake-controller";
    text = /* python */ ''
      #!${lib.getExe pkgs.python3}
      """Emulates a Triton BLE controller via /dev/uhid: emits numbered 0x45
      input reports, records output reports, and answers get/set report."""
      import os, pathlib, select, struct, time

      UHID_OUTPUT = 6
      UHID_GET_REPORT = 9
      UHID_GET_REPORT_REPLY = 10
      UHID_CREATE2 = 11
      UHID_INPUT2 = 12
      UHID_SET_REPORT = 13
      UHID_SET_REPORT_REPLY = 14
      UHID_START = 2
      UHID_STOP = 3
      DATA_MAX = 4096
      EVENT_SIZE = 4 + 128 + 64 + 64 + 2 + 2 + 4 + 4 + 4 + 4 + DATA_MAX

      OUTPUT_PATH = pathlib.Path('${fakeController.outputPath}')
      SET_FEATURE_PATH = pathlib.Path('${fakeController.setFeaturePath}')
      READY_PATH = pathlib.Path('${fakeController.readyPath}')
      FEATURE_BYTE = ${fakeController.featureByte}

      def vendor_report(report_id, main_item, count):
          return bytes([0x85, report_id, 0x09, 0x01, 0x15, 0x00, 0x26, 0xff, 0x00,
                        0x75, 0x08, 0x95, count, main_item, 0x02])

      rd = (bytes([0x06, 0x00, 0xff, 0x09, 0x01, 0xa1, 0x01])
            + vendor_report(0x45, 0x81, 45)    # input, 45 bytes
            + vendor_report(0x80, 0x91, 63)    # output
            + vendor_report(0x01, 0xb1, 63)    # feature
            + bytes([0xc0]))

      def write_event(fd, event):
          os.write(fd, event.ljust(EVENT_SIZE, b'\x00'))

      fd = os.open('/dev/uhid', os.O_RDWR)
      write_event(fd, struct.pack('<I', UHID_CREATE2) + struct.pack(
          '<128s64s64sHHIIII',
          b'Fake Triton', b'fake/input0', b'fake-triton',
          len(rd), 0x05, 0x28de, 0x1303, 0x0110, 0,
      ) + rd)
      READY_PATH.write_text('ready\n')

      input_report = bytes([0x45]) + bytes(range(1, 46))
      running = False
      next_input = time.monotonic()
      while True:
          ready, _, _ = select.select([fd], [], [], 0.004)
          if ready:
              event = os.read(fd, EVENT_SIZE)
              etype = struct.unpack_from('<I', event, 0)[0]
              payload = event[4:]
              if etype == UHID_START:
                  running = True
              elif etype == UHID_STOP:
                  running = False
              elif etype == UHID_OUTPUT:
                  size = struct.unpack_from('<H', payload, DATA_MAX)[0]
                  with OUTPUT_PATH.open('a') as f:
                      f.write(payload[:size].hex() + '\n')
              elif etype == UHID_GET_REPORT:
                  req_id, rnum, _rtype = struct.unpack_from('<IBB', payload, 0)
                  data = bytes([rnum]) + bytes([FEATURE_BYTE] * 15)
                  write_event(fd, struct.pack('<IIHH', UHID_GET_REPORT_REPLY,
                                              req_id, 0, len(data)) + data)
              elif etype == UHID_SET_REPORT:
                  req_id, _rnum, _rtype, size = struct.unpack_from('<IBBH', payload, 0)
                  SET_FEATURE_PATH.write_bytes(payload[8:8 + size])
                  write_event(fd, struct.pack('<IIH', UHID_SET_REPORT_REPLY, req_id, 0))
          if running and time.monotonic() >= next_input:
              try:
                  write_event(fd, struct.pack('<IH', UHID_INPUT2, len(input_report))
                              + input_report)
              except OSError:
                  pass
              next_input = time.monotonic() + 0.004
    '';
  };

  verifySteamSide = pkgs.writeTextFile {
    name = "verify-steamless-link-controller";
    executable = true;
    destination = "/bin/verify-steamless-link-controller";
    text = /* python */ ''
      #!${lib.getExe pkgs.python3}
      """Runs on the steam node against the server-created virtual controller:
      reads a forwarded 0x45 input report and round-trips output, GET_REPORT,
      and SET_REPORT traffic to the fake device."""
      import fcntl, glob, os, select, time

      FEATURE_BYTE = ${fakeController.featureByte}

      hidraw_sys = glob.glob('${steamHidDeviceGlob}')
      assert hidraw_sys, 'server-created hidraw node not found'
      dev = '/dev/' + os.path.basename(hidraw_sys[0])
      fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK)
      try:
          deadline = time.monotonic() + 10
          report = None
          while time.monotonic() < deadline:
              ready, _, _ = select.select([fd], [], [], 0.25)
              if ready:
                  report = os.read(fd, 64)
                  if report:
                      break
          assert report, 'timed out reading forwarded input report'
          assert report[0] == 0x45, report.hex()
          assert len(report) == 46, len(report)

          os.write(fd, bytes([0x80, 1, 2, 3, 4]))

          # HIDIOCGFEATURE(16) round trip through both machines.
          hidiocgfeature_16 = (3 << 30) | (16 << 16) | (0x48 << 8) | 0x07
          buf = bytearray(16)
          buf[0] = 0x01
          fcntl.ioctl(fd, hidiocgfeature_16, buf, True)
          assert buf[0] == 0x01, buf.hex()
          assert buf[1] == FEATURE_BYTE, buf.hex()

          hidiocsfeature_16 = (3 << 30) | (16 << 16) | (0x48 << 8) | 0x06
          set_buf = bytearray(16)
          set_buf[0] = 0x01
          set_buf[1] = 0xa5
          fcntl.ioctl(fd, hidiocsfeature_16, set_buf, True)
      finally:
          os.close(fd)
    '';
  };

  baseNode =
    host:
    { lib, ... }:
    {
      virtualisation.vlans = [ testNetwork.vlan ];
      networking.useDHCP = false;
      networking.hosts = {
        ${testNetwork.steam.ipv4} = [ testNetwork.steam.hostName ];
        ${testNetwork.handheld.ipv4} = [ testNetwork.handheld.hostName ];
      };
      networking.interfaces.eth1.ipv4.addresses = lib.mkOverride 0 [
        {
          address = host.ipv4;
          prefixLength = testNetwork.prefixLength;
        }
      ];
    };
in
{
  name = "steamless-link-controller";

  nodes = {
    steam =
      { ... }:
      {
        imports = [
          (baseNode testNetwork.steam)
          steamlessLinkHostModule
        ];

        users.groups.steam = { };
        users.users.steam = {
          isSystemUser = true;
          group = "steam";
          extraGroups = [ "input" ];
        };

        services.steamless-link-host = {
          enable = true;
          package = steamlessLinkHostPackage;
          listenHost = uhidServer.listenHost;
          listenPort = uhidServer.listenPort;
          logLevel = uhidServer.logLevel;
          openFirewall = true;
        };
      };

    handheld =
      { ... }:
      {
        imports = [
          (baseNode testNetwork.handheld)
          steamlessLinkControllerModule
        ];

        boot.kernelModules = [ "uhid" ];

        services.steamless-link-controller = {
          enable = true;
          package = steamlessLinkControllerPackage;
          host = testNetwork.steam.hostName;
          port = uhidServer.listenPort;
          reconnectMs = 50;
          logLevel = "debug";
        };

        systemd.services.fake-controller = {
          description = "Fake Triton BLE controller backed by /dev/uhid";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-modules-load.service" ];
          serviceConfig = {
            ExecStart = lib.getExe' fakeControllerDaemon "steamless-fake-controller";
            Restart = "on-failure";
          };
        };
      };
  };

  testScript = /* python */ ''
    start_all()

    steam.wait_for_unit("steamless-link-host.service")
    steam.wait_until_succeeds("journalctl -u steamless-link-host --no-pager | grep -q 'listening on ${uhidServer.listenHost}:${toString uhidServer.listenPort}'")

    handheld.wait_for_unit("multi-user.target")
    handheld.wait_for_unit("fake-controller.service")
    handheld.wait_until_succeeds("test -e ${fakeController.readyPath}")
    handheld.wait_until_succeeds("ls -d ${fakeController.hidDeviceGlob}")

    handheld.wait_for_unit("steamless-link-controller-capture.service")
    handheld.wait_for_unit("steamless-link-controller.service")

    # Diagnostics: show flag state and how udev evaluated the hidraw node.
    print(handheld.succeed(
        "ls -l /dev/hidraw*; "
        "test -e /run/steamless-link-controller/capture && echo FLAG-PRESENT || echo FLAG-MISSING; "
        "dev=$(ls ${fakeController.hidDeviceGlob}/hidraw/ | head -n1); "
        "udevadm test --action=add /sys/class/hidraw/$dev 2>&1 | grep -Ei 'steamless|GROUP|MODE|uaccess' || true"
    ))

    # While capture is active, the hidraw node belongs to the daemon's group
    # and is unreadable for ordinary (Steam-running) users.
    handheld.wait_until_succeeds("${handheldHidrawStat} | grep -q '^root steamless-link-input 660$'")

    # The bridge should produce a virtual controller on the steam node.
    steam.wait_until_succeeds("ls ${steamHidDeviceGlob} >/dev/null")
    steam.wait_until_succeeds("journalctl -u steamless-link-host --no-pager | grep -q 'input reports='")
    steam.succeed("${lib.getExe' verifySteamSide "verify-steamless-link-controller"}")

    # Output and feature-set reports written on the steam node must reach the
    # fake device.
    handheld.wait_until_succeeds("grep -q '8001020304' ${fakeController.outputPath}")
    handheld.wait_until_succeeds("test \"$(od -An -tx1 -N2 ${fakeController.setFeaturePath} | tr -d '[:space:]')\" = 01a5")

    # Dynamic handoff: stopping capture returns the controller to local
    # consumers (default root-only perms here; uaccess in real setups) and
    # tears down the remote virtual controller.
    handheld.succeed("systemctl stop steamless-link-controller-capture.service")
    handheld.wait_until_succeeds("${handheldHidrawStat} | grep -q '^root root 600$'")
    steam.wait_until_fails("ls ${steamHidDeviceGlob} >/dev/null")

    # Re-enabling capture steals it back and the bridge recovers on its own.
    handheld.succeed("systemctl start steamless-link-controller-capture.service")
    handheld.wait_until_succeeds("${handheldHidrawStat} | grep -q '^root steamless-link-input 660$'")
    steam.wait_until_succeeds("ls ${steamHidDeviceGlob} >/dev/null")
    steam.succeed("${lib.getExe' verifySteamSide "verify-steamless-link-controller"}")
  '';
}
