# Steamless Link host

This directory contains the Steam-host half of SteamlessLink: a small Zig/Linux daemon that creates a virtual Steam Controller using `/dev/uhid` and proxies Steam's hidraw feature/output traffic back to a controller. A client may instead send device information first, causing the host to create that HID descriptor and identity, including a standard generic gamepad.

## Requirements

- Linux with UHID enabled (`uhid` kernel module)
- Zig 0.16+ to build from source, or the Nix package from this flake
- write access to `/dev/uhid` for the daemon user
- hidraw access for the Steam user
- a trusted TCP path from the Android app to the daemon

Useful upstream docs:

- Linux UHID: <https://docs.kernel.org/hid/uhid.html>
- Linux hidraw: <https://docs.kernel.org/hid/hidraw.html>
- Linux gamepad specification: <https://docs.kernel.org/input/gamepad.html>
- udev rules: <https://www.freedesktop.org/software/systemd/man/latest/udev.html>
- systemd services: <https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html>
- nginx stream proxy, if you want a TCP reverse proxy: <https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html>

## Quick manual install on a systemd distro

```sh
sudo modprobe uhid

zig build -Doptimize=ReleaseSafe
sudo install -Dm755 zig-out/bin/steamless-link-host /usr/local/bin/steamless-link-host

sudo install -Dm644 60-steamless-link-host.rules /etc/udev/rules.d/60-steamless-link-host.rules
sudo install -Dm644 steamless-link-host.service /etc/systemd/system/steamless-link-host.service

# Edit User= and ExecStart= in the service if needed.
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc --subsystem-match=hidraw
sudo systemctl enable --now steamless-link-host
```

If your distro does not have an `input` group, adjust the udev rule and service `SupplementaryGroups=` accordingly. Running the daemon as the same user that runs Steam is the simplest permission model.

## Nix

Build the daemon with:

```sh
nix build .#steamless-link-host
```

On NixOS, import `nixosModules.steamless-link-host` from this flake and enable `services.steamless-link-host`. The flake module defaults to this flake's Zig 0.16-built package. If you import `nix/modules/steamless-link-host.nix` directly, set `services.steamless-link-host.package` to a package built with Zig 0.16+.

## Security

The current protocol is raw TCP and unauthenticated. Do not expose it to an untrusted network. If `--iroh-ticket-file` is configured, raw-TCP peers can request the Iroh route too.

Safer deployment options:

- bind to localhost and use an SSH tunnel
- bind only on a trusted LAN/VPN interface
- firewall the port to the Android device
- add authentication/TLS in a future protocol revision

## Protocol

Every TCP frame is:

```text
u8 frame_type
u16be payload_length
payload bytes
```

Controller -> host:

- `0x01 FRAME_INPUT`: numbered HID input report, normally `0x47` or legacy
  `0x45` + 45-byte Triton BLE payload
- `0x02 FRAME_GET_REPORT_REPLY`: `u32le request_id`, `u16le errno`, report bytes
- `0x03 FRAME_SET_REPORT_REPLY`: `u32le request_id`, `u16le errno`
- `0x04 FRAME_DEVICE_INFO`: `u32le bus`, `u16le vendor`, `u16le product`,
  `u16le descriptor_length`, HID report descriptor, then optionally `u8
  name_length`, UTF-8 name bytes. The trailing name extension is omitted when empty,
  so old clients retain the original frame shape. It must precede input; the
  host mirrors that identity, descriptor, and optional host-visible name in its
  UHID device. Clients without this frame use the legacy Triton BLE descriptor.
  Names are limited to 127 non-NUL UTF-8 bytes.
- `0x05 FRAME_GET_IROH_TICKET`: empty one-shot request. Available only when
  `--iroh-ticket-file` points at the proxy's private ticket file.
- `0x07 FRAME_DEVICE_BUNDLE`: initial `u8 device_count` (1..4), followed by
  `device_count` entries of `u16le info_length` and a `FRAME_DEVICE_INFO` payload.
  Descriptors are bounded to 4096 bytes per device. Truncated entries, invalid
  identities, and trailing bytes are rejected. Partial creation is cleaned up.

Host -> controller:

- `0x81 FRAME_OUTPUT`: `u8 uhid_report_type`, HID output report bytes
- `0x82 FRAME_GET_REPORT`: `u32le request_id`, `u8 report_number`, `u8 report_type`
- `0x83 FRAME_SET_REPORT`: `u32le request_id`, `u8 report_number`, `u8 report_type`, report bytes
- `0x85 FRAME_IROH_TICKET`: endpoint ticket bytes
- `0x87 FRAME_DEVICE_BUNDLE_READY`: `u8 device_count`, acknowledging the bundle
  after its UHID devices have been created. This is not a promise that every
  host driver or application supports their descriptors.

In either direction, a bundled connection uses `0x06 FRAME_DEVICE_FRAME`:
`u8 device_index`, `u8 inner_frame_type`, inner payload. Slots are zero-based;
**all** device traffic, including slot zero, is wrapped. Client-to-host inner
frames are input/get-report-reply/set-report-reply; host-to-client frames are
output/get-report/set-report. Report request IDs are local to each device.
Nested wrappers and out-of-range slots are invalid. The Android client waits
at most five seconds for the matching bundle acknowledgement before closing.
Legacy single-device connections do not use these wrappers or acknowledgement.

### Extended Generic HID profile

Zig's `core/src/extended_gamepad.zig` owns the descriptors and packed wire types.
Sizes use exact bit-to-byte division, offsets derive from fields, and report
serialization is explicitly little-endian, never a copy of padded struct memory.
Android metadata and controller initialization payloads are generated from Zig.

All devices use USB bus type and vendor/product IDs `0000:0000`, without
impersonating another manufacturer's controller:

| Slot | Name | Input reports, including ID |
| --- | --- | --- |
| 0 | SteamlessLink Extended Gamepad | ID 1, 12 bytes: 32 button bits, hat byte, six unsigned byte axes |
| 1 | SteamlessLink Left Touchpad | ID 1, 8 bytes: tip-contact bit with padding, u16 X/Y/pressure |
| 2 | SteamlessLink Right Touchpad | Same as left pad |
| 3 | SteamlessLink Motion Sensors | IDs 1 (accel) and 2 (gyro), 13 bytes each: three signed i32 axes |

Gamepad buttons 1..15 retain the small generic profile's mapping. Buttons 16..30
are QAM, L4, R4, L5, R5, left/right pad clicks, left/right trigger clicks,
left/right stick touch, left/right pad touch, left/right grip touch. Buttons
31..32 are reserved. Sticks and pads invert Triton's Y direction to HID's
positive-down convention. Touchpads are independent absolute single-contact
digitizers, not gestures or emulated mouse deltas; pressure is zero when released.

Motion axes use SDL's `X, Z, -Y` orientation. Values are micro m/s² and micro rad/s,
with an IIO scale of `0.000001`. Source ranges are ±2g and ±2000 degrees/s. Each
axis has its own HID field, as required by Linux's sensor-hub dispatch. The
separate sensor device avoids sensor-hub binding swallowing gamepad events.
Triton timestamps are parsed but not forwarded; buffered IIO timestamps use the
host's arrival time. Enable all XYZ scan elements when reading buffered samples.

Each sensor also has a seven-byte numbered feature report:
`u8 id`, `u8 reporting_state`, `u8 power_state`, `u32le interval_ms`.
Reporting state is 1 (no events) or 2 (all events); power is 1 (full) through
5 (off). Defaults are no-events/off, interval 4 ms. Only the fixed 4 ms interval
is accepted. Streaming requires both all-events and full-power; direct input
GETs return the cached latest sample even when streaming is disabled. Feature
GET/SET and input GET use Linux UHID report types 0 and 2 respectively, not USB
control-transfer report-type numbering. Unsupported controls return EIO and are
never forwarded to Triton.

The host needs `hid-sensor-hub`, `hid-sensor-accel-3d`, and `hid-sensor-gyro-3d`
for IIO support. IIO access permissions are consumer/distro policy, separate
from the existing Steam hidraw rules. Steam/SDL do not automatically associate
these companion devices with controller motion. No haptics, Sony/Xbox spoofing,
or automatic Steam gyro integration is provided.

Protocol references:

- [SDL Triton driver](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_steam_triton.c)
- [SDL Triton structures](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/steam/controller_structs.h)
- [SDL controller settings](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/steam/controller_constants.h)
- [Linux HID sensor hub](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-sensor-hub.c)
- [Linux HID sensor IIO drivers](https://github.com/torvalds/linux/tree/master/drivers/iio)
