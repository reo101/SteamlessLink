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
    steam.wait_for_open_port(3244)

    phone.wait_for_unit("multi-user.target")
    phone.succeed(
        "python3 - <<'PY'\n"
        "import socket, struct, time\n"
        "payload = bytes([0x45]) + bytes(range(1, 46))\n"
        "packet = bytes([0x01]) + struct.pack('!H', len(payload)) + payload\n"
        "with socket.create_connection(('steam', 3244), timeout=10) as sock:\n"
        "    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)\n"
        "    next_send = time.monotonic()\n"
        "    for _ in range(500):\n"
        "        sock.sendall(packet)\n"
        "        next_send += 0.004\n"
        "        delay = next_send - time.monotonic()\n"
        "        if delay > 0:\n"
        "            time.sleep(delay)\n"
        "PY\n"
    )

    steam.wait_until_succeeds("journalctl -u steamless-uhid --no-pager | grep -q 'input reports='")
  '';
}
