"""Loopback-only FTP fixture for integration tests; never used by the application."""
import os
from pathlib import Path
import socket
import socketserver
import sys

ROOT = Path(sys.argv[1]).resolve()


class FTP(socketserver.StreamRequestHandler):
    def handle(self):
        self.cwd = ROOT
        self.passive = None
        self.reply('220 ZweiCommander test fixture')
        try:
            while True:
                raw = self.rfile.readline()
                if not raw:
                    break
                parts = raw.decode('utf-8').rstrip('\r\n').split(' ', 1)
                cmd, arg = parts[0].upper(), parts[1] if len(parts) > 1 else ''
                if cmd == 'USER':
                    self.reply('331 Password required')
                elif cmd == 'PASS':
                    self.reply('230 Logged in')
                elif cmd == 'PWD':
                    self.reply('257 "/%s"' % str(self.cwd.relative_to(ROOT)).replace('.', ''))
                elif cmd == 'SYST':
                    self.reply('215 UNIX Type: L8')
                elif cmd in ('TYPE', 'OPTS', 'NOOP'):
                    self.reply('200 OK')
                elif cmd == 'CWD':
                    p = self.path(arg)
                    if p.is_dir():
                        self.cwd = p
                        self.reply('250 Changed directory')
                    else:
                        self.reply('550 Not found')
                elif cmd in ('EPSV', 'PASV'):
                    if self.passive:
                        self.passive.close()
                    self.passive = socket.socket()
                    self.passive.bind(('127.0.0.1', 0))
                    self.passive.listen(1)
                    self.passive.settimeout(10)
                    port = self.passive.getsockname()[1]
                    self.reply('229 Entering Extended Passive Mode (|||%d|)' % port if cmd == 'EPSV' else '227 Entering Passive Mode (127,0,0,1,%d,%d)' % (port // 256, port % 256))
                elif cmd in ('MLSD', 'LIST', 'RETR', 'STOR'):
                    self.reply('150 Opening data connection')
                    data, _ = self.passive.accept()
                    with data:
                        if cmd in ('MLSD', 'LIST'):
                            rows = []
                            for p in sorted(self.cwd.iterdir()):
                                if cmd == 'MLSD':
                                    rows.append('type=%s;size=%d;modify=20261017000000; %s\r\n' % ('dir' if p.is_dir() else 'file', p.stat().st_size, p.name))
                                else:
                                    rows.append('%srw-r--r-- 1 user group %d Oct 17 12:00 %s\r\n' % ('d' if p.is_dir() else '-', p.stat().st_size, p.name))
                            data.sendall(''.join(rows).encode('utf-8'))
                        elif cmd == 'RETR':
                            data.sendall(self.path(arg).read_bytes())
                        else:
                            with self.path(arg).open('xb') as output:
                                while True:
                                    chunk = data.recv(65536)
                                    if not chunk:
                                        break
                                    output.write(chunk)
                    self.passive.close()
                    self.passive = None
                    self.reply('226 Transfer complete')
                elif cmd == 'SIZE':
                    p = self.path(arg)
                    self.reply('213 %d' % p.stat().st_size if p.is_file() else '550 Not found')
                elif cmd == 'QUIT':
                    self.reply('221 Goodbye')
                    break
                else:
                    self.reply('502 Not implemented')
        except (BrokenPipeError, ConnectionError):
            pass
        finally:
            if self.passive:
                self.passive.close()

    def path(self, name):
        path = (ROOT / name.lstrip('/') if name.startswith('/') else self.cwd / name).resolve()
        if path != ROOT and ROOT not in path.parents:
            raise ValueError('Path outside fixture')
        return path

    def reply(self, text):
        self.wfile.write((text + '\r\n').encode('utf-8'))
        self.wfile.flush()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(('127.0.0.1', 0), FTP) as server:
    (ROOT / 'port.txt').write_text(str(server.server_address[1]))
    server.serve_forever(poll_interval=0.1)
