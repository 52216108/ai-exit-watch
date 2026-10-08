"""仅供测试：用独立 Mihomo 和回环服务器验证断线后不发生直连。"""
import copy
import http.server
import json
import select
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def read_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("连接已关闭")
        data += chunk
    return data


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    blocked = False
    connections = 0


class Socks(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(4)
        try:
            if self.server.blocked:
                return
            self.server.connections += 1
            greeting = read_exact(self.request, 2)
            read_exact(self.request, greeting[1])
            self.request.sendall(b"\x05\x00")
            header = read_exact(self.request, 4)
            if header[3] == 1:
                host = socket.inet_ntoa(read_exact(self.request, 4))
            elif header[3] == 3:
                host = read_exact(self.request, read_exact(self.request, 1)[0]).decode()
            else:
                return
            port = int.from_bytes(read_exact(self.request, 2), "big")
            if host not in ("127.0.0.1", "claude.ai", "control.example.com"):
                raise ValueError("测试仅允许访问回环服务")
            with socket.create_connection(("127.0.0.1", port), timeout=4) as upstream:
                self.request.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                while True:
                    ready, _, _ = select.select([self.request, upstream], [], [], 4)
                    if not ready:
                        break
                    for current in ready:
                        data = current.recv(65536)
                        if not data:
                            return
                        (upstream if current is self.request else self.request).sendall(data)
        except (OSError, ConnectionError):
            pass


class HTTP(http.server.BaseHTTPRequestHandler):
    hits = 0

    def do_GET(self):
        HTTP.hits += 1
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_):
        pass


class UDP(socketserver.BaseRequestHandler):
    hits = 0

    def handle(self):
        UDP.hits += 1
        data, sock = self.request
        sock.sendto(data, self.client_address)


def start(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    binary, fixture = sys.argv[1:]
    variants = json.loads(Path(fixture).read_text())
    target = start(Server(("127.0.0.1", 0), HTTP))
    landing = start(Server(("127.0.0.1", 0), Socks))
    front = start(Server(("127.0.0.1", 0), Socks))
    udp_target = start(socketserver.ThreadingUDPServer(("127.0.0.1", 0), UDP))
    try:
        with tempfile.TemporaryDirectory(prefix="ai-exit-lock-mihomo-test-") as temporary:
            for index, base in enumerate(variants):
                with socket.socket() as reservation:
                    reservation.bind(("127.0.0.1", 0))
                    proxy_port = reservation.getsockname()[1]
                config = copy.deepcopy(base)
                config.update({"mixed-port": proxy_port, "bind-address": "127.0.0.1", "allow-lan": False,
                               "mode": "rule", "log-level": "silent", "tun": {"enable": False},
                               "dns": {"enable": False}, "hosts": {"claude.ai": "127.0.0.1", "control.example.com": "127.0.0.1"}})
                for node in config["proxies"]:
                    node["server"] = "127.0.0.1"
                    node["port"] = landing.server_address[1] if node["name"] == "落地" else front.server_address[1]
                directory = Path(temporary) / str(index)
                directory.mkdir()
                path = directory / "config.json"
                path.write_text(json.dumps(config))
                process = subprocess.Popen([binary, "-d", str(directory), "-f", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                try:
                    for _ in range(100):
                        if process.poll() is not None:
                            raise AssertionError(process.stderr.read().decode())
                        try:
                            with socket.create_connection(("127.0.0.1", proxy_port), timeout=0.1):
                                break
                        except OSError:
                            time.sleep(0.05)
                    else:
                        raise AssertionError("独立 Mihomo 未就绪")

                    def request(host):
                        return subprocess.run(["/usr/bin/curl", "--silent", "--fail", "--noproxy", "", "--max-time", "3",
                                               "--proxy", f"http://127.0.0.1:{proxy_port}",
                                               f"http://{host}:{target.server_address[1]}/test"], capture_output=True)

                    def udp_request(host):
                        with socket.create_connection(("127.0.0.1", proxy_port), timeout=2) as control:
                            control.sendall(b"\x05\x01\x00")
                            assert read_exact(control, 2) == b"\x05\x00"
                            control.sendall(b"\x05\x03\x00\x01" + b"\x00" * 6)
                            response = read_exact(control, 4)
                            assert response[1] == 0 and response[3] == 1
                            read_exact(control, 4)
                            port = int.from_bytes(read_exact(control, 2), "big")
                            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                                udp.bind(("127.0.0.1", 0)); udp.settimeout(0.7)
                                domain = host.encode()
                                packet = b"\x00\x00\x00\x03" + bytes([len(domain)]) + domain
                                packet += udp_target.server_address[1].to_bytes(2, "big") + b"lock-test"
                                udp.sendto(packet, ("127.0.0.1", port))
                                try:
                                    return udp.recvfrom(2048)[0].endswith(b"lock-test")
                                except socket.timeout:
                                    return False

                    landing.blocked = False
                    before = HTTP.hits
                    result = request("claude.ai")
                    if index != 1:
                        assert result.returncode == 0 and result.stdout == b"ok"
                        assert front.connections > 0 and landing.connections > 0, "未走前置与落地两跳"
                        landing.blocked = True
                        before = HTTP.hits
                        assert request("claude.ai").returncode != 0, "故障时不应连通"
                    else:
                        assert result.returncode != 0, "链路缺失时应拒绝"
                    assert HTTP.hits == before, "受保护连接偷偷走了直连"
                    assert request("control.example.com").returncode == 0, "非保护域名应保留原路由"
                    before_udp = UDP.hits
                    if index == 2:
                        assert udp_request("claude.ai") and UDP.hits == before_udp + 1, "对照应复现无拒绝兜底时的 UDP 绕出"
                    else:
                        assert not udp_request("claude.ai") and UDP.hits == before_udp, "保护域名 UDP 不应绕出"
                    assert udp_request("control.example.com"), "非保护域名 UDP 保留直连"
                    print(f"独立 Mihomo 场景 {index + 1} 通过", flush=True)
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
    finally:
        for server in (target, landing, front, udp_target):
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
