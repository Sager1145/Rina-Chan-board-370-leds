import socket
import ujson as json
from config import (
    HTTP_PORT, UDP_PORT, DNS_PORT, ENABLE_CAPTIVE_DNS, MAX_HTTP_BODY, WEBUI_FILE,
    LOG_PROTOCOL_VERBOSE, AP_IP, HTTP_CLIENT_TIMEOUT_MS, HTTP_SEND_CHUNK_BYTES,
    UDP_PACKETS_PER_POLL, DNS_PACKETS_PER_POLL,
)
import logger as log


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
        self.dns = None
        self.client_timeout_s = max(0.02, float(HTTP_CLIENT_TIMEOUT_MS) / 1000.0)

    def begin(self):
        ai = socket.getaddrinfo('0.0.0.0', HTTP_PORT)[0][-1]
        self.http = socket.socket()
        self.http.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.http.bind(ai)
        self.http.listen(4)
        self.http.setblocking(False)

        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.udp.bind(('0.0.0.0', UDP_PORT))
        self.udp.setblocking(False)

        if ENABLE_CAPTIVE_DNS:
            try:
                self.dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                self.dns.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                self.dns.bind(('0.0.0.0', DNS_PORT))
                self.dns.setblocking(False)
                log.info('DNS', 'captive DNS listening', port=DNS_PORT, ip=AP_IP)
            except Exception as e:
                self.dns = None
                log.warn('DNS', 'captive DNS bind failed', port=DNS_PORT, err=e)
        log.info('SERVER', 'listening responsive', http_port=HTTP_PORT, udp_port=UDP_PORT, dns_port=(DNS_PORT if self.dns else None), timeout_ms=HTTP_CLIENT_TIMEOUT_MS)

    def _urgent(self):
        # Physical button service is allowed during HTTP/DNS/UDP transfers so a
        # slow phone/browser cannot make buttons feel dead.
        try:
            self.app.urgent_poll()
        except Exception as e:
            log.warn('SERVER', 'urgent poll failed', err=e)

    def poll(self):
        self._poll_dns()
        self._poll_udp()
        self._poll_http()

    def _poll_dns(self):
        if self.dns is None:
            return
        for _ in range(int(DNS_PACKETS_PER_POLL)):
            try:
                data, addr = self.dns.recvfrom(512)
            except OSError:
                return
            try:
                if len(data) < 12:
                    continue
                reply = self._build_dns_reply(data)
                if reply:
                    self.dns.sendto(reply, addr)
                    if LOG_PROTOCOL_VERBOSE:
                        log.debug('DNS', 'reply captive A', addr=addr, bytes=len(reply))
            except Exception as e:
                log.warn('DNS', 'dns request failed', addr=addr, err=e)
            self._urgent()

    def _build_dns_reply(self, data):
        tid = data[0:2]
        flags = b'\x81\x80'
        qdcount = data[4:6]
        ancount = qdcount
        header = tid + flags + qdcount + ancount + b'\x00\x00\x00\x00'
        question = data[12:]
        try:
            ip_parts = bytes([int(x) & 0xFF for x in AP_IP.split('.')])
        except Exception:
            ip_parts = b'\xC0\xA8\x04\x01'
        answer = b'\xC0\x0C' + b'\x00\x01' + b'\x00\x01' + b'\x00\x00\x00\x1E' + b'\x00\x04' + ip_parts
        return header + question + answer

    def _poll_udp(self):
        if self.udp is None:
            return
        for _ in range(int(UDP_PACKETS_PER_POLL)):
            try:
                data, addr = self.udp.recvfrom(4096)
            except OSError:
                return
            try:
                is_text = bool(data and all((32 <= b <= 126) or b in (9, 10, 13) for b in data[:64]))
                if LOG_PROTOCOL_VERBOSE:
                    log.info('UDP', 'packet in', addr=addr, length=len(data), text=is_text)
                if is_text:
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
                log.exception('UDP', 'error', e)
            self._urgent()

    def _poll_http(self):
        if self.http is None:
            return
        try:
            conn, addr = self.http.accept()
        except OSError:
            return
        if LOG_PROTOCOL_VERBOSE:
            log.info('HTTP', 'client', addr=addr)
        try:
            conn.settimeout(self.client_timeout_s)
            req = conn.recv(1024)
            if not req:
                conn.close()
                return
            head = req
            while b'\r\n\r\n' not in head and len(head) < 8192:
                self._urgent()
                try:
                    more = conn.recv(1024)
                except OSError:
                    break
                if not more:
                    break
                head += more
            if b'\r\n\r\n' in head:
                header, body = head.split(b'\r\n\r\n', 1)
            else:
                header, body = head, b''
            lines = header.decode('utf-8', 'ignore').split('\r\n')
            first = lines[0].split()
            if len(first) < 2:
                self._send(conn, 400, 'text/plain', 'bad request')
                return
            method, path = first[0], first[1]
            if LOG_PROTOCOL_VERBOSE:
                log.info('HTTP', 'request line', method=method, path=path)
            headers = {}
            for line in lines[1:]:
                if ':' in line:
                    k, v = line.split(':', 1)
                    headers[k.lower()] = v.strip()
            clen = int(headers.get('content-length', '0') or '0')
            if clen > MAX_HTTP_BODY:
                log.warn('HTTP', 'body too large', content_length=clen, max_body=MAX_HTTP_BODY)
                self._send(conn, 413, 'text/plain', 'body too large')
                return
            while len(body) < clen:
                self._urgent()
                try:
                    more = conn.recv(min(1024, clen - len(body)))
                except OSError:
                    break
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
            log.exception('HTTP', 'error', e)
        try:
            conn.close()
        except Exception:
            pass

    def _route(self, conn, method, path, qs, body):
        if LOG_PROTOCOL_VERBOSE:
            log.debug('HTTP', 'route', method=method, path=path, body_len=len(body))
        captive_paths = ('/generate_204', '/gen_204', '/hotspot-detect.html', '/library/test/success.html', '/connecttest.txt', '/ncsi.txt', '/fwlink')
        if path == '/' or path in captive_paths:
            if path in captive_paths:
                log.info('HTTP', 'captive probe', path=path)
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
            log.info('HTTP', 'api cmd', cmd=str(cmd)[:96])
            reply = self.app.handle_command(cmd, source='http')
            ctype = 'application/json; charset=utf-8' if isinstance(reply, str) and reply[:1] in ('{', '[') else 'text/plain; charset=utf-8'
            self._send(conn, 200, ctype, reply if reply is not None else 'ok')
        else:
            log.info('HTTP', 'unknown path fallback to WebUI', path=path)
            self._send_file(conn, WEBUI_FILE, 'text/html; charset=utf-8')

    def _send_json(self, conn, obj):
        self._send(conn, 200, 'application/json; charset=utf-8', json.dumps(obj))

    def _send_file(self, conn, path, content_type):
        try:
            header = 'HTTP/1.1 200 OK\r\nContent-Type: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\n\r\n' % content_type
            if not self._send_bytes(conn, header.encode()):
                return
            with open(path, 'rb') as f:
                while True:
                    chunk = f.read(int(HTTP_SEND_CHUNK_BYTES))
                    if not chunk:
                        break
                    if not self._send_bytes(conn, chunk):
                        break
        except Exception as e:
            log.warn('HTTP', 'send file failed', path=path, err=e)

    def _send(self, conn, status, content_type, body):
        if body is None:
            body = ''
        if isinstance(body, str):
            body = body.encode('utf-8')
        reason = {200: 'OK', 400: 'Bad Request', 404: 'Not Found', 413: 'Payload Too Large', 500: 'Internal Server Error'}.get(status, 'OK')
        header = 'HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\n\r\n' % (status, reason, content_type, len(body))
        self._send_bytes(conn, header.encode() + body)

    def _send_bytes(self, conn, data):
        pos = 0
        chunk_size = int(HTTP_SEND_CHUNK_BYTES)
        while pos < len(data):
            self._urgent()
            end = min(len(data), pos + chunk_size)
            try:
                sent = conn.send(data[pos:end])
            except OSError as e:
                log.warn('HTTP', 'send timeout/drop', sent=pos, total=len(data), err=e)
                return False
            if sent is None:
                sent = end - pos
            if sent <= 0:
                return False
            pos += sent
        return True
