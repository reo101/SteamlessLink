#!/usr/bin/env python3
"""SteamlessLink raw TCP to Linux UHID bridge.

The Android app forwards raw Steam Controller/Triton BLE HID-ish reports over a
small framed TCP protocol. This daemon creates a Linux UHID device that Steam can
open through hidraw, injects input reports, and proxies Steam feature/output
traffic back to the Android app so battery, ping, haptics, and configuration keep
working.
"""

from __future__ import annotations

import argparse
import errno
import logging
import os
import socket
import struct
import threading
import time
from dataclasses import dataclass

UHID_DESTROY = 1
UHID_START = 2
UHID_STOP = 3
UHID_OPEN = 4
UHID_CLOSE = 5
UHID_OUTPUT = 6
UHID_GET_REPORT = 9
UHID_GET_REPORT_REPLY = 10
UHID_CREATE2 = 11
UHID_INPUT2 = 12
UHID_SET_REPORT = 13
UHID_SET_REPORT_REPLY = 14

UHID_DATA_MAX = 4096
UHID_CREATE2_SIZE = 128 + 64 + 64 + 2 + 2 + 4 + 4 + 4 + 4 + UHID_DATA_MAX
UHID_EVENT_SIZE = 4 + UHID_CREATE2_SIZE

BUS_USB = 0x03
VALVE_VID = 0x28DE
TRITON_BLE_PID = 0x1303

FRAME_INPUT = 0x01
FRAME_GET_REPORT_REPLY = 0x02
FRAME_SET_REPORT_REPLY = 0x03
FRAME_OUTPUT = 0x81
FRAME_GET_REPORT = 0x82
FRAME_SET_REPORT = 0x83

_active_client: socket.socket | None = None
_active_client_lock = threading.Lock()


def vendor_report_descriptor() -> bytes:
    """Return the permissive Valve/Triton report descriptor used for UHID.

    Steam identifies the virtual controller primarily by Valve VID/PID and then
    speaks numbered raw reports through hidraw. The descriptor advertises the
    numbered input, feature, and output report IDs Steam uses on the Triton/BLE
    path without trying to model each field semantically.
    """

    out = bytearray([
        0x06,
        0x00,
        0xFF,  # Usage Page (Vendor Defined 0xff00)
        0x09,
        0x01,  # Usage 1
        0xA1,
        0x01,  # Collection Application
    ])

    def add_report(report_id: int, main_item: int, count: int) -> None:
        out.extend([
            0x85,
            report_id & 0xFF,  # Report ID
            0x09,
            0x01,  # Usage 1
            0x15,
            0x00,  # Logical Min 0
            0x26,
            0xFF,
            0x00,  # Logical Max 255
            0x75,
            0x08,  # Report Size 8
            0x95,
            count & 0xFF,  # Report Count
            main_item,
            0x02,  # Input/Output/Feature Data,Var,Abs
        ])

    # Inputs. 0x45 is Triton BLE state; 0x42 is USB state; 0x43 is status-ish.
    add_report(0x45, 0x81, 45)
    add_report(0x42, 0x81, 63)
    add_report(0x43, 0x81, 63)

    # Common Valve feature reports used by Steam Controller tooling.
    for report_id in (0x01, 0x03, 0x04, 0x08, 0x09):
        add_report(report_id, 0xB1, 63)

    # Triton BLE output characteristics map to UUID 100f6c(b5..be), i.e. logical
    # report IDs 0x80..0x89.
    for report_id in range(0x80, 0x8A):
        add_report(report_id, 0x91, 63)

    out.append(0xC0)  # End Collection
    return bytes(out)


REPORT_DESCRIPTOR = vendor_report_descriptor()


def zbytes(value: str, size: int) -> bytes:
    raw = value.encode("utf-8")[: size - 1]
    return raw + b"\0" * (size - len(raw))


def padded_event(event_type: int, payload: bytes = b"") -> bytes:
    if len(payload) > UHID_CREATE2_SIZE:
        raise ValueError(f"UHID payload too large: {len(payload)}")
    return struct.pack("<I", event_type) + payload + b"\0" * (UHID_CREATE2_SIZE - len(payload))


def log_control_event(count: int, message: str, *args: object) -> None:
    level = logging.INFO if count <= 20 or count % 100 == 0 else logging.DEBUG
    logging.log(level, message, *args)


def replace_active_client(conn: socket.socket) -> None:
    global _active_client
    with _active_client_lock:
        old = _active_client
        _active_client = conn
    if old is not None and old is not conn:
        try:
            old.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            old.close()
        except OSError:
            pass


def clear_active_client(conn: socket.socket) -> None:
    global _active_client
    with _active_client_lock:
        if _active_client is conn:
            _active_client = None


@dataclass(frozen=True)
class UhidIdentity:
    name: str = "Steam Controller"
    phys: str = "steamlesslink/input0"
    uniq: str = "steamlesslink-triton"
    bus: int = BUS_USB
    vendor: int = VALVE_VID
    product: int = TRITON_BLE_PID
    version: int = 0x0110
    country: int = 0


class UhidSteamController:
    def __init__(self, identity: UhidIdentity, uhid_path: str) -> None:
        self.fd = os.open(uhid_path, os.O_RDWR | os.O_CLOEXEC)
        self.lock = threading.Lock()
        self.identity = identity
        self._destroyed = False
        self.create()

    def write_event(self, event_type: int, payload: bytes = b"") -> None:
        with self.lock:
            os.write(self.fd, padded_event(event_type, payload))

    def create(self) -> None:
        rd = REPORT_DESCRIPTOR
        identity = self.identity
        payload = b"".join([
            zbytes(identity.name, 128),
            zbytes(identity.phys, 64),
            zbytes(identity.uniq, 64),
            struct.pack(
                "<HHIIII",
                len(rd),
                identity.bus,
                identity.vendor,
                identity.product,
                identity.version,
                identity.country,
            ),
            rd + b"\0" * (UHID_DATA_MAX - len(rd)),
        ])
        self.write_event(UHID_CREATE2, payload)
        logging.info(
            "created UHID device name=%r vid=0x%04x pid=0x%04x rd_size=%d",
            identity.name,
            identity.vendor,
            identity.product,
            len(rd),
        )

    def input_report(self, data: bytes) -> None:
        if not data:
            return
        if len(data) > UHID_DATA_MAX:
            logging.warning("dropping oversized input report len=%d", len(data))
            return
        payload = struct.pack("<H", len(data)) + data + b"\0" * (UHID_DATA_MAX - len(data))
        self.write_event(UHID_INPUT2, payload)

    def get_report_reply(self, request_id: int, err: int, data: bytes) -> None:
        if len(data) > UHID_DATA_MAX:
            data = data[:UHID_DATA_MAX]
        payload = struct.pack("<IHH", request_id, err, len(data)) + data + b"\0" * (UHID_DATA_MAX - len(data))
        self.write_event(UHID_GET_REPORT_REPLY, payload)
        logging.debug("GET_REPORT reply id=%d err=%d size=%d", request_id, err, len(data))

    def set_report_reply(self, request_id: int, err: int) -> None:
        self.write_event(UHID_SET_REPORT_REPLY, struct.pack("<IH", request_id, err))

    def destroy(self) -> None:
        if self._destroyed:
            return
        self._destroyed = True
        try:
            self.write_event(UHID_DESTROY)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass


def send_frame(conn: socket.socket, frame_type: int, payload: bytes) -> None:
    if len(payload) > 65535:
        payload = payload[:65535]
    conn.sendall(bytes([frame_type]) + struct.pack("!H", len(payload)) + payload)


def recv_exact(conn: socket.socket, size: int) -> bytes | None:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = conn.recv(size - len(chunks))
        if not chunk:
            return None
        chunks.extend(chunk)
    return bytes(chunks)


def read_frame(conn: socket.socket) -> tuple[int | None, bytes | None]:
    header = recv_exact(conn, 3)
    if header is None:
        return None, None
    frame_type = header[0]
    size = struct.unpack("!H", header[1:3])[0]
    payload = recv_exact(conn, size)
    if payload is None:
        return None, None
    return frame_type, payload


def uhid_reader(dev: UhidSteamController, conn: socket.socket, stop: threading.Event) -> None:
    control_events = 0
    while not stop.is_set():
        try:
            ev = os.read(dev.fd, UHID_EVENT_SIZE)
        except OSError as e:
            if e.errno in (errno.EBADF, errno.EIO):
                return
            logging.warning("UHID read failed: %s", e)
            return
        if len(ev) < 4:
            continue
        event_type = struct.unpack_from("<I", ev, 0)[0]
        payload = ev[4:]
        if event_type == UHID_START:
            dev_flags = struct.unpack_from("<Q", payload, 0)[0]
            logging.info("UHID start flags=0x%x", dev_flags)
        elif event_type in (UHID_STOP, UHID_OPEN, UHID_CLOSE):
            logging.info("UHID event type=%d", event_type)
        elif event_type == UHID_OUTPUT:
            control_events += 1
            size = struct.unpack_from("<H", payload, UHID_DATA_MAX)[0]
            report_type = payload[UHID_DATA_MAX + 2]
            data = payload[:size]
            log_control_event(control_events, "UHID output rtype=%d len=%d head=%s", report_type, size, data[:8].hex(" "))
            try:
                send_frame(conn, FRAME_OUTPUT, bytes([report_type]) + data)
            except OSError:
                return
        elif event_type == UHID_GET_REPORT:
            control_events += 1
            request_id, report_num, report_type = struct.unpack_from("<IBB", payload, 0)
            log_control_event(control_events, "UHID get_report id=%d rnum=0x%02x rtype=%d", request_id, report_num, report_type)
            try:
                send_frame(conn, FRAME_GET_REPORT, struct.pack("<IBB", request_id, report_num, report_type))
            except OSError:
                return
        elif event_type == UHID_SET_REPORT:
            control_events += 1
            request_id, report_num, report_type, size = struct.unpack_from("<IBBH", payload, 0)
            data = payload[8 : 8 + size]
            log_control_event(
                control_events,
                "UHID set_report id=%d rnum=0x%02x rtype=%d len=%d head=%s",
                request_id,
                report_num,
                report_type,
                size,
                data[:8].hex(" "),
            )
            try:
                send_frame(conn, FRAME_SET_REPORT, struct.pack("<IBB", request_id, report_num, report_type) + data)
            except OSError:
                return
        else:
            logging.debug("UHID event type=%d", event_type)


def handle_client(conn: socket.socket, addr: tuple[str, int], identity: UhidIdentity, uhid_path: str) -> None:
    logging.info("client connected remote=%s:%s", *addr)
    try:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass
    replace_active_client(conn)
    stop = threading.Event()
    dev = UhidSteamController(identity, uhid_path)
    reader = threading.Thread(target=uhid_reader, args=(dev, conn, stop), daemon=True)
    reader.start()
    reports = 0
    last_log = 0.0
    try:
        while True:
            frame_type, payload = read_frame(conn)
            if frame_type is None or payload is None:
                break
            if frame_type == FRAME_INPUT:
                reports += 1
                now = time.monotonic()
                if now - last_log >= 1.0:
                    last_log = now
                    report_id = payload[0] if payload else -1
                    logging.info("input reports=%d id=0x%02x len=%d head=%s", reports, report_id, len(payload), payload[:8].hex(" "))
                dev.input_report(payload)
            elif frame_type == FRAME_GET_REPORT_REPLY:
                if len(payload) < 6:
                    continue
                request_id, err = struct.unpack_from("<IH", payload, 0)
                data = payload[6:]
                dev.get_report_reply(request_id, err, data)
            elif frame_type == FRAME_SET_REPORT_REPLY:
                if len(payload) < 6:
                    continue
                request_id, err = struct.unpack_from("<IH", payload, 0)
                dev.set_report_reply(request_id, err)
            else:
                logging.debug("ignoring client frame type=0x%02x len=%d", frame_type, len(payload))
    finally:
        stop.set()
        dev.destroy()
        clear_active_client(conn)
        try:
            conn.close()
        except OSError:
            pass
        logging.info("client disconnected remote=%s:%s reports=%d", *addr, reports)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="SteamlessLink raw Triton-to-UHID bridge")
    parser.add_argument("--listen-host", default="127.0.0.1", help="address to bind, e.g. 127.0.0.1 or 0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=3244, help="TCP port for SteamlessLink raw UHID frames")
    parser.add_argument("--uhid-path", default="/dev/uhid", help="path to Linux UHID device")
    parser.add_argument("--name", default="Steam Controller", help="UHID device name exposed to Steam")
    parser.add_argument("--phys", default="steamlesslink/input0", help="UHID physical path string")
    parser.add_argument("--uniq", default="steamlesslink-triton", help="UHID unique path string")
    parser.add_argument("--vid", type=lambda s: int(s, 0), default=VALVE_VID, help="USB/vendor ID, default 0x28de")
    parser.add_argument("--pid", type=lambda s: int(s, 0), default=TRITON_BLE_PID, help="product ID, default 0x1303")
    parser.add_argument("--version", type=lambda s: int(s, 0), default=0x0110, help="device version")
    parser.add_argument("--log-level", default="info", choices=["debug", "info", "warning", "error"])
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=getattr(logging, args.log_level.upper()), format="%(asctime)s %(levelname)s %(message)s")
    identity = UhidIdentity(name=args.name, phys=args.phys, uniq=args.uniq, vendor=args.vid, product=args.pid, version=args.version)

    family = socket.AF_INET6 if ":" in args.listen_host else socket.AF_INET
    with socket.socket(family, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((args.listen_host, args.listen_port))
        server.listen(4)
        logging.info("listening on %s:%d", args.listen_host, args.listen_port)
        while True:
            conn, addr = server.accept()
            thread = threading.Thread(target=handle_client, args=(conn, addr, identity, args.uhid_path), daemon=True)
            thread.start()


if __name__ == "__main__":
    main()
