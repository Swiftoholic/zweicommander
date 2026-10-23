"""Loopback-only FTP fixture for integration tests; never used by the application."""
import argparse
import datetime
import os
import ssl
import time
import threading
from pathlib import Path
import socket
import socketserver
import sys

parser = argparse.ArgumentParser()
parser.add_argument('root', type=Path)
parser.add_argument('--cert', type=Path)
parser.add_argument('--key', type=Path)
parser.add_argument('--delay', type=float, default=0)
parser.add_argument('--password')
args = parser.parse_args()
ROOT = args.root.resolve()
LOGIN_LOCK = threading.Lock()
TLS = None
if args.cert:
    TLS = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    TLS.load_cert_chain(str(args.cert), str(args.key))


class FTP(socketserver.StreamRequestHandler):
    def handle(self):
        self.cwd = ROOT
        self.passive = None
        self.data_tls = False
        self.rename_from = None
        self.reply('220 ZweiCommander test fixture')
        try:
            while True:
                raw = self.rfile.readline()
                if not raw:
                    break
                parts = raw.decode('utf-8').rstrip('\r\n').split(' ', 1)
                cmd, arg = parts[0].upper(), parts[1] if len(parts) > 1 else ''
                if cmd == 'AUTH' and TLS:
                    self.reply('234 Start TLS')
                    self.connection = TLS.wrap_socket(self.connection, server_side=True)
                    self.rfile = self.connection.makefile('rb')
                    self.wfile = self.connection.makefile('wb')
                elif cmd == 'PBSZ' and TLS:
                    self.reply('200 Buffer accepted')
                elif cmd == 'PROT' and TLS:
                    self.data_tls = arg == 'P'
                    self.reply('200 Protection accepted')
                elif cmd == 'USER':
                    self.reply('331 Password required')
                elif cmd == 'PASS':
                    counter = ROOT / '.login-count'
                    with LOGIN_LOCK:
                        counter.write_text(str(int(counter.read_text()) + 1 if counter.exists() else 1))
                    if args.password is not None and arg != args.password:
                        self.reply('530 Login denied')
                    else:
                        (ROOT / '.login-used').touch()
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
                elif cmd == 'RNFR':
                    p = self.path(arg)
                    if p.exists():
                        self.rename_from = p
                        self.reply('350 Destination required')
                    else:
                        self.reply('550 Not found')
                elif cmd == 'RNTO':
                    p = self.path(arg)
                    if self.rename_from is None or p.exists():
                        self.reply('550 Rename rejected')
                    else:
                        self.rename_from.rename(p)
                        self.rename_from = None
                        self.reply('250 Renamed')
                elif cmd in ('DELE', 'RMD'):
                    p = self.path(arg)
                    try:
                        p.rmdir() if cmd == 'RMD' else p.unlink()
                        self.reply('250 Removed')
                    except OSError:
                        self.reply('550 Remove rejected')
                elif cmd == 'MKD':
                    p = self.path(arg)
                    try:
                        p.mkdir()
                        self.reply('257 Directory created')
                    except FileExistsError:
                        self.reply('550 Already exists')
                elif cmd in ('MLSD', 'LIST', 'RETR', 'STOR'):
                    self.reply('150 Opening data connection')
                    data, _ = self.passive.accept()
                    data.settimeout(10)
                    if self.data_tls:
                        data = TLS.wrap_socket(data, server_side=True)
                        (ROOT / '.data-tls-used').touch()
                    with data:
                        if cmd in ('MLSD', 'LIST'):
                            rows = []
                            for p in sorted(self.cwd.iterdir()):
                                if cmd == 'MLSD':
                                    kind = 'OS.unix=slink' if p.is_symlink() else 'dir' if p.is_dir() else 'file'
                                    modified = datetime.datetime.fromtimestamp(p.lstat().st_mtime, datetime.timezone.utc).strftime('%Y%m%d%H%M%S.%f')
                                    rows.append('type=%s;size=%d;modify=%s; %s\r\n' % (kind, p.lstat().st_size, modified, p.name))
                                else:
                                    rows.append('%srw-r--r-- 1 user group %d Oct 17 12:00 %s\r\n' % ('d' if p.is_dir() else '-', p.stat().st_size, p.name))
                            data.sendall(''.join(rows).encode('utf-8'))
                        elif cmd == 'RETR':
                            with self.path(arg).open('rb') as source:
                                while True:
                                    chunk = source.read(32768)
                                    if not chunk:
                                        break
                                    data.sendall(chunk)
                                    if args.delay:
                                        time.sleep(args.delay)
                        else:
                            with self.path(arg).open('xb') as output:
                                while True:
                                    chunk = data.recv(65536)
                                    if not chunk:
                                        break
                                    output.write(chunk)
                                    if args.delay:
                                        time.sleep(args.delay)
                        if self.data_tls:
                            try:
                                data.unwrap()
                            except (ssl.SSLError, OSError):
                                pass
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
