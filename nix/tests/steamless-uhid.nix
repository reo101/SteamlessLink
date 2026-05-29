{
  pkgs,
  lib,
  steamlessUhidModule,
  steamlessUhidPackage,
}:
let
  testNetwork = {
    vlan = 1;
    prefixLength = 24;
    steam = {
      hostName = "steam";
      ipv4 = "192.168.1.1";
    };
    phone = {
      hostName = "phone";
      ipv4 = "192.168.1.2";
    };
  };

  uhidServer = {
    listenHost = "0.0.0.0";
    listenPort = 3244;
    logLevel = "debug";
  };

  steamController = rec {
    name = "Steam Controller";
    hidBusHex = "0003";
    valveVendorHex = "28DE";
    tritonBleProductHex = "1303";
    hidDeviceGlob = "/sys/bus/hid/devices/${hidBusHex}:${valveVendorHex}:${tritonBleProductHex}.*/hidraw/hidraw*";
    hidIdUevent = "HID_ID=${hidBusHex}:0000${valveVendorHex}:0000${tritonBleProductHex}";
    reportDescriptorLength = 278;
    inputReportId = 69; # 0x45, the numbered Triton BLE input report
    inputReportSize = 46;
    outputReportHex = "8001020304";
  };

  phoneClientConfig = {
    readyPath = "/tmp/client-ready";
    donePath = "/tmp/client-done";
    failedPath = "/tmp/client-failed";
    outputFramePath = "/tmp/output-frame";
    logPath = "/tmp/phone-client.log";
    inputReportCount = 500;
    inputIntervalSeconds = "0.004"; # 250 Hz
    socketTimeoutSeconds = "0.005";
    totalTimeoutSeconds = 12;
  };

  steamlessPhoneClient = pkgs.writeTextFile {
    name = "steamless-phone-client";
    executable = true;
    destination = "/bin/steamless-phone-client";
    text = /* python */ ''
      #!${lib.getExe pkgs.python3}
      import pathlib, socket, struct, time, traceback

      STEAM_HOST = '${testNetwork.steam.hostName}'
      STEAM_PORT = ${toString uhidServer.listenPort}
      READY_PATH = pathlib.Path('${phoneClientConfig.readyPath}')
      DONE_PATH = pathlib.Path('${phoneClientConfig.donePath}')
      FAILED_PATH = pathlib.Path('${phoneClientConfig.failedPath}')
      OUTPUT_FRAME_PATH = pathlib.Path('${phoneClientConfig.outputFramePath}')
      INPUT_REPORT_ID = ${toString steamController.inputReportId}
      INPUT_REPORT_SIZE = ${toString steamController.inputReportSize}
      INPUT_REPORT_COUNT = ${toString phoneClientConfig.inputReportCount}
      INPUT_INTERVAL_SECONDS = ${phoneClientConfig.inputIntervalSeconds}
      SOCKET_TIMEOUT_SECONDS = ${phoneClientConfig.socketTimeoutSeconds}
      TOTAL_TIMEOUT_SECONDS = ${toString phoneClientConfig.totalTimeoutSeconds}

      FRAME_INPUT = 0x01
      FRAME_GET_REPORT_REPLY = 0x02
      FRAME_SET_REPORT_REPLY = 0x03
      FRAME_OUTPUT = 0x81
      FRAME_GET_REPORT = 0x82
      FRAME_SET_REPORT = 0x83

      def send_frame(sock, frame_type, payload):
          sock.sendall(bytes([frame_type]) + struct.pack('!H', len(payload)) + payload)

      def recv_exact(sock, size):
          data = bytearray()
          while len(data) < size:
              chunk = sock.recv(size - len(data))
              if not chunk:
                  raise EOFError('socket closed')
              data.extend(chunk)
          return bytes(data)

      def recv_frame(sock):
          header = recv_exact(sock, 3)
          size = struct.unpack('!H', header[1:3])[0]
          return header[0], recv_exact(sock, size)

      def main():
          payload = bytes([INPUT_REPORT_ID]) + bytes(range(1, INPUT_REPORT_SIZE))
          READY_PATH.write_text('ready\n')
          with socket.create_connection((STEAM_HOST, STEAM_PORT), timeout=10) as sock:
              sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
              sock.settimeout(SOCKET_TIMEOUT_SECONDS)
              next_send = time.monotonic()
              sent = 0
              deadline = time.monotonic() + TOTAL_TIMEOUT_SECONDS
              saw_output = False
              while time.monotonic() < deadline:
                  if sent >= INPUT_REPORT_COUNT and saw_output:
                      break
                  now = time.monotonic()
                  while sent < INPUT_REPORT_COUNT and now >= next_send:
                      send_frame(sock, FRAME_INPUT, payload)
                      sent += 1
                      next_send += INPUT_INTERVAL_SECONDS
                  try:
                      frame_type, frame_payload = recv_frame(sock)
                  except socket.timeout:
                      continue
                  if frame_type == FRAME_OUTPUT:
                      OUTPUT_FRAME_PATH.write_text(frame_payload.hex() + '\n')
                      saw_output = True
                      continue
                  if frame_type == FRAME_GET_REPORT and len(frame_payload) >= 6:
                      request_id = frame_payload[:4]
                      report_number = frame_payload[4]
                      send_frame(sock, FRAME_GET_REPORT_REPLY, request_id + struct.pack('<H', 0) + bytes([report_number]) + bytes(15))
                  elif frame_type == FRAME_SET_REPORT and len(frame_payload) >= 6:
                      send_frame(sock, FRAME_SET_REPORT_REPLY, frame_payload[:4] + struct.pack('<H', 0))
              if sent < INPUT_REPORT_COUNT:
                  raise RuntimeError(f'sent only {sent} input reports')
              if not saw_output:
                  raise RuntimeError('timed out waiting for UHID output frame')
          DONE_PATH.write_text('ok\n')

      try:
          main()
      except Exception as exc:
          FAILED_PATH.write_text(str(exc) + '\n')
          traceback.print_exc()
          raise
    '';
  };

  verifySteamlessHidraw = pkgs.writeTextFile {
    name = "verify-steamless-hidraw";
    executable = true;
    destination = "/bin/verify-steamless-hidraw";
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
      dev = '/dev/' + hidraw_name
      fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK)
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

  baseNode =
    host:
    { lib, ... }:
    {
      virtualisation.vlans = [ testNetwork.vlan ];
      networking.useDHCP = false;
      networking.hosts = {
        ${testNetwork.steam.ipv4} = [ testNetwork.steam.hostName ];
        ${testNetwork.phone.ipv4} = [ testNetwork.phone.hostName ];
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
  name = "steamless-uhid";

  nodes = {
    steam =
      { ... }:
      {
        imports = [
          (baseNode testNetwork.steam)
          steamlessUhidModule
        ];

        users.groups.steam = { };
        users.users.steam = {
          isSystemUser = true;
          group = "steam";
          extraGroups = [ "input" ];
        };

        services.steamless-uhid = {
          enable = true;
          package = steamlessUhidPackage;
          listenHost = uhidServer.listenHost;
          listenPort = uhidServer.listenPort;
          logLevel = uhidServer.logLevel;
          openFirewall = true;
        };
      };

    phone = { ... }: {
      imports = [ (baseNode testNetwork.phone) ];
    };
  };

  testScript = /* python */ ''
    start_all()

    steam.wait_for_unit("multi-user.target")
    steam.wait_for_unit("steamless-uhid.service")
    steam.wait_until_succeeds("journalctl -u steamless-uhid --no-pager | grep -q 'listening on ${uhidServer.listenHost}:${toString uhidServer.listenPort}'")

    phone.wait_for_unit("multi-user.target")
    phone.succeed("${lib.getExe steamlessPhoneClient} > ${phoneClientConfig.logPath} 2>&1 &")
    phone.wait_until_succeeds("test -e ${phoneClientConfig.readyPath}")

    steam.wait_until_succeeds("ls ${steamController.hidDeviceGlob} >/dev/null")
    steam.succeed("${lib.getExe verifySteamlessHidraw}")

    phone.wait_until_succeeds("test -e ${phoneClientConfig.donePath} -o -e ${phoneClientConfig.failedPath}")
    phone.succeed("test -e ${phoneClientConfig.donePath}")
    phone.succeed("grep -q '${steamController.outputReportHex}' ${phoneClientConfig.outputFramePath}")
    steam.wait_until_succeeds("journalctl -u steamless-uhid --no-pager | grep -q 'input reports='")
    steam.succeed("journalctl -u steamless-uhid --no-pager | grep -q 'UHID output'")
  '';
}
