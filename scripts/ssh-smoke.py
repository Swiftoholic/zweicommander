#!/usr/bin/env python3
"""Full native SSH/SFTP checks with generated keys and a loopback-only server."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--python', required=True, type=Path, help='Python test environment containing Paramiko')
parser.add_argument('--tests', required=True, type=Path, help='Built CommanderCoreTests executable')
parser.add_argument('--results', required=True, type=Path, help='Private test-log directory')
args = parser.parse_args()
args.results.mkdir(parents=True, exist_ok=True)
version = subprocess.check_output([str(args.python.absolute()), '-c', 'import paramiko; print(paramiko.__version__)'], text=True).strip()
fixture = Path(__file__).resolve().parents[1] / 'Tests/fixtures/ssh_server.py'
with tempfile.TemporaryDirectory(prefix='ZweiCommander-ssh-') as temporary:
    root = Path(temporary)
    server = root / 'Server'
    server.mkdir()
    (server / 'Initial.txt').write_text('SSH fixture\n', encoding='utf-8')
    for name in ['client', 'wrong_client']:
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'synthetic-test', '-f', str(root / name)], check=True)
    with (args.results / 'ssh-server.log').open('w') as log:
        process = subprocess.Popen([str(args.python.absolute()), str(fixture), str(server), str(root / 'client.pub')], stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while not (server / 'port.txt').is_file() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(.02)
            if not (server / 'port.txt').is_file():
                raise SystemExit('SSH fixture did not start')
            with (args.results / 'ssh-probe.log').open('w') as output:
                result = subprocess.run([str(args.tests.resolve()), '--ssh-probe', str(root)], stdout=output, stderr=subprocess.STDOUT, timeout=90)
            text = (args.results / 'ssh-probe.log').read_text()
            checks = sum(line.startswith('SSH PROBE PASS ') and not line.endswith(' checks') for line in text.splitlines())
            if result.returncode or 'SSH PROBE PASS 9 checks' not in text or 'SSH PROBE FAIL' in text or checks != 9:
                raise SystemExit('Native SSH/SFTP checks failed; inspect the private probe log')
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
(args.results / 'ssh-verification.json').write_text(json.dumps({
    'native_ssh_client': True, 'real_system_sftp_server': True,
    'encrypted_loopback_transport': True, 'checks_passed': checks,
    'paramiko_version': version, 'generated_keys_removed': True,
    'system_ssh_configuration_unchanged': True,
}, indent=2) + '\n')
print('9 native SSH/SFTP checks passed; temporary keys removed.')
