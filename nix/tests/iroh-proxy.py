"""Local-only proxy acceptance, identity, EOF and disconnect tests."""
import os
import pathlib
import select
import socket
import subprocess
import sys
import tempfile
import threading

PROXY = sys.argv[1]
# Public RFC 8032 Ed25519 test vector, never a production credential.
CLIENT_SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
CLIENT_ID = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
PAYLOAD = b"steamless-iroh-eof"

with tempfile.TemporaryDirectory(prefix="steamless-iroh-test-") as directory:
    root = pathlib.Path(directory)
    key = root / "controller.key"
    key.write_bytes(CLIENT_SEED)
    key.chmod(0o600)
    target = socket.socket()
    target.bind(("127.0.0.1", 0))
    target.listen()
    target.settimeout(5)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    environment = dict(os.environ, STEAMLESS_IROH_BIND_ADDR=f"127.0.0.1:{port}",
                       STEAMLESS_IROH_EXTERNAL_ADDR=f"127.0.0.1:{port}")
    command = [PROXY, "--identity-key", str(root / "host.key"), "--allow-peer", CLIENT_ID,
               f"127.0.0.1:{target.getsockname()[1]}"]

    def start_proxy():
        process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE)
        assert select.select([process.stdout], [], [], 10)[0], "no proxy ticket"
        ticket = process.stdout.readline().decode().strip()
        assert ticket.startswith("endpoint"), ticket
        return process, ticket

    def stop_proxy(process):
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    proxy, ticket = start_proxy()
    stop_proxy(proxy)
    proxy, restarted = start_proxy()
    assert ticket == restarted, "persistent host identity changed"
    assert (root / "host.key").stat().st_mode & 0o777 == 0o600
    client_environment = dict(os.environ, STEAMLESS_IROH_BIND_ADDR="127.0.0.1:0")

    def client(authorized=True):
        args = [PROXY, "connect"]
        if authorized:
            args += ["--identity-key", str(key)]
        return subprocess.run(args + [ticket], input=PAYLOAD, capture_output=True,
                              env=client_environment, timeout=8)

    try:
        denied = client(False)
        assert denied.returncode != 0, "unknown controller was authorized"
        assert not select.select([target], [], [], 0.2)[0], "unknown controller opened TCP target"
        print("unknown controller rejected before TCP connect", flush=True)

        for reply_after_eof in (False, True):
            failures = []

            def serve():
                try:
                    connection, _ = target.accept()
                    with connection:
                        connection.settimeout(5)
                        data = bytearray()
                        while True:
                            chunk = connection.recv(4096)
                            if not chunk:
                                break
                            data.extend(chunk)
                            if not reply_after_eof:
                                connection.sendall(chunk)
                        if reply_after_eof:
                            connection.sendall(data)
                        assert data == PAYLOAD, data
                except Exception as error:
                    failures.append(error)

            worker = threading.Thread(target=serve)
            worker.start()
            result = client()
            worker.join(timeout=6)
            assert not worker.is_alive(), "TCP target did not observe EOF"
            assert not failures, failures
            assert result.returncode == 0, result.stderr.decode()
            assert result.stdout == PAYLOAD, result.stdout
            print(f"authorized response, reply_after_eof={reply_after_eof}: passed", flush=True)

        def close_target():
            connection, _ = target.accept()
            with connection:
                connection.recv(4096)

        worker = threading.Thread(target=close_target)
        worker.start()
        result = client()
        worker.join(timeout=6)
        assert result.returncode != 0, "missing response was accepted"
        assert not worker.is_alive()
        print("target disconnect reaches controller", flush=True)
    finally:
        stop_proxy(proxy)
        target.close()
