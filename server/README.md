# Steamless UHID server

This directory contains the non-Android half of SteamlessLink: a small Linux daemon that creates a virtual Steam Controller using `/dev/uhid` and proxies Steam's hidraw feature/output traffic back to the Android app.

## Requirements

- Linux with UHID enabled (`uhid` kernel module)
- Python 3.10+
- write access to `/dev/uhid` for the daemon user
- hidraw access for the Steam user
- a trusted TCP path from the Android app to the daemon

Useful upstream docs:

- Linux UHID: <https://docs.kernel.org/hid/uhid.html>
- Linux hidraw: <https://docs.kernel.org/hid/hidraw.html>
- udev rules: <https://www.freedesktop.org/software/systemd/man/latest/udev.html>
- systemd services: <https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html>
- nginx stream proxy, if you want a TCP reverse proxy: <https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html>

## Quick manual install on a systemd distro

```sh
sudo modprobe uhid
sudo install -Dm755 steamless-uhid-server.py /usr/local/bin/steamless-uhid-server
sudo install -Dm644 60-steamless-uhid.rules /etc/udev/rules.d/60-steamless-uhid.rules
sudo install -Dm644 steamless-uhid.service /etc/systemd/system/steamless-uhid.service

# Edit User= and ExecStart= in the service if needed.
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc --subsystem-match=hidraw
sudo systemctl enable --now steamless-uhid
```

If your distro does not have an `input` group, adjust the udev rule and service `SupplementaryGroups=` accordingly. Running the daemon as the same user that runs Steam is the simplest permission model.

## Security

The current protocol is raw TCP and unauthenticated. Do not expose it to an untrusted network.

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

Android -> server:

- `0x01 FRAME_INPUT`: numbered HID input report, normally `0x45` + 45-byte Triton BLE payload
- `0x02 FRAME_GET_REPORT_REPLY`: `u32le request_id`, `u16le errno`, report bytes
- `0x03 FRAME_SET_REPORT_REPLY`: `u32le request_id`, `u16le errno`

Server -> Android:

- `0x81 FRAME_OUTPUT`: `u8 uhid_report_type`, HID output report bytes
- `0x82 FRAME_GET_REPORT`: `u32le request_id`, `u8 report_number`, `u8 report_type`
- `0x83 FRAME_SET_REPORT`: `u32le request_id`, `u8 report_number`, `u8 report_type`, report bytes
