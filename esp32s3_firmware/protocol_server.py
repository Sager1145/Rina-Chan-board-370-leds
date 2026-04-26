import socket
import ujson as json
import time
import config
import logger as log
try:
    import machine
except Exception:
    machine = None
try:
    import gc
except Exception:
    gc = None

HTTP_PORT = getattr(config, 'HTTP_PORT', 80)
UDP_PORT = getattr(config, 'UDP_PORT', 1234)
DNS_PORT = getattr(config, 'DNS_PORT', 53)
ENABLE_CAPTIVE_DNS = getattr(config, 'ENABLE_CAPTIVE_DNS', True)
MAX_HTTP_BODY = getattr(config, 'MAX_HTTP_BODY', 32768)
WEBUI_FILE = getattr(config, 'WEBUI_FILE', 'webui/index.html')
LOG_PROTOCOL_VERBOSE = getattr(config, 'LOG_PROTOCOL_VERBOSE', False)
AP_IP = getattr(config, 'AP_IP', '192.168.4.1')
HTTP_CLIENT_TIMEOUT_MS = getattr(config, 'HTTP_CLIENT_TIMEOUT_MS', 120)
HTTP_SEND_CHUNK_BYTES = getattr(config, 'HTTP_SEND_CHUNK_BYTES', 768)
UDP_PACKETS_PER_POLL = getattr(config, 'UDP_PACKETS_PER_POLL', 4)
DNS_PACKETS_PER_POLL = getattr(config, 'DNS_PACKETS_PER_POLL', 4)


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


def _parse_form(body):
    text = _decode_http_text(body)
    _, form = _parse_qs('?' + text)
    return form


def _decode_http_text(data):
    try:
        return data.decode('utf-8')
    except Exception:
        out = ''
        for b in data:
            if b in (9, 10, 13) or 32 <= b <= 126:
                out += chr(b)
        return out


def _looks_like_http(req):
    return (
        req.startswith(b'GET ') or
        req.startswith(b'POST ') or
        req.startswith(b'HEAD ') or
        req.startswith(b'OPTIONS ')
    )


def _hex_to_bytes(hex_text):
    vals = []
    for c in str(hex_text or ''):
        if c in '0123456789abcdefABCDEF':
            vals.append(c)
    if len(vals) % 2:
        vals.append('0')
    out = bytearray(len(vals) // 2)
    for i in range(0, len(vals), 2):
        out[i // 2] = int(vals[i] + vals[i + 1], 16)
    return bytes(out)


def _bytes_to_hex(data):
    out = ''
    for b in data:
        out += '%02X' % b
    return out


def _json_escape(value):
    s = str(value or '')
    s = s.replace('\\', '\\\\').replace('"', '\\"')
    s = s.replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
    return s


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
            try:
                req = conn.recv(1024)
            except OSError:
                return
            if not req:
                conn.close()
                return
            if not _looks_like_http(req):
                if LOG_PROTOCOL_VERBOSE:
                    log.debug('HTTP', 'non-http probe dropped', first=req[:8])
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
            lines = _decode_http_text(header).split('\r\n')
            first = lines[0].split()
            if len(first) < 2:
                self._send(conn, 400, 'text/plain', 'bad request')
                return
            method, path = first[0], first[1]
            if method not in ('GET', 'POST', 'HEAD', 'OPTIONS'):
                self._send(conn, 405, 'text/plain', 'method not allowed')
                return
            if LOG_PROTOCOL_VERBOSE:
                log.info('HTTP', 'request line', method=method, path=path)
            headers = {}
            for line in lines[1:]:
                if ':' in line:
                    k, v = line.split(':', 1)
                    headers[k.lower()] = v.strip()
            try:
                clen = int(headers.get('content-length', '0') or '0')
            except Exception:
                self._send(conn, 400, 'text/plain', 'bad content-length')
                return
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
            log.warn('HTTP', 'request dropped', err=e)
        finally:
            try:
                conn.close()
            except Exception:
                pass
            if gc is not None:
                try:
                    gc.collect()
                except Exception:
                    pass

    def _route(self, conn, method, path, qs, body):
        if LOG_PROTOCOL_VERBOSE:
            log.debug('HTTP', 'route', method=method, path=path, body_len=len(body))
        if method == 'OPTIONS':
            self._send(conn, 204, 'text/plain', '')
            return
        captive_paths = ('/generate_204', '/gen_204', '/hotspot-detect.html', '/library/test/success.html', '/connecttest.txt', '/ncsi.txt', '/fwlink', '/wifi', '/0wifi')
        if path == '/' or path in captive_paths:
            if path in captive_paths:
                log.info('HTTP', 'captive probe', path=path)
            self._send_webui(conn)
        elif path == '/i':
            self._send(conn, 200, 'text/plain; charset=utf-8', 'RinaChanBoard ESP32-S3\n' + json.dumps(self._status_obj()))
        elif path == '/r':
            self._send(conn, 200, 'text/plain; charset=utf-8', 'Restarting...')
            if machine is not None:
                try:
                    machine.reset()
                except Exception:
                    pass
        elif path == '/api/status':
            self._send_json(conn, self._status_obj())
        elif path == '/api/request':
            cmd = qs.get('cmd') or _parse_form(body).get('cmd', '')
            if not cmd:
                self._send(conn, 400, 'text/plain; charset=utf-8', 'missing cmd')
            else:
                self._send_command_reply(conn, cmd)
        elif path == '/api/send':
            form = _parse_form(body)
            cmd = form.get('msg') or form.get('plain') or qs.get('msg') or qs.get('plain') or ''
            wait = (form.get('wait') or qs.get('wait') or '0') == '1'
            if not cmd:
                self._send(conn, 400, 'text/plain; charset=utf-8', 'missing msg')
            elif wait:
                self._send_command_reply(conn, cmd)
            else:
                self.app.handle_command(cmd, source='http')
                self._send(conn, 200, 'text/plain; charset=utf-8', 'OK')
        elif path == '/api/binary':
            self._handle_binary(conn, qs)
        elif path == '/api/flyakari/test':
            self._send(conn, 200, 'text/plain; charset=utf-8', 'RinaboardIsOn')
        elif path == '/api/wifi/status':
            self._send_json(conn, self._wifi_status_obj())
        elif path == '/api/wifi/scan':
            nets = self.app.network.scan() if self.app.network else []
            self._send_json(conn, {'networks': nets})
        elif path == '/api/wifi/save':
            self._handle_wifi_save(conn, body)
        elif path == '/api/state':
            self._send_json(conn, self.app.state_json())
        elif path == '/api/faces':
            self._send_file(conn, self.app.faces.path, 'application/json; charset=utf-8')
        elif path == '/api/battery':
            self._send_json(conn, self.app.battery.snapshot())
        elif path == '/api/scan':
            self._send_json(conn, self.app.network.scan() if self.app.network else [])
        elif path == '/api/cmd':
            cmd = qs.get('c') or _decode_http_text(body)
            log.info('HTTP', 'api cmd', cmd=str(cmd)[:96])
            if cmd == 'requestSavedFaces370':
                self._send_file(conn, self.app.faces.path, 'application/json; charset=utf-8')
                return
            reply = self.app.handle_command(cmd, source='http')
            ctype = 'application/json; charset=utf-8' if isinstance(reply, str) and reply[:1] in ('{', '[') else 'text/plain; charset=utf-8'
            self._send(conn, 200, ctype, reply if reply is not None else 'ok')
        else:
            if LOG_PROTOCOL_VERBOSE:
                log.debug('HTTP', 'unknown path', path=path)
            self._send(conn, 404, 'text/plain; charset=utf-8', 'not found')

    def _send_command_reply(self, conn, cmd):
        log.info('HTTP', 'legacy api cmd', cmd=str(cmd)[:96])
        if cmd == 'requestSavedFaces370':
            self._send_file(conn, self.app.faces.path, 'application/json; charset=utf-8')
            return
        reply = self.app.handle_command(cmd, source='http')
        ctype = 'application/json; charset=utf-8' if isinstance(reply, str) and reply[:1] in ('{', '[') else 'text/plain; charset=utf-8'
        self._send(conn, 200, ctype, reply if reply is not None else 'OK')

    def _status_obj(self):
        net = self.app.network.status() if self.app.network else {}
        sta = net.get('sta_status', '')
        try:
            rssi = self.app.network.sta.status('rssi') if self.app.network and self.app.network.sta else 0
        except Exception:
            rssi = 0
        return {
            'mode': net.get('mode', 'ap'),
            'sta_status': sta,
            'ip': self.app.network.ip if self.app.network else AP_IP,
            'ap_ip': self.app.network.ip if self.app.network else AP_IP,
            'ssid': self.app.network.ssid if self.app.network else '',
            'udp_port': UDP_PORT,
            'udp_rx': 0,
            'udp_tx': 0,
            'http_rx': 0,
            'rssi': rssi,
            'runtime': self.app.runtime_status_obj(),
        }

    def _wifi_status_obj(self):
        net = self.app.network.status() if self.app.network else {}
        try:
            import wifi_config
        except Exception:
            wifi_config = None
        return {
            'mode': net.get('mode', 'ap'),
            'can_configure': net.get('mode', 'ap') == 'ap',
            'sta_connected': bool(net.get('sta_connected', False)),
            'sta_ssid': self.app.network.ssid if self.app.network and net.get('mode') == 'sta' else '',
            'sta_ip': self.app.network.ip if self.app.network and net.get('mode') == 'sta' else '',
            'ap_active': bool(net.get('ap_active', False)),
            'ap_ip': self.app.network.ip if self.app.network else AP_IP,
            'rssi': 0,
            'sta_ssid_cfg': getattr(wifi_config, 'STA_SSID', '') if wifi_config else '',
            'ap_ssid_cfg': getattr(wifi_config, 'AP_SSID', getattr(config, 'AP_SSID', 'RinaChanBoard-S3')) if wifi_config else getattr(config, 'AP_SSID', 'RinaChanBoard-S3'),
            'ap_channel_cfg': getattr(wifi_config, 'AP_CHANNEL', getattr(config, 'AP_CHANNEL', 6)) if wifi_config else getattr(config, 'AP_CHANNEL', 6),
        }

    def _handle_wifi_save(self, conn, body):
        form = _parse_form(body)
        sta_ssid = form.get('ssid', '')
        sta_pass = form.get('password', '')
        ap_ssid = form.get('ap_ssid', getattr(config, 'AP_SSID', 'RinaChanBoard-S3')) or 'RinaChanBoard-S3'
        ap_pass = form.get('ap_password', getattr(config, 'AP_PASSWORD', '12345678'))
        ap_channel = form.get('ap_channel', str(getattr(config, 'AP_CHANNEL', 6))) or '6'
        try:
            ch = int(ap_channel)
        except Exception:
            ch = 6
        if ch < 1 or ch > 13:
            ch = 6
        def esc(s):
            return str(s or '').replace('\\', '\\\\').replace('"', '\\"')
        text = (
            '# Optional station Wi-Fi credentials.\n'
            'STA_SSID = "{}"\n'
            'STA_PASSWORD = "{}"\n\n'
            'AP_SSID = "{}"\n'
            'AP_PASSWORD = "{}"\n'
            'AP_COMPAT_OPEN = {}\n'
            'AP_CHANNEL = {}\n'
            'AP_HIDDEN = False\n'
            'AP_MAX_CLIENTS = 4\n'
            'AP_COUNTRY = "US"\n'
        ).format(esc(sta_ssid), esc(sta_pass), esc(ap_ssid), esc(ap_pass), 'True' if not ap_pass else 'False', ch)
        try:
            with open('wifi_config.py', 'w') as f:
                f.write(text)
            self._send_json(conn, {'ok': True, 'message': 'Wi-Fi saved; rebooting'})
            try:
                time.sleep_ms(200)
            except Exception:
                pass
            if machine is not None:
                try:
                    machine.reset()
                except Exception:
                    pass
        except Exception as e:
            self._send_json(conn, {'ok': False, 'error': str(e)}, 500)

    def _handle_binary(self, conn, qs):
        data = _hex_to_bytes(qs.get('hex', ''))
        wait = qs.get('wait', '0') == '1'
        fmt = qs.get('format', 'hex') or 'hex'
        if wait and len(data) == 2:
            code = (data[0] << 8) | data[1]
            reply = self._binary_request_reply(code)
            if reply is None:
                self._send(conn, 504, 'text/plain; charset=utf-8', 'timeout/no reply')
            elif fmt == 'text':
                self._send(conn, 200, 'text/plain; charset=utf-8', reply.decode('utf-8', 'ignore') if isinstance(reply, bytes) else str(reply))
            else:
                self._send(conn, 200, 'text/plain; charset=utf-8', _bytes_to_hex(reply if isinstance(reply, bytes) else str(reply).encode()))
            return
        reply = self.app.handle_legacy_udp(data)
        self._send(conn, 200, 'text/plain; charset=utf-8', reply if wait else 'OK')

    def _binary_request_reply(self, code):
        if code == 0x1001:
            return _hex_to_bytes(self.app.handle_command('requestFace', source='http'))
        if code == 0x1002:
            color = self.app.color
            return bytes((int(color[0]) & 0xFF, int(color[1]) & 0xFF, int(color[2]) & 0xFF))
        if code == 0x1003:
            b = int(max(0, min(255, (self.app.brightness * 255 + 50) // 100)))
            return bytes((b,))
        if code == 0x1004:
            return str(getattr(config, 'VERSION', '')).encode()
        if code == 0x1005:
            return None
        return b'Command Error!'

    def _send_json(self, conn, obj, status=200):
        self._send(conn, status, 'application/json; charset=utf-8', json.dumps(obj))

    def _send_webui(self, conn):
        self._send_file(conn, WEBUI_FILE, 'text/html; charset=utf-8')

    def _send_file(self, conn, path, content_type, content_encoding=None):
        try:
            header = 'HTTP/1.1 200 OK\r\nContent-Type: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\n' % content_type
            if content_encoding:
                header += 'Content-Encoding: %s\r\n' % content_encoding
            header += '\r\n'
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
        reason = {200: 'OK', 204: 'No Content', 400: 'Bad Request', 404: 'Not Found', 405: 'Method Not Allowed', 413: 'Payload Too Large', 500: 'Internal Server Error', 504: 'Gateway Timeout'}.get(status, 'OK')
        header = 'HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\n\r\n' % (status, reason, content_type, len(body))
        if self._send_bytes(conn, header.encode()):
            self._send_bytes(conn, body)

    def _send_bytes(self, conn, data):
        pos = 0
        chunk_size = int(HTTP_SEND_CHUNK_BYTES)
        while pos < len(data):
            self._urgent()
            end = min(len(data), pos + chunk_size)
            try:
                sent = conn.send(data[pos:end])
            except OSError as e:
                if LOG_PROTOCOL_VERBOSE:
                    log.debug('HTTP', 'client send dropped', sent=pos, total=len(data), err=e)
                return False
            if sent is None:
                sent = end - pos
            if sent <= 0:
                return False
            pos += sent
        return True
