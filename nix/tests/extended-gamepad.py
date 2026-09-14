"""Real mapper/descriptor fixtures, exercised through TCP -> UHID -> evdev/IIO."""
import glob
import json
import os
import pathlib
import select
import socket
import struct
import sys
import threading
import time

fixture = json.loads(pathlib.Path(sys.argv[2]).read_text())
names = [bytes(name).decode() for name in fixture['names']]
descriptors = list(map(bytes, fixture['descriptors']))

def reports(which):
    packet = bytes(fixture[which])
    result, offset = [], 0
    for device, size in zip(fixture['devices'], fixture['sizes']):
        result.append((device, packet[offset:offset + size]))
        offset += size
    assert offset == len(packet)
    return result

active, neutral = reports('active'), reports('neutral')

def client():
    lock = threading.Lock()
    features = {i: bytes([i, 1, 5, 4, 0, 0, 0]) for i in (1, 2)}
    sensor_inputs = {data[0]: data for slot, data in active if slot == 3}
    failures = []
    with socket.create_connection(('steam', 3244), timeout=10) as sock:
        sock.settimeout(None)
        def send(kind, payload):
            with lock:
                sock.sendall(bytes([kind]) + struct.pack('!H', len(payload)) + payload)
        def exact(size):
            result = b''
            while len(result) < size:
                part = sock.recv(size - len(result))
                if not part:
                    raise EOFError()
                result += part
            return result
        def receive():
            header = exact(3)
            return header[0], exact(struct.unpack('!H', header[1:])[0])
        infos = []
        for name, descriptor in zip(names, descriptors):
            encoded_name = name.encode()
            info = struct.pack('<IHHH', 3, 0, 0, len(descriptor)) + descriptor + bytes([len(encoded_name)]) + encoded_name
            infos.append(struct.pack('<H', len(info)) + info)
        send(7, bytes([len(infos)]) + b''.join(infos))
        assert receive() == (0x87, bytes([len(infos)]))
        def control():
            try:
                while True:
                    kind, payload = receive()
                    assert kind == 6 and len(payload) >= 2, (kind, payload)
                    slot, kind, data = payload[0], payload[1], payload[2:]
                    if kind == 0x82:
                        request, number, report_type = struct.unpack('<IBB', data)
                        report = (features if report_type == 0 else sensor_inputs).get(number) if slot == 3 else None
                        reply = struct.pack('<IH', request, 0 if report is not None else 5) + (report or b'')
                        send(6, bytes([slot, 2]) + reply)
                    elif kind == 0x83:
                        request, number, report_type = struct.unpack('<IBB', data[:6])
                        assert slot == 3 and number in features and report_type == 0, (slot, data)
                        assert len(data[6:]) == 7 and data[6] == number, data
                        features[number] = data[6:]
                        send(6, bytes([slot, 3]) + struct.pack('<IH', request, 0))
            except Exception as error:
                failures.append(error)
        threading.Thread(target=control, daemon=True).start()
        pathlib.Path('/tmp/extended-ready').touch()
        deadline = time.monotonic() + 60
        index = 0
        while time.monotonic() < deadline and not pathlib.Path('/tmp/extended-stop').exists():
            if failures:
                raise failures[0]
            for slot, data in active if index % 2 else neutral:
                if slot != 3 or features[data[0]][1:3] == bytes([2, 1]):
                    send(6, bytes([slot, 1]) + data)
            index += 1
            time.sleep(.004)
        assert pathlib.Path('/tmp/extended-stop').exists(), 'verification did not finish'
        sock.shutdown(socket.SHUT_RDWR)
    pathlib.Path('/tmp/extended-done').touch()

def verify():
    hid_devices = {}
    for path in glob.glob('/sys/bus/hid/devices/*'):
        root = pathlib.Path(path)
        uevent = (root / 'uevent').read_text()
        for index, name in enumerate(names):
            if f'HID_NAME={name}\n' in uevent:
                assert (root / 'report_descriptor').read_bytes() == descriptors[index]
                hid_devices[index] = root
    assert len(hid_devices) == len(names), hid_devices
    assert 'hid-sensor-hub' in str((hid_devices[3] / 'driver').resolve())
    fds, seen = {}, {0: set(), 1: set(), 2: set()}
    event = struct.Struct('llHHi')
    try:
        for slot in range(3):
            paths = list(hid_devices[slot].glob('input/input*/event*'))
            assert len(paths) == 1, (slot, paths)
            fds[os.open('/dev/input/' + paths[0].name, os.O_RDONLY | os.O_NONBLOCK)] = slot
        # EV_KEY / BTN_SOUTH; generic HID button 17..20 maps to BTN_TRIGGER_HAPPY1..4.
        expected = {
            0: {(1, 0x130, 1), (1, 0x2c0, 1), (1, 0x2c1, 1), (1, 0x2c2, 1), (1, 0x2c3, 1), (1, 0x130, 0)},
            1: {(1, 0x14a, 1), (1, 0x14a, 0), (3, 0, 31768), (3, 1, 30767), (3, 0x18, 1234)},
            2: {(1, 0x14a, 1), (1, 0x14a, 0), (3, 0, 35768), (3, 1, 36767), (3, 0x18, 2345)},
        }
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            ready, _, _ = select.select(list(fds), [], [], .2)
            for fd in ready:
                data = os.read(fd, event.size * 64)
                for offset in range(0, len(data), event.size):
                    _, _, kind, code, value = event.unpack_from(data, offset)
                    seen[fds[fd]].add((kind, code, value))
            if all(expected[slot] <= seen[slot] for slot in seen):
                break
        assert all(expected[slot] <= seen[slot] for slot in seen), {slot: expected[slot] - seen[slot] for slot in seen}
    finally:
        for fd in fds:
            os.close(fd)
    sensors = { (path / 'name').read_text().strip(): path for path in pathlib.Path('/sys/bus/iio/devices').glob('iio:device*') }
    for name, channel, expected_value in [('accel_3d', 'accel_x', 9806650), ('gyro_3d', 'anglvel_z', 34906585)]:
        root = sensors[name]
        assert int((root / f'in_{channel}_raw').read_text()) == expected_value
        scale = root / ('in_accel_scale' if name == 'accel_3d' else 'in_anglvel_scale')
        assert abs(float(scale.read_text()) - 1e-6) < 1e-12
        assert float(scale.with_name(scale.name.replace('_scale', '_sampling_frequency')).read_text()) == 250
        # HID sensor drivers push their complete XYZ scan structure.
        for axis in 'xyz':
            (root / 'scan_elements' / f'in_{channel[:-1]}{axis}_en').write_text('1')
        (root / 'buffer' / 'length').write_text('2')
        fd = os.open('/dev/' + root.name, os.O_RDONLY | os.O_NONBLOCK)
        try:
            (root / 'buffer' / 'enable').write_text('1')
            deadline = time.monotonic() + 3
            values = set()
            while time.monotonic() < deadline and expected_value not in values:
                if select.select([fd], [], [], .2)[0]:
                    values.update(sample['xyz'.index(channel[-1])] for sample in struct.iter_unpack('<iii', os.read(fd, 12 * 16)))
            assert expected_value in values, (name, values)
        finally:
            (root / 'buffer' / 'enable').write_text('0')
            os.close(fd)
    print('ok: gamepad + four paddles, two touchpads with release/pressure, accel + gyro IIO direct and buffered reads')

if sys.argv[1] == 'client':
    client()
else:
    verify()
