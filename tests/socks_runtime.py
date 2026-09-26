"""Exercise actual Xray SOCKS5 authentication, TCP and UDP on loopback only."""
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def read_exact(conn, size):
    result = b""
    while len(result) < size:
        data = conn.recv(size - len(result))
        if not data:
            raise AssertionError("Unexpected SOCKS connection closure")
        result += data
    return result


def allocate_port():
    with socket.socket() as tcp, socket.socket(type=socket.SOCK_DGRAM) as udp:
        tcp.bind(("127.0.0.1", 0))
        port = tcp.getsockname()[1]
        udp.bind(("127.0.0.1", port))
        return port


def authenticate(port, password=b"test-password"):
    conn = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
        conn.sendall(b"\x05\x01\x02")
        assert read_exact(conn, 2) == b"\x05\x02"
        user = b"test-user"
        conn.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(password)]) + password)
        response = read_exact(conn, 2)
        assert response[0] == 1
        return conn, response[1]
    except BaseException:
        conn.close()
        raise


def request(conn, command, port):
    conn.sendall(bytes([5, command, 0, 1]) + socket.inet_aton("127.0.0.1") + struct.pack("!H", port))
    header = read_exact(conn, 4)
    assert header == b"\x05\x00\x00\x01", header
    return socket.inet_ntoa(read_exact(conn, 4)), struct.unpack("!H", read_exact(conn, 2))[0]


def tcp_echo(listener):
    conn, _ = listener.accept()
    with conn:
        conn.sendall(conn.recv(1024))


def udp_echo(listener):
    data, address = listener.recvfrom(2048)
    listener.sendto(data, address)


def main():
    xray = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory() as prefix:
        ports = [allocate_port() for _ in range(3)]
        env = dict(os.environ, REALITY_ROOT_PREFIX=prefix)
        # Render using the production script, with synthetic test credentials.
        script = r'''
set -euo pipefail
source <(sed '$d' reality.sh)
write_reality_env "$1" 11111111-1111-4111-8111-111111111111 example.com example.com:443 unused public-test aabbccdd 127.0.0.1 chrome Test true
PRIVATE_KEY='CNbUQuA6-wuMRF2DIaS6R3CUJBa7CGO0wLE8Aj0HoH0'
write_ss_env 127.0.0.1 "$2" aes-256-gcm test-password Test
write_socks_env 127.0.0.1 "$3" test-user test-password Test 127.0.0.1
rebuild_config
'''
        subprocess.run(["bash", "-c", script, "test", *map(str, ports)], env=env, check=True)
        config = str(Path(prefix) / "etc/reality-onekey/config.json")
        subprocess.run([xray, "run", "-test", "-c", config], check=True)
        with tempfile.TemporaryFile() as log:
            process = subprocess.Popen([xray, "run", "-c", config], stdout=log, stderr=log)
            try:
                for _ in range(50):
                    if process.poll() is not None:
                        raise AssertionError("Xray exited during startup")
                    try:
                        probe = socket.create_connection(("127.0.0.1", ports[2]), timeout=0.2)
                        probe.close()
                        break
                    except OSError:
                        time.sleep(0.1)
                else:
                    raise AssertionError("SOCKS listener did not start")
                with socket.create_connection(("127.0.0.1", ports[2]), timeout=5) as conn:
                    conn.sendall(b"\x05\x01\x00")
                    assert read_exact(conn, 2) == b"\x05\xff", "Anonymous access accepted"
                conn, status = authenticate(ports[2], b"wrong-password")
                conn.close()
                assert status != 0, "Wrong password accepted"
                with socket.socket() as echo:
                    echo.bind(("127.0.0.1", 0))
                    echo.listen()
                    echo.settimeout(5)
                    worker = threading.Thread(target=tcp_echo, args=(echo,), daemon=True)
                    worker.start()
                    conn, status = authenticate(ports[2])
                    with conn:
                        assert status == 0
                        request(conn, 1, echo.getsockname()[1])
                        conn.sendall(b"SOCKS TCP test")
                        assert read_exact(conn, 14) == b"SOCKS TCP test"
                    worker.join(timeout=5)
                with socket.socket(type=socket.SOCK_DGRAM) as echo, socket.socket(type=socket.SOCK_DGRAM) as udp:
                    echo.bind(("127.0.0.1", 0))
                    echo.settimeout(5)
                    udp.bind(("127.0.0.1", 0))
                    udp.settimeout(5)
                    worker = threading.Thread(target=udp_echo, args=(echo,), daemon=True)
                    worker.start()
                    conn, status = authenticate(ports[2])
                    with conn:
                        assert status == 0
                        relay = request(conn, 3, udp.getsockname()[1])
                        assert relay == ("127.0.0.1", ports[2]), relay
                        packet = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", echo.getsockname()[1]) + b"SOCKS UDP test"
                        # The server installs its UDP authorization after writing
                        # the association response; retries cover that small race.
                        for _ in range(3):
                            udp.sendto(packet, relay)
                            try:
                                data, _ = udp.recvfrom(2048)
                                break
                            except socket.timeout:
                                continue
                        else:
                            raise AssertionError("SOCKS UDP response timed out")
                        assert data == packet, data
                    worker.join(timeout=5)
                print("Actual Xray: auth rejection, TCP and UDP round trips passed")
            except BaseException:
                log.seek(0)
                print(log.read().decode(errors="replace"), file=sys.stderr)
                raise
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
