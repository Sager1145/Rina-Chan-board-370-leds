import socket
import ujson as json
from config import HTTP_PORT, UDP_PORT, UDP_REPLY_PORT, MAX_HTTP_BODY, WEBUI_FILE


def _url_decode(s):
    s = s.replace('+', ' ')
    out = ''
    i = 0
    while i < len(s):
        if s[i] == '%' and i + 2 < len(s):
            try:
                out += chr(int(s[i + 1:i + 3], 16))
                i += 3
                continue
            except Exception:
                pass
        out += s[i]
        i += 1
    return out


def _parse_qs(path):
    if '?' not in path:
        return path, {}
    path, qs = path.split('?', 1)
    out = {}
    for part in qs.split('&'):
        if not part:
            continue
        if '=' in part:
            k, v = part.split('=', 1)
        else:
            k, v = part, ''
        out[_url_decode(k)] = _url_decode(v)
    return path, out


class ProtocolServer:
    def __init__(self, app):
        self.app = app
        self.http = None
        self.udp = None

    def begin(self):
        ai = socket.getaddrinfo('0.0.0.0', HTTP_PORT)[0][-1]
        self.http = socket.socket()
        self.http.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.http.bind(ai)
        self.http.listen(2)
        self.http.setblocking(False)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.udp.bind(('0.0.0.0', UDP_PORT))
        self.udp.setblocking(False)
        print('HTTP listening on', HTTP_PORT, 'UDP', UDP_PORT)

    def poll(self):
        self._poll_udp()
        self._poll_http()

    def _poll_udp(self):
        if self.udp is None:
            return
        try:
            data, addr = self.udp.recvfrom(4096)
        except OSError:
            return
        try:
            # Prefer text protocol if payload looks textual.
            if data and all((32 <= b <= 126) or b in (9, 10, 13) for b in data[:64]):
                cmd = data.decode().strip()
                reply = self.app.handle_command(cmd, source='udp')
            else:
                reply = self.app.handle_legacy_udp(data)
            if reply is None:
                reply = 'ok'
            if not isinstance(reply, bytes):
                reply = str(reply).encode()
            self.udp.sendto(reply, addr)
        except Exception as e:
            try:
                self.udp.sendto(('ERR ' + str(e)).encode(), addr)
            except Exception:
                pass
            print('udp error:', e)

    def _poll_http(self):
        if self.http is None:
            return
        try:
            conn, addr = self.http.accept()
        except OSError:
            return
        try:
            conn.settimeout(1)
            req = conn.recv(1024)
            if not req:
                conn.close(); return
            head = req
            while b'\r\n\r\n' not in head and len(head) < 8192:
                more = conn.recv(1024)
                if not more:
                    break
                head += more
            header, body = (head.split(b'\r\n\r\n', 1) + [b''])[:2] if b'\r\n\r\n' in head else (head, b'')
            lines = header.decode('utf-8', 'ignore').split('\r\n')
            first = lines[0].split()
            if len(first) < 2:
                self._send(conn, 400, 'text/plain', 'bad request')
                return
            method, path = first[0], first[1]
            headers = {}
            for line in lines[1:]:
                if ':' in line:
                    k, v = line.split(':', 1)
                    headers[k.lower()] = v.strip()
            clen = int(headers.get('content-length', '0') or '0')
            if clen > MAX_HTTP_BODY:
                self._send(conn, 413, 'text/plain', 'body too large')
                return
            while len(body) < clen:
                more = conn.recv(min(1024, clen - len(body)))
                if not more:
                    break
                body += more
            path, qs = _parse_qs(path)
            self._route(conn, method, path, qs, body)
        except Exception as e:
            try:
                self._send(conn, 500, 'text/plain', 'ERR ' + str(e))
            except Exception:
                pass
            print('http error:', e)
        try:
            conn.close()
        except Exception:
            pass

    def _route(self, conn, method, path, qs, body):
        if path == '/':
            self._send_file(conn, WEBUI_FILE, 'text/html; charset=utf-8')
        elif path == '/api/state':
            self._send_json(conn, self.app.state_json())
        elif path == '/api/faces':
            self._send(conn, 200, 'application/json; charset=utf-8', self.app.faces.to_json())
        elif path == '/api/battery':
            self._send_json(conn, self.app.battery.snapshot())
        elif path == '/api/scan':
            self._send_json(conn, self.app.network.scan() if self.app.network else [])
        elif path == '/api/cmd':
            cmd = qs.get('c') or body.decode('utf-8', 'ignore')
            reply = self.app.handle_command(cmd, source='http')
            ctype = 'application/json; charset=utf-8' if isinstance(reply, str) and reply[:1] in ('{', '[') else 'text/plain; charset=utf-8'
            self._send(conn, 200, ctype, reply if reply is not None else 'ok')
        else:
            self._send(conn, 404, 'text/plain', 'not found')

    def _send_json(self, conn, obj):
        self._send(conn, 200, 'application/json; charset=utf-8', json.dumps(obj))

    def _send_file(self, conn, path, content_type):
        try:
            conn.send(('HTTP/1.1 200 OK\r\nContent-Type: %s\r\nConnection: close\r\n\r\n' % content_type).encode())
            with open(path, 'rb') as f:
                while True:
                    chunk = f.read(1024)
                    if not chunk:
                        break
                    conn.send(chunk)
        except Exception as e:
            self._send(conn, 500, 'text/plain', 'file error ' + str(e))

    def _send(self, conn, status, content_type, body):
        if body is None:
            body = ''
        if isinstance(body, str):
            body = body.encode('utf-8')
        reason = {200: 'OK', 400: 'Bad Request', 404: 'Not Found', 413: 'Payload Too Large', 500: 'Internal Server Error'}.get(status, 'OK')
        header = 'HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n' % (status, reason, content_type, len(body))
        conn.send(header.encode() + body)
