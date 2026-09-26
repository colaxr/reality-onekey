"""Real pinned independent SOCKS5: auth, fixed-port UDP, concurrent clients, NAT IP."""
import contextlib
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from socks_runtime import allocate_port, authenticate, read_exact, request, tcp_echo


def exercise(binary, public_ip, main_binary=None):
    with tempfile.TemporaryDirectory() as prefix:
        port = allocate_port()
        env = dict(os.environ, REALITY_ROOT_PREFIX=prefix)
        script = r'''
set -euo pipefail
source <(sed '$d' reality.sh)
write_socks_env 127.0.0.1 "$1" test-user test-password Test "$2" xray-fixed
mkdir -p "$SOCKS_DIR"
render_socks_config > "$SOCKS_CONFIG"
! has_xray_nodes
! managed_listeners | grep .
if rebuild_config; then exit 1; fi
'''
        subprocess.run(["bash", "-c", script, "test", str(port), public_ip], env=env, check=True)
        config = str(Path(prefix) / "etc/reality-onekey-socks/config.json")
        subprocess.run([binary, "run", "-test", "-c", config], check=True)
        main_process = None
        if main_binary:
            main_script = r'''
set -euo pipefail
source <(sed '$d' reality.sh)
write_ss_env 127.0.0.1 "$1" aes-256-gcm test-password Main
rebuild_config
! grep -q socks-in "$CONFIG_FILE"
'''
            subprocess.run(["bash", "-c", main_script, "test", str(allocate_port())], env=env, check=True)
            main_config = str(Path(prefix) / "etc/reality-onekey/config.json")
            subprocess.run([main_binary, "run", "-test", "-c", main_config], check=True)
            main_process = subprocess.Popen([main_binary, "run", "-c", main_config])
        with tempfile.TemporaryFile() as log:
            process = subprocess.Popen([binary, "run", "-c", config], stdout=log, stderr=log)
            try:
                for _ in range(50):
                    assert process.poll() is None, "Independent SOCKS exited"
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=.2):
                            break
                    except OSError:
                        time.sleep(.1)
                else:
                    raise AssertionError("Independent SOCKS startup timed out")
                with socket.create_connection(("127.0.0.1", port), timeout=5) as conn:
                    conn.sendall(b"\x05\x01\x00")
                    assert read_exact(conn, 2) == b"\x05\xff", "Anonymous access!"
                conn, status = authenticate(port, b"wrong-password")
                conn.close()
                assert status != 0, "Wrong password accepted"
                with socket.socket() as echo:
                    echo.bind(("127.0.0.1", 0))
                    echo.listen()
                    echo.settimeout(5)
                    worker = threading.Thread(target=tcp_echo, args=(echo,), daemon=True)
                    worker.start()
                    conn, status = authenticate(port)
                    with conn:
                        assert status == 0
                        request(conn, 1, echo.getsockname()[1])
                        conn.sendall(b"Independent TCP")
                        assert read_exact(conn, 15) == b"Independent TCP"
                    worker.join(5)
                with contextlib.ExitStack() as stack:
                    echo = stack.enter_context(socket.socket(type=socket.SOCK_DGRAM))
                    echo.bind(("127.0.0.1", 0))
                    echo.settimeout(5)
                    def echo_loop():
                        try:
                            for _ in range(40):
                                data, addr = echo.recvfrom(4096)
                                echo.sendto(data, addr)
                        except OSError:
                            pass
                    worker = threading.Thread(target=echo_loop, daemon=True)
                    worker.start()
                    clients = []
                    # Hold four associations simultaneously on ONE relay port.
                    for _ in range(4):
                        udp = stack.enter_context(socket.socket(type=socket.SOCK_DGRAM))
                        udp.bind(("127.0.0.1", 0))
                        udp.settimeout(5)
                        conn, status = authenticate(port)
                        stack.enter_context(conn)
                        assert status == 0
                        # NAT clients often cannot predict the translated UDP
                        # source port and request an initially unknown port (0).
                        relay = request(conn, 3, udp.getsockname()[1] if public_ip == "127.0.0.1" else 0)
                        assert relay == (public_ip, port), relay
                        clients.append(udp)
                    time.sleep(0.2)
                    for turn in range(10):
                        if turn == 5 and main_process:
                            old_main_pid = main_process.pid
                            socks_pid = process.pid
                            main_process.terminate()
                            main_process.wait(5)
                            main_process = subprocess.Popen([main_binary, "run", "-c", main_config])
                            assert main_process.pid != old_main_pid
                            assert process.pid == socks_pid and process.poll() is None
                        packets = []
                        for index, udp in enumerate(clients):
                            payload = f"client-{index}-turn-{turn}".encode()
                            packet = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", echo.getsockname()[1]) + payload
                            packets.append(packet)
                            # Simulate NAT mapping to the local relay while checking
                            # the advertised (non-local) public IP in ASSOCIATE.
                            udp.sendto(packet, ("127.0.0.1", port))
                        for udp, packet in zip(clients, packets):
                            result, addr = udp.recvfrom(4096)
                            assert addr[1] == port and result == packet, (result, packet)
                    worker.join(5)
                print(f"Independent SOCKS passed: auth/TCP/40 UDP packets/4 concurrent clients/public IP {public_ip}")
            except BaseException:
                log.seek(0)
                print(log.read().decode(errors="replace"), file=sys.stderr)
                raise
            finally:
                if main_process:
                    main_process.terminate()
                    main_process.wait(5)
                process.terminate()
                try:
                    process.wait(5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    binary = str(Path(sys.argv[1]).resolve())
    exercise(binary, "127.0.0.1")
    exercise(binary, "192.0.2.123", str(Path(sys.argv[2]).resolve()))
