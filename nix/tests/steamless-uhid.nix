{
  steamlessUhidModule,
  steamlessUhidPackage,
}:
let
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
      { pkgs, ... }:
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

        environment.systemPackages = [ pkgs.python3 ];

        services.steamless-uhid = {
          enable = true;
          package = steamlessUhidPackage;
          listenHost = "0.0.0.0";
          logLevel = "debug";
          openFirewall = true;
        };
      };

    phone =
      { pkgs, ... }:
      {
        imports = [ (baseNode "192.168.1.2") ];
        environment.systemPackages = [ pkgs.python3 ];
      };
  };

  testScript = ''
    start_all()

    steam.wait_for_unit("multi-user.target")
    steam.wait_for_unit("steamless-uhid.service")
    steam.wait_until_succeeds("journalctl -u steamless-uhid --no-pager | grep -q 'listening on 0.0.0.0:3244'")

    phone.wait_for_unit("multi-user.target")
    phone.succeed(
        "cat > /tmp/steamless-phone-client.py <<'PY'\n"
        "import pathlib, socket, struct, time, traceback\n"
        "\n"
        "FRAME_INPUT = 0x01\n"
        "FRAME_GET_REPORT_REPLY = 0x02\n"
        "FRAME_SET_REPORT_REPLY = 0x03\n"
        "FRAME_OUTPUT = 0x81\n"
        "FRAME_GET_REPORT = 0x82\n"
        "FRAME_SET_REPORT = 0x83\n"
        "\n"
        "def send_frame(sock, frame_type, payload):\n"
        "    sock.sendall(bytes([frame_type]) + struct.pack('!H', len(payload)) + payload)\n"
        "\n"
        "def recv_exact(sock, size):\n"
        "    data = bytearray()\n"
        "    while len(data) < size:\n"
        "        chunk = sock.recv(size - len(data))\n"
        "        if not chunk:\n"
        "            raise EOFError('socket closed')\n"
        "        data.extend(chunk)\n"
        "    return bytes(data)\n"
        "\n"
        "def recv_frame(sock):\n"
        "    header = recv_exact(sock, 3)\n"
        "    size = struct.unpack('!H', header[1:3])[0]\n"
        "    return header[0], recv_exact(sock, size)\n"
        "\n"
        "def main():\n"
        "    payload = bytes([0x45]) + bytes(range(1, 46))\n"
        "    pathlib.Path('/tmp/client-ready').write_text('ready\\n')\n"
        "    with socket.create_connection(('steam', 3244), timeout=10) as sock:\n"
        "        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)\n"
        "        sock.settimeout(0.005)\n"
        "        next_send = time.monotonic()\n"
        "        sent = 0\n"
        "        deadline = time.monotonic() + 12\n"
        "        saw_output = False\n"
        "        while time.monotonic() < deadline:\n"
        "            if sent >= 500 and saw_output:\n"
        "                break\n"
        "            now = time.monotonic()\n"
        "            while sent < 500 and now >= next_send:\n"
        "                send_frame(sock, FRAME_INPUT, payload)\n"
        "                sent += 1\n"
        "                next_send += 0.004\n"
        "            try:\n"
        "                frame_type, frame_payload = recv_frame(sock)\n"
        "            except socket.timeout:\n"
        "                continue\n"
        "            if frame_type == FRAME_OUTPUT:\n"
        "                pathlib.Path('/tmp/output-frame').write_text(frame_payload.hex() + '\\n')\n"
        "                saw_output = True\n"
        "                continue\n"
        "            if frame_type == FRAME_GET_REPORT and len(frame_payload) >= 6:\n"
        "                request_id = frame_payload[:4]\n"
        "                report_number = frame_payload[4]\n"
        "                send_frame(sock, FRAME_GET_REPORT_REPLY, request_id + struct.pack('<H', 0) + bytes([report_number]) + bytes(15))\n"
        "            elif frame_type == FRAME_SET_REPORT and len(frame_payload) >= 6:\n"
        "                send_frame(sock, FRAME_SET_REPORT_REPLY, frame_payload[:4] + struct.pack('<H', 0))\n"
        "        if sent < 500:\n"
        "            raise RuntimeError(f'sent only {sent} input reports')\n"
        "        if not saw_output:\n"
        "            raise RuntimeError('timed out waiting for UHID output frame')\n"
        "    pathlib.Path('/tmp/client-done').write_text('ok\\n')\n"
        "\n"
        "try:\n"
        "    main()\n"
        "except Exception as exc:\n"
        "    pathlib.Path('/tmp/client-failed').write_text(str(exc) + '\\n')\n"
        "    traceback.print_exc()\n"
        "    raise\n"
        "PY\n"
        "python3 /tmp/steamless-phone-client.py > /tmp/phone-client.log 2>&1 &\n"
    )
    phone.wait_until_succeeds("test -e /tmp/client-ready")

    steam.wait_until_succeeds("ls /sys/bus/hid/devices/0003:28DE:1303.*/hidraw/hidraw* >/dev/null")
    steam.succeed(
        "python3 - <<'PY'\n"
        "import glob, os, pathlib, select, time\n"
        "hidraw_sys = glob.glob('/sys/bus/hid/devices/0003:28DE:1303.*/hidraw/hidraw*')\n"
        "assert hidraw_sys, 'Steam Controller hidraw node not found'\n"
        "hidraw_name = os.path.basename(hidraw_sys[0])\n"
        "hid_device = pathlib.Path('/sys/class/hidraw') / hidraw_name / 'device'\n"
        "uevent = (hid_device / 'uevent').read_text()\n"
        "assert 'HID_ID=0003:000028DE:00001303' in uevent, uevent\n"
        "report_descriptor = (hid_device / 'report_descriptor').read_bytes()\n"
        "assert len(report_descriptor) == 278, len(report_descriptor)\n"
        "dev = '/dev/' + hidraw_name\n"
        "fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK)\n"
        "try:\n"
        "    deadline = time.monotonic() + 5\n"
        "    report = None\n"
        "    while time.monotonic() < deadline:\n"
        "        ready, _, _ = select.select([fd], [], [], 0.25)\n"
        "        if ready:\n"
        "            report = os.read(fd, 64)\n"
        "            if report:\n"
        "                break\n"
        "    assert report is not None, 'timed out reading hidraw input report'\n"
        "    assert report[0] == 0x45, report.hex()\n"
        "    assert len(report) == 46, len(report)\n"
        "    os.write(fd, bytes([0x80, 1, 2, 3, 4]))\n"
        "finally:\n"
        "    os.close(fd)\n"
        "PY\n"
    )

    phone.wait_until_succeeds("test -e /tmp/client-done -o -e /tmp/client-failed")
    phone.succeed("test -e /tmp/client-done")
    phone.succeed("grep -q '8001020304' /tmp/output-frame")
    steam.wait_until_succeeds("journalctl -u steamless-uhid --no-pager | grep -q 'input reports='")
    steam.succeed("journalctl -u steamless-uhid --no-pager | grep -q 'UHID output'")
  '';
}
