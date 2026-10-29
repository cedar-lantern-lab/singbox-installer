"""Isolated regression checks; never installs software or writes /root/sbox."""
import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).with_name('reality_hy2_ws.sh').read_text()


class InstallerChecks(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        # Extract only the helpers; do not run main, install dependencies, or use systemd.
        helpers = SOURCE[SOURCE.index('stop_cloudflared(){'):SOURCE.index('# client configuration')]
        self.helpers = 'set -o pipefail\nfail() { echo "$*" >&2; exit 1; }\n' + helpers.replace('/root/sbox', str(self.root))

    def run_bash(self, body):
        return subprocess.run(['bash'], input=self.helpers + '\n' + body,
                              text=True, capture_output=True, timeout=15)

    def test_single_url_is_saved_and_log_is_retained(self):
        cloudflared = self.root / 'cloudflared-linux'
        cloudflared.write_text('#!/bin/bash\necho "Requesting a Quick Tunnel on trycloudflare.com" >&2\n'
                               'echo "https://sample-domain.trycloudflare.com" >&2\n'
                               'echo "INF Registered tunnel connection" >&2\nexec /bin/sleep 10\n')
        cloudflared.chmod(0o700)
        # Cleanup always runs in this shell, including when start_quick_tunnel fails.
        result = self.run_bash('trap stop_cloudflared EXIT\nstart_quick_tunnel 15555')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(base64.b64decode((self.root / 'argo.txt.b64').read_bytes()).decode().strip(),
                         'sample-domain.trycloudflare.com')
        self.assertIn('Registered tunnel connection', (self.root / 'cloudflared.log').read_text())

    def test_failed_tunnel_does_not_reuse_stale_hostname(self):
        (self.root / 'argo.txt.b64').write_text(base64.b64encode(b'stale.trycloudflare.com').decode())
        cloudflared = self.root / 'cloudflared-linux'
        cloudflared.write_text('#!/bin/bash\necho "connection failure" >&2\nexit 17\n')
        cloudflared.chmod(0o700)
        result = self.run_bash('start_quick_tunnel 15555')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'argo.txt.b64').exists())
        self.assertIn('connection failure', (self.root / 'cloudflared.log').read_text())

    def test_download_failure_preserves_installed_binary(self):
        old_binary = self.root / 'sing-box'
        old_binary.write_bytes(b'previous working binary')
        result = self.run_bash('curl() { return 22; }\nSING_BOX_VERSION=1.14.4\ndownload_singbox')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(old_binary.read_bytes(), b'previous working binary')

    def test_config_generation_uses_route_action(self):
        start = SOURCE.index('jq -n --arg listen_port')
        end = SOURCE.index('# Create sing-box.service', start)
        generation = SOURCE[start:end].replace('/root/sbox/sbconfig_server.json', str(self.root / 'server.json'))
        body = '''listen_port=443; vmess_port=15555; hy_listen_port=8443
vmess_uuid=11111111-1111-4111-8111-111111111111
uuid=22222222-2222-4222-8222-222222222222
ws_path=/sample; server_name=example.com; private_key=fixture
short_id=0011223344556677; hy_password=fixture; server_ip=192.0.2.1
'''
        result = self.run_bash(body + generation)
        self.assertEqual(result.returncode, 0, result.stderr)
        import json
        config = json.loads((self.root / 'server.json').read_text())
        rule = config['route']['rules'][1]
        self.assertEqual(rule['action'], 'route')
        self.assertEqual(rule['outbound'], 'direct')


if __name__ == '__main__':
    unittest.main(verbosity=2)
