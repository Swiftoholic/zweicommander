"""Optional loopback SSH fixture: Paramiko transports the real system SFTP server.

Requires Paramiko in a separate test environment. Uses only a supplied synthetic
public key, generates an ephemeral host key, and never changes SSH configuration.
"""
import argparse
import base64
import os
from pathlib import Path
import socketserver
import subprocess
import threading
import time

import paramiko

parser = argparse.ArgumentParser()
parser.add_argument('root', type=Path)
parser.add_argument('public_key', type=Path)
args = parser.parse_args()
ROOT = args.root.resolve()
kind, encoded = args.public_key.read_text().split()[:2]
CLIENT = paramiko.PKey.from_type_string(kind, base64.b64decode(encoded))
HOST = paramiko.RSAKey.generate(2048)
AUTH_LOCK = threading.Lock()


class Authentication(paramiko.ServerInterface):
    def __init__(self):
        self.subsystem = threading.Event()

    def get_allowed_auths(self, username):
        return 'publickey'

    def check_auth_publickey(self, username, key):
        accepted = username == 'fixture' and key == CLIENT
        with AUTH_LOCK:
            with (ROOT / '.auth-events').open('a') as log:
                log.write('accepted\n' if accepted else 'rejected\n')
        return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_subsystem_request(self, channel, name):
        if name == 'sftp':
            self.subsystem.set()
            return True
        return False


class SSH(socketserver.BaseRequestHandler):
    def handle(self):
        transport = paramiko.Transport(self.request)
        transport.handshake_timeout = 10
        transport.auth_timeout = 10
        transport.add_server_key(HOST)
        server, process, channel = Authentication(), None, None
        try:
            transport.start_server(server=server)
            channel = transport.accept(10)
            if channel is None or not server.subsystem.wait(10):
                return
            process = subprocess.Popen(['/usr/libexec/sftp-server', '-d', str(ROOT)],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL)

            def incoming():
                try:
                    while True:
                        data = channel.recv(32768)
                        if not data:
                            break
                        process.stdin.write(data)
                        process.stdin.flush()
                except (OSError, EOFError):
                    pass
                finally:
                    process.stdin.close()

            def outgoing():
                try:
                    while True:
                        data = os.read(process.stdout.fileno(), 32768)
                        if not data:
                            break
                        channel.sendall(data)
                except (OSError, EOFError):
                    pass
                finally:
                    channel.shutdown_write()

            threads = [threading.Thread(target=fn, daemon=True) for fn in (incoming, outgoing)]
            for thread in threads:
                thread.start()
            while process.poll() is None and transport.is_active():
                time.sleep(.02)
        except (paramiko.SSHException, OSError, EOFError):
            pass
        finally:
            if channel is not None:
                channel.close()
            transport.close()
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(('127.0.0.1', 0), SSH) as server:
    port = server.server_address[1]
    line = '[127.0.0.1]:%d %s %s\n'
    (ROOT / 'known_hosts').write_text(line % (port, HOST.get_name(), HOST.get_base64()))
    wrong = paramiko.RSAKey.generate(2048)
    (ROOT / 'wrong_hosts').write_text(line % (port, wrong.get_name(), wrong.get_base64()))
    (ROOT / 'port.txt').write_text(str(port))
    server.serve_forever(poll_interval=.1)
