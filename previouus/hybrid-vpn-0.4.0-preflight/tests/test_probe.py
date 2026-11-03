"""Local loopback tests of the shipped remote helper. Python 3.10+; no dependencies."""
import ast
import json
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProbeTests(unittest.TestCase):
    def test_token_echo_and_stop(self):
        text = (ROOT / 'Preflight.ps1').read_text(encoding='utf-8')
        script = text.split("$remoteTemplate = @'\n", 1)[1].split("\n'@", 1)[0]
        token = secrets.token_hex(16)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        script = script.replace('__TOKEN__', repr(token)).replace('__PORT__', str(port))
        tree = ast.parse(script)
        # Inventory commands are not needed for a transport unit test.
        for node in tree.body:
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'commands' for t in node.targets):
                node.value = ast.Dict(keys=[], values=[])
        script = ast.unparse(ast.fix_missing_locations(tree))
        process = subprocess.Popen([sys.executable, '-u', '-c', script], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        try:
            self.assertTrue(json.loads(process.stdout.readline())['ready'])
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                udp.settimeout(0.3)
                udp.connect(('127.0.0.1', port))
                udp.send(b'incorrect-token:0')
                with self.assertRaises(socket.timeout):
                    udp.recv(128)
                payload = (token + ':0').encode()
                udp.send(payload)
                self.assertEqual(udp.recv(128), payload)
                stop = (token + ':STOP').encode()
                udp.send(stop)
                self.assertEqual(udp.recv(128), stop)
            output, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, error)
            report = json.loads(output)
            self.assertEqual(report['probe_packets'], 2)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == '__main__':
    unittest.main()
