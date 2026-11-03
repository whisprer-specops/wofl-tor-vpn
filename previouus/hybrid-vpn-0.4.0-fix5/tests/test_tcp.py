"""Actual PowerShell/.NET verifier through a local SOCKS/TLS fixture. No system trust edits."""
import argparse
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = '/tmp/hybrid-build/pwsh/pwsh'


def exact(sock, size):
    data = b''
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError()
        data += chunk
    return data


class TcpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.dir = Path(cls.temp.name)
        for name in ('trusted', 'untrusted', 'wronghost'):
            host = 'wrong.example' if name == 'wronghost' else 'check.torproject.org'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', str(cls.dir / (name + '.key')),
                            '-out', str(cls.dir / (name + '.crt')), '-days', '1',
                            '-subj', '/CN=' + host, '-addext', 'subjectAltName=DNS:' + host],
                           check=True, capture_output=True)
        # Trust wronghost too, so its rejection specifically exercises hostname validation.
        (cls.dir / 'ca.pem').write_bytes((cls.dir / 'trusted.crt').read_bytes() +
                                         (cls.dir / 'wronghost.crt').read_bytes())
        (cls.dir / 'empty').mkdir()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_case(self, mode, expected):
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(('127.0.0.1', 17880))
        listener.listen()
        listener.settimeout(15)
        errors = []
        destinations = []

        def serve():
            tls = None
            try:
                conn, _ = listener.accept()
                with conn:
                    conn.settimeout(10)
                    version, count = exact(conn, 2)
                    self.assertEqual(version, 5)
                    exact(conn, count)
                    conn.sendall(b'\x05\x00')
                    self.assertEqual(exact(conn, 4), b'\x05\x01\x00\x03')
                    host = exact(conn, exact(conn, 1)[0]).decode()
                    port = int.from_bytes(exact(conn, 2), 'big')
                    destinations.append((host, port))
                    conn.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x01\xbb')
                    cert = mode if mode in ('untrusted', 'wronghost') else 'trusted'
                    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                    context.load_cert_chain(self.dir / (cert + '.crt'), self.dir / (cert + '.key'))
                    try:
                        tls = context.wrap_socket(conn, server_side=True)
                    except (ssl.SSLError, BrokenPipeError):
                        if mode in ('untrusted', 'wronghost'):
                            return
                        raise
                    request = b''
                    while b'\r\n\r\n' not in request:
                        part = tls.recv(4096)
                        if not part:
                            if mode in ('untrusted', 'wronghost'):
                                return
                            raise EOFError('HTTP request missing')
                        request += part
                    self.assertIn(b'GET /api/ip HTTP/1.1', request)
                    body = json.dumps({'IsTor': mode != 'not-tor', 'IP': '203.0.113.5'}).encode()
                    if mode == 'chunked':
                        headers = b'Transfer-Encoding: chunked\r\n'
                        wire = ('%x\r\n' % len(body)).encode() + body + b'\r\n0\r\n\r\n'
                    elif mode == 'no-framing':
                        headers, wire = b'', body
                    else:
                        headers = ('Content-Length: %d\r\n' % len(body)).encode()
                        wire = body[:-5] if mode == 'truncated' else body
                    tls.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n' + headers + b'Connection: close\r\n\r\n' + wire)
                    # Deliberately omit TLS close_notify, reproducing the relevant failure condition.
                    os.close(tls.detach())
            except Exception as exc:
                if not (mode in ('untrusted', 'wronghost') and isinstance(exc, (ssl.SSLError, BrokenPipeError))):
                    errors.append(exc)
            finally:
                if tls is not None:
                    tls.close()
                listener.close()

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        env = dict(os.environ, SSL_CERT_FILE=str(self.dir / 'ca.pem'), SSL_CERT_DIR=str(self.dir / 'empty'))
        script = ". '" + str(ROOT / 'client/Common.ps1') + "'; . '" + str(ROOT / 'client/Verify-Tcp.ps1') + "'; try { $r=Test-HybridTcp -Attempts 1 -TimeoutSeconds 8; $r | ConvertTo-Json -Compress } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }"
        result = subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-Command', script],
                                env=env, capture_output=True, text=True, timeout=15)
        thread.join(15)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(destinations, [('check.torproject.org', 443)])
        self.assertEqual(result.returncode == 0, expected, result.stdout + result.stderr)
        if mode in ('untrusted', 'wronghost'):
            self.assertRegex(result.stderr.lower(), 'certificate|ssl connection|authentication')
        if expected:
            self.assertEqual(json.loads(result.stdout)['IP'], '203.0.113.5')

    def test_complete_without_tls_close_notify(self): self.run_case('complete', True)
    def test_chunked_without_tls_close_notify(self): self.run_case('chunked', True)
    def test_truncation_rejected(self): self.run_case('truncated', False)
    def test_not_tor_rejected(self): self.run_case('not-tor', False)
    def test_untrusted_cert_rejected(self): self.run_case('untrusted', False)
    def test_wrong_hostname_rejected(self): self.run_case('wronghost', False)
    def test_close_delimited_rejected(self): self.run_case('no-framing', False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--pwsh', default=PWSH)
    args, remaining = parser.parse_known_args()
    PWSH = args.pwsh
    unittest.main(argv=[__file__] + remaining)
