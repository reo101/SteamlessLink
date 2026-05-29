{
  pkgs,
  lib,
  steamlessUhidModule,
  steamlessUhidPackage,
}:
let
  steamlessPhoneClient = pkgs.writeTextFile {
    name = "steamless-phone-client";
    executable = true;
    destination = "/bin/steamless-phone-client";
    text = /* python */ ''
      #!${lib.getExe pkgs.python3}
      import pathlib, socket, struct, time, traceback

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
          payload = bytes([0x45]) + bytes(range(1, 46))
          pathlib.Path('/tmp/client-ready').write_text('ready\n')
          with socket.create_connection(('steam', 3244), timeout=10) as sock:
              sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
              sock.settimeout(0.005)
              next_send = time.monotonic()
              sent = 0
              deadline = time.monotonic() + 12
              saw_output = False
              while time.monotonic() < deadline:
                  if sent >= 500 and saw_output:
                      break
                  now = time.monotonic()
                  while sent < 500 and now >= next_send:
                      send_frame(sock, FRAME_INPUT, payload)
                      sent += 1
                      next_send += 0.004
                  try:
                      frame_type, frame_payload = recv_frame(sock)
                  except socket.timeout:
                      continue
                  if frame_type == FRAME_OUTPUT:
                      pathlib.Path('/tmp/output-frame').write_text(frame_payload.hex() + '\n')
                      saw_output = True
                      continue
                  if frame_type == FRAME_GET_REPORT and len(frame_payload) >= 6:
                      request_id = frame_payload[:4]
                      report_number = frame_payload[4]
                      send_frame(sock, FRAME_GET_REPORT_REPLY, request_id + struct.pack('<H', 0) + bytes([report_number]) + bytes(15))
                  elif frame_type == FRAME_SET_REPORT and len(frame_payload) >= 6:
                      send_frame(sock, FRAME_SET_REPORT_REPLY, frame_payload[:4] + struct.pack('<H', 0))
              if sent < 500:
                  raise RuntimeError(f'sent only {sent} input reports')
              if not saw_output:
                  raise RuntimeError('timed out waiting for UHID output frame')
          pathlib.Path('/tmp/client-done').write_text('ok\n')

      try:
          main()
      except Exception as exc:
          pathlib.Path('/tmp/client-failed').write_text(str(exc) + '\n')
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

      hidraw_sys = glob.glob('/sys/bus/hid/devices/0003:28DE:1303.*/hidraw/hidraw*')
      assert hidraw_sys, 'Steam Controller hidraw node not found'
      hidraw_name = os.path.basename(hidraw_sys[0])
      hid_device = pathlib.Path('/sys/class/hidraw') / hidraw_name / 'device'
      uevent = (hid_device / 'uevent').read_text()
      assert 'HID_ID=0003:000028DE:00001303' in uevent, uevent
      report_descriptor = (hid_device / 'report_descriptor').read_bytes()
      assert len(report_descriptor) == 278, len(report_descriptor)
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
          assert report[0] == 0x45, report.hex()
          assert len(report) == 46, len(report)
          os.write(fd, bytes([0x80, 1, 2, 3, 4]))
      finally:
          os.close(fd)
    '';
  };

  baseNode =
    address:
    { lib, ... }:
    {
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.hosts = {
        "192.168.1.1" = [ "steam" ];
        "192.168.1.2" = [ "phone" ];
      };
      networking.interfaces.eth1.ipv4.addresses = lib.mkOverride 0 [
        {
          inherit address;
          prefixLength = 24;
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
          (baseNode "192.168.1.1")
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
          listenHost = "0.0.0.0";
          logLevel = "debug";
          openFirewall = true;
        };
      };

    phone = { ... }: {
      imports = [ (baseNode "192.168.1.2") ];
    };
  };

  testScript = ''
    start_all()

    steam.wait_for_unit("multi-user.target")
    steam.wait_for_unit("steamless-uhid.service")
    steam.wait_until_succeeds("journalctl -u steamless-uhid --no-pager | grep -q 'listening on 0.0.0.0:3244'")

    phone.wait_for_unit("multi-user.target")
    phone.succeed("${lib.getExe steamlessPhoneClient} > /tmp/phone-client.log 2>&1 &")
    phone.wait_until_succeeds("test -e /tmp/client-ready")

    steam.wait_until_succeeds("ls /sys/bus/hid/devices/0003:28DE:1303.*/hidraw/hidraw* >/dev/null")
    steam.succeed("${lib.getExe verifySteamlessHidraw}")

    phone.wait_until_succeeds("test -e /tmp/client-done -o -e /tmp/client-failed")
    phone.succeed("test -e /tmp/client-done")
    phone.succeed("grep -q '8001020304' /tmp/output-frame")
    steam.wait_until_succeeds("journalctl -u steamless-uhid --no-pager | grep -q 'input reports='")
    steam.succeed("journalctl -u steamless-uhid --no-pager | grep -q 'UHID output'")
  '';
}
