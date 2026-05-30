{
  pkgs,
  lib,
  uinputGamepadPackage,
}:
let
  virtualGamepad = {
    name = "SteamlessLink Virtual Xbox 360 Controller";
    vendor = "045e";
    product = "028e";
    version = "0114";
    packetSize = 20;
    helper = lib.getExe uinputGamepadPackage;
  };

  verifyUinputGamepad = pkgs.writeTextFile {
    name = "verify-steamless-uinput-gamepad";
    executable = true;
    destination = "/bin/verify-steamless-uinput-gamepad";
    text = /* python */ ''
      #!${lib.getExe pkgs.python3}
      import glob
      import os
      import pathlib
      import select
      import struct
      import subprocess
      import threading
      import time

      HELPER = '${virtualGamepad.helper}'
      NAME = '${virtualGamepad.name}'
      VENDOR = '${virtualGamepad.vendor}'
      PRODUCT = '${virtualGamepad.product}'
      VERSION = '${virtualGamepad.version}'
      PACKET_SIZE = ${toString virtualGamepad.packetSize}

      EV_SYN = 0x00
      EV_KEY = 0x01
      EV_ABS = 0x03
      SYN_REPORT = 0

      ABS_X = 0x00
      ABS_Y = 0x01
      ABS_Z = 0x02
      ABS_RX = 0x03
      ABS_RY = 0x04
      ABS_RZ = 0x05
      ABS_HAT0X = 0x10
      ABS_HAT0Y = 0x11

      BTN_A = 0x130
      BTN_B = 0x131
      BTN_TR = 0x137
      BTN_START = 0x13b

      X_DPAD_UP = 0x0001
      X_DPAD_LEFT = 0x0004
      X_START = 0x0010
      X_RIGHT_BUMPER = 0x0200
      X_A = 0x1000
      X_B = 0x2000

      event_struct = struct.Struct('llHHi')

      def read_logs(stream, prefix):
          for line in iter(stream.readline, b""):
              print(prefix + line.decode(errors='replace').rstrip(), flush=True)

      def find_event():
          deadline = time.monotonic() + 5
          while time.monotonic() < deadline:
              for event in glob.glob('/sys/class/input/event*'):
                  root = pathlib.Path(event)
                  name_path = root / 'device/name'
                  if name_path.exists() and name_path.read_text().strip() == NAME:
                      return root
              time.sleep(0.05)
          raise AssertionError('virtual gamepad did not appear')

      def assert_identity(event_root):
          device = event_root / 'device'
          assert (device / 'id/vendor').read_text().strip().lower() == VENDOR
          assert (device / 'id/product').read_text().strip().lower() == PRODUCT
          assert (device / 'id/version').read_text().strip().lower() == VERSION

      def make_packet():
          buttons = X_A | X_B | X_RIGHT_BUMPER | X_START | X_DPAD_LEFT | X_DPAD_UP
          return struct.pack(
              '<IBBhhhh6x',
              buttons,
              64,
              128,
              10000,
              -12000,
              -15000,
              16000,
          )

      def read_events(fd):
          events = []
          deadline = time.monotonic() + 3
          while time.monotonic() < deadline:
              ready, _, _ = select.select([fd], [], [], 0.25)
              if not ready:
                  continue
              chunk = os.read(fd, event_struct.size * 64)
              for offset in range(0, len(chunk) - event_struct.size + 1, event_struct.size):
                  _, _, event_type, code, value = event_struct.unpack_from(chunk, offset)
                  events.append((event_type, code, value))
              if (EV_SYN, SYN_REPORT, 0) in events:
                  break
          return events

      proc = subprocess.Popen(
          [HELPER],
          stdin=subprocess.PIPE,
          stdout=subprocess.PIPE,
          stderr=subprocess.PIPE,
      )
      threading.Thread(target=read_logs, args=(proc.stdout, 'stdout: '), daemon=True).start()
      threading.Thread(target=read_logs, args=(proc.stderr, 'stderr: '), daemon=True).start()
      try:
          event_root = find_event()
          assert_identity(event_root)
          event_path = '/dev/input/' + event_root.name
          fd = os.open(event_path, os.O_RDONLY | os.O_NONBLOCK)
          try:
              proc.stdin.write(make_packet())
              proc.stdin.flush()
              events = read_events(fd)
          finally:
              os.close(fd)

          assert (EV_KEY, BTN_A, 1) in events, events
          assert (EV_KEY, BTN_B, 1) in events, events
          assert (EV_KEY, BTN_TR, 1) in events, events
          assert (EV_KEY, BTN_START, 1) in events, events
          assert (EV_ABS, ABS_X, 10000) in events, events
          assert (EV_ABS, ABS_Y, 12000) in events, events
          assert (EV_ABS, ABS_RX, -15000) in events, events
          assert (EV_ABS, ABS_RY, -16000) in events, events
          assert (EV_ABS, ABS_Z, 64) in events, events
          assert (EV_ABS, ABS_RZ, 128) in events, events
          assert (EV_ABS, ABS_HAT0X, -1) in events, events
          assert (EV_ABS, ABS_HAT0Y, -1) in events, events
          assert (EV_SYN, SYN_REPORT, 0) in events, events
      finally:
          if proc.stdin:
              proc.stdin.close()
          try:
              proc.wait(timeout=5)
          except subprocess.TimeoutExpired:
              proc.terminate()
              proc.wait(timeout=5)
  '';
  };
in
{
  name = "steamless-uinput-gamepad";

  nodes.machine =
    { ... }:
    {
      boot.kernelModules = [ "uinput" ];
      environment.systemPackages = [
        uinputGamepadPackage
        verifyUinputGamepad
      ];
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test -e /dev/uinput")
    machine.succeed("${lib.getExe verifyUinputGamepad}")
  '';
}
