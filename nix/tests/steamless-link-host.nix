{
  pkgs,
  lib,
  steamlessLinkHostModule,
  steamlessLinkHostPackage,
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

  irohProxy = {
    bindAddr = "${testNetwork.steam.ipv4}:34244";
    externalAddr = "${testNetwork.steam.ipv4}:34244";
    stateDirectory = "/var/lib/steamless-link-iroh-proxy";
  };

  steamController = rec {
    name = "Steam Controller";
    hidBusHex = "0003";
    valveVendorHex = "28DE";
    tritonBleProductHex = "1303";
    hidDeviceGlob = "/sys/bus/hid/devices/${hidBusHex}:${valveVendorHex}:${tritonBleProductHex}.*/hidraw/hidraw*";
    hidIdUevent = "HID_ID=${hidBusHex}:0000${valveVendorHex}:0000${tritonBleProductHex}";
    reportDescriptorLength = 293;
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
      FRAME_GET_IROH_TICKET = 0x05
      FRAME_OUTPUT = 0x81
      FRAME_GET_REPORT = 0x82
      FRAME_SET_REPORT = 0x83
      FRAME_IROH_TICKET = 0x85

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
          with socket.create_connection((STEAM_HOST, STEAM_PORT), timeout=10) as sock:
              send_frame(sock, FRAME_GET_IROH_TICKET, b"")
              frame_type, ticket = recv_frame(sock)
              if frame_type != FRAME_IROH_TICKET or not ticket.startswith(b'endpoint'):
                  raise RuntimeError('invalid Iroh ticket response')
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

  genericGamepad = {
    name = "SteamlessLink Generic Gamepad";
    hidDeviceGlob = "/sys/bus/hid/devices/0003:0000:0000.*/hidraw/hidraw*";
    inputEventGlob = "/sys/bus/hid/devices/0003:0000:0000.*/input/input*/event*";
    inputReport = "01410c0100ff123411ee";
    reportDescriptorHex = "05010905a101850105091901290f150025017501950f810275019501810305010939150025073500463b0165147504950181427504950181036500150026ff00750895060930093109330934093209358102c0";
  };

  steamlessGenericPhoneClient = pkgs.writeTextFile {
    name = "steamless-generic-phone-client";
    executable = true;
    destination = "/bin/steamless-generic-phone-client";
    text = /* python */ ''
      #!${lib.getExe pkgs.python3}
      import pathlib, socket, struct, time, traceback

      STEAM_HOST = '${testNetwork.steam.hostName}'
      STEAM_PORT = ${toString uhidServer.listenPort}
      READY_PATH = pathlib.Path('/tmp/generic-client-ready')
      DONE_PATH = pathlib.Path('/tmp/generic-client-done')
      FAILED_PATH = pathlib.Path('/tmp/generic-client-failed')
      FRAME_INPUT = 0x01
      FRAME_DEVICE_INFO = 0x04
      REPORT_DESCRIPTOR = bytes.fromhex('${genericGamepad.reportDescriptorHex}')
      NAME = b'${genericGamepad.name}'
      ACTIVE_REPORT = bytes.fromhex('${genericGamepad.inputReport}')
      NEUTRAL_REPORT = bytes([0x01, 0x00, 0x00, 0x08, 0x80, 0x80, 0x80, 0x80, 0x00, 0x00])

      def send_frame(sock, frame_type, payload):
          sock.sendall(bytes([frame_type]) + struct.pack('!H', len(payload)) + payload)

      def main():
          device_info = (
              struct.pack('<IHHH', 0x0003, 0x0000, 0x0000, len(REPORT_DESCRIPTOR))
              + REPORT_DESCRIPTOR
              + bytes([len(NAME)])
              + NAME
          )
          with socket.create_connection((STEAM_HOST, STEAM_PORT), timeout=10) as sock:
              sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
              send_frame(sock, FRAME_DEVICE_INFO, device_info)
              READY_PATH.write_text('ready\n')
              for index in range(1000):
                  send_frame(sock, FRAME_INPUT, ACTIVE_REPORT if index % 2 else NEUTRAL_REPORT)
                  time.sleep(0.004)
          DONE_PATH.write_text('ok\n')

      try:
          main()
      except Exception as exc:
          FAILED_PATH.write_text(str(exc) + '\n')
          traceback.print_exc()
          raise
    '';
  };

  verifyGenericGamepad = pkgs.writeTextFile {
    name = "verify-steamless-generic-gamepad";
    executable = true;
    destination = "/bin/verify-steamless-generic-gamepad";
    text = /* python */ ''
      #!${lib.getExe pkgs.python3}
      import glob, os, pathlib, select, struct, time

      HID_DEVICE_GLOB = '${genericGamepad.hidDeviceGlob}'
      INPUT_EVENT_GLOB = '${genericGamepad.inputEventGlob}'
      NAME = '${genericGamepad.name}'
      ACTIVE_REPORT = bytes.fromhex('${genericGamepad.inputReport}')
      REPORT_DESCRIPTOR = bytes.fromhex('${genericGamepad.reportDescriptorHex}')
      EV_KEY = 0x01
      EV_ABS = 0x03
      BTN_SOUTH = 0x130
      BTN_TL = 0x136
      BTN_SELECT = 0x13a
      BTN_START = 0x13b
      ABS_X = 0x00
      ABS_Y = 0x01
      ABS_Z = 0x02
      ABS_RX = 0x03
      ABS_RY = 0x04
      ABS_RZ = 0x05
      ABS_HAT0X = 0x10
      ABS_HAT0Y = 0x11
      EVENT = struct.Struct('llHHi')

      hidraw_sys = glob.glob(HID_DEVICE_GLOB)
      assert hidraw_sys, 'generic gamepad hidraw node not found'
      hidraw_name = os.path.basename(hidraw_sys[0])
      hid_device = pathlib.Path('/sys/class/hidraw') / hidraw_name / 'device'
      uevent = (hid_device / 'uevent').read_text()
      assert 'HID_ID=0003:00000000:00000000' in uevent, uevent
      assert (hid_device / 'report_descriptor').read_bytes() == REPORT_DESCRIPTOR

      event_sys = glob.glob(INPUT_EVENT_GLOB)
      assert event_sys, 'generic gamepad event node not found'
      event_name = os.path.basename(event_sys[0])
      event_root = pathlib.Path('/sys/class/input') / event_name
      assert (event_root / 'device/name').read_text().strip() == NAME

      expected_events = {
          (EV_KEY, BTN_SOUTH, 1),
          (EV_KEY, BTN_TL, 1),
          (EV_KEY, BTN_SELECT, 1),
          (EV_KEY, BTN_START, 1),
          (EV_ABS, ABS_X, 0),
          (EV_ABS, ABS_Y, 255),
          (EV_ABS, ABS_Z, 17),
          (EV_ABS, ABS_RX, 18),
          (EV_ABS, ABS_RY, 52),
          (EV_ABS, ABS_RZ, 238),
          (EV_ABS, ABS_HAT0X, 1),
          (EV_ABS, ABS_HAT0Y, -1),
      }
      seen_events = set()
      saw_hidraw_report = False
      hidraw_fd = os.open('/dev/' + hidraw_name, os.O_RDONLY | os.O_NONBLOCK)
      event_fd = os.open('/dev/input/' + event_name, os.O_RDONLY | os.O_NONBLOCK)
      try:
          deadline = time.monotonic() + 5
          while time.monotonic() < deadline:
              ready, _, _ = select.select([hidraw_fd, event_fd], [], [], 0.25)
              if hidraw_fd in ready:
                  if os.read(hidraw_fd, 64) == ACTIVE_REPORT:
                      saw_hidraw_report = True
              if event_fd in ready:
                  try:
                      data = os.read(event_fd, EVENT.size * 64)
                  except OSError as error:
                      raise AssertionError((error, expected_events - seen_events, seen_events)) from error
                  for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                      _, _, event_type, code, value = EVENT.unpack_from(data, offset)
                      seen_events.add((event_type, code, value))
              if saw_hidraw_report and expected_events.issubset(seen_events):
                  break
      finally:
          os.close(hidraw_fd)
          os.close(event_fd)
      assert saw_hidraw_report, 'did not receive the generic HID report'
      assert expected_events.issubset(seen_events), (expected_events - seen_events, seen_events)
    '';
  };

  verifySteamlessHidraw = pkgs.writeTextFile {
    name = "verify-steamless-link-host";
    executable = true;
    destination = "/bin/verify-steamless-link-host";
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
  name = "steamless-link-host";

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
          iroh = {
            enable = true;
            inherit (irohProxy) bindAddr externalAddr;
          };
        };
      };

    phone = { ... }: {
      imports = [ (baseNode testNetwork.phone) ];
    };
  };

  testScript = /* python */ ''
    start_all()

    steam.wait_for_unit("multi-user.target")
    steam.wait_for_unit("steamless-link-host.service")
    steam.wait_until_succeeds("journalctl -u steamless-link-host --no-pager | grep -q 'listening on ${uhidServer.listenHost}:${toString uhidServer.listenPort}'")
    steam.wait_for_unit("steamless-link-iroh-proxy.service")
    steam.wait_until_succeeds("test -f ${irohProxy.stateDirectory}/identity.key")
    steam.succeed("test \"$(stat -c %U ${irohProxy.stateDirectory})\" = steam")
    steam.succeed("test \"$(stat -c %a ${irohProxy.stateDirectory})\" = 700")
    steam.succeed("test \"$(stat -c %a ${irohProxy.stateDirectory}/identity.key)\" = 600")
    steam.succeed("test \"$(stat -c %s ${irohProxy.stateDirectory}/identity.key)\" = 32")
    steam.wait_until_succeeds("test -s ${irohProxy.stateDirectory}/ticket")
    steam.succeed("test \"$(stat -c %a ${irohProxy.stateDirectory}/ticket)\" = 600")

    phone.wait_for_unit("multi-user.target")
    phone.succeed("${lib.getExe steamlessPhoneClient} > ${phoneClientConfig.logPath} 2>&1 &")
    phone.wait_until_succeeds("test -e ${phoneClientConfig.readyPath}")

    steam.wait_until_succeeds("ls ${steamController.hidDeviceGlob} >/dev/null")
    steam.succeed("${lib.getExe verifySteamlessHidraw}")

    phone.wait_until_succeeds("test -e ${phoneClientConfig.donePath} -o -e ${phoneClientConfig.failedPath}")
    phone.succeed("test -e ${phoneClientConfig.donePath}")
    phone.succeed("grep -q '${steamController.outputReportHex}' ${phoneClientConfig.outputFramePath}")
    steam.wait_until_succeeds("journalctl -u steamless-link-host --no-pager | grep -q 'input reports='")
    steam.succeed("journalctl -u steamless-link-host --no-pager | grep -q 'UHID output'")

    phone.succeed("${lib.getExe steamlessGenericPhoneClient} > /tmp/generic-client.log 2>&1 &")
    phone.wait_until_succeeds("test -e /tmp/generic-client-ready")
    steam.wait_until_succeeds("ls ${genericGamepad.hidDeviceGlob} >/dev/null")
    steam.succeed("${lib.getExe verifyGenericGamepad}")
    phone.wait_until_succeeds("test -e /tmp/generic-client-done -o -e /tmp/generic-client-failed")
    phone.succeed("test -e /tmp/generic-client-done")
  '';
}
