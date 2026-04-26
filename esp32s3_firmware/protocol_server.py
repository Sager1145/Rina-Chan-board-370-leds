import socket
import ujson as json
import time
import os
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
HTTP_SEND_CHUNK_BYTES = getattr(config, 'HTTP_SEND_CHUNK_BYTES', 256)
HTTP_SEND_RETRY_COUNT = getattr(config, 'HTTP_SEND_RETRY_COUNT', 24)
HTTP_SEND_RETRY_DELAY_MS = getattr(config, 'HTTP_SEND_RETRY_DELAY_MS', 8)
UDP_PACKETS_PER_POLL = getattr(config, 'UDP_PACKETS_PER_POLL', 4)
DNS_PACKETS_PER_POLL = getattr(config, 'DNS_PACKETS_PER_POLL', 4)
UDP_RECV_BYTES = getattr(config, 'UDP_RECV_BYTES', 768)
HTTP_BODY_RECV_BYTES = getattr(config, 'HTTP_BODY_RECV_BYTES', 512)
HTTP_HEADER_MAX_BYTES = getattr(config, 'HTTP_HEADER_MAX_BYTES', 4096)
CORS_HEADERS = (
    'Access-Control-Allow-Origin: *\r\n'
    'Access-Control-Allow-Methods: GET, POST, OPTIONS, HEAD\r\n'
    'Access-Control-Allow-Headers: Content-Type, Cache-Control\r\n'
)


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



def _safe_len(value):
    try:
        return len(value)
    except Exception:
        return -1


def _gc_collect(reason=None):
    if gc is not None:
        try:
            before = gc.mem_free()
        except Exception:
            before = -1
        try:
            gc.collect()
        except Exception:
            pass
        try:
            after = gc.mem_free()
        except Exception:
            after = -1
        if reason and LOG_PROTOCOL_VERBOSE:
            log.debug('GC', 'collect', reason=reason, before=before, after=after)


def _short_cmd(cmd, limit=140):
    s = str(cmd or '').replace('\r', ' ').replace('\n', ' ')
    if len(s) > limit:
        return s[:limit] + '...'
    return s

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
        log.info('SERVER', 'listening responsive', http_port=HTTP_PORT, udp_port=UDP_PORT, dns_port=(DNS_PORT if self.dns else None), timeout_ms=HTTP_CLIENT_TIMEOUT_MS, udp_recv_bytes=UDP_RECV_BYTES, http_body_recv_bytes=HTTP_BODY_RECV_BYTES)

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
                data, addr = self.dns.recvfrom(256)
            except MemoryError as e:
                log.warn('DNS', 'recv memory pressure', err=e)
                _gc_collect('dns recv')
                return
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
        # Build a minimal one-question/one-answer captive DNS A response.
        tid = data[0:2]
        flags = b'\x81\x80'
        idx = 12
        try:
            while idx < len(data) and data[idx] != 0:
                idx += int(data[idx]) + 1
            if idx + 5 > len(data):
                return None
            question = data[12:idx + 5]
        except Exception:
            return None
        header = tid + flags + b'\x00\x01' + b'\x00\x01' + b'\x00\x00\x00\x00'
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
                data, addr = self.udp.recvfrom(int(UDP_RECV_BYTES))
            except MemoryError as e:
                log.warn('UDP', 'recv memory pressure; packet skipped', err=e, recv_bytes=UDP_RECV_BYTES)
                _gc_collect('udp recv')
                return
            except OSError:
                return
            try:
                is_text = bool(data and all((32 <= b <= 126) or b in (9, 10, 13) for b in data[:64]))
                log.info('UDP', 'packet in', addr=addr, length=len(data), text=is_text)
                if is_text:
                    cmd = data.decode().strip()
                    log.info('UDP', 'command', cmd=_short_cmd(cmd))
                    reply = self.app.handle_command(cmd, source='udp')
                else:
                    reply = self.app.handle_legacy_udp(data)
                if reply is None:
                    reply = 'ok'
                if not isinstance(reply, bytes):
                    reply = str(reply).encode()
                self.udp.sendto(reply, addr)
                log.info('UDP', 'reply sent', addr=addr, bytes=len(reply))
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
                req = conn.recv(512)
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
            while b'\r\n\r\n' not in head and len(head) < int(HTTP_HEADER_MAX_BYTES):
                self._urgent()
                try:
                    more = conn.recv(512)
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
                    more = conn.recv(min(int(HTTP_BODY_RECV_BYTES), clen - len(body)))
                except OSError:
                    break
                if not more:
                    break
                body += more
            path, qs = _parse_qs(path)
            log.info('HTTP', 'request', method=method, path=path, query=len(qs), body_len=len(body), content_length=clen, ua=(headers.get('user-agent','')[:50] if headers else ''))
            self._route(conn, method, path, qs, body, headers)
        except MemoryError as e:
            log.warn('HTTP', 'request dropped: memory pressure', err=e)
            _gc_collect('http memory')
            try:
                self._send(conn, 503, 'text/plain', 'ERR memory pressure; retry')
            except Exception:
                pass
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

    def _route(self, conn, method, path, qs, body, headers=None):
        if headers is None:
            headers = {}
        if LOG_PROTOCOL_VERBOSE:
            log.debug('HTTP', 'route', method=method, path=path, body_len=len(body))
        if method == 'OPTIONS':
            log.info('HTTP', 'options')
            self._send(conn, 204, 'text/plain', '')
            return
        captive_paths = ('/generate_204', '/gen_204', '/hotspot-detect.html', '/library/test/success.html', '/connecttest.txt', '/ncsi.txt', '/fwlink', '/wifi', '/0wifi')
        if path == '/' or path == '/index.html':
            self._send_webui(conn, headers, head_only=(method == 'HEAD'), force_plain=(qs.get('plain') == '1'))
        elif path == '/app.js':
            self._send_static(conn, 'webui/app.js', 'application/javascript; charset=utf-8', headers, head_only=(method == 'HEAD'))
        elif path == '/lite':
            self._send_lite_page(conn)
        elif path in captive_paths:
            log.info('HTTP', 'captive probe', path=path)
            self._send_captive_page(conn)
        elif path.startswith('/mmtls/'):
            log.info('HTTP', 'mobile background probe', path=path)
            self._send(conn, 204, 'text/plain; charset=utf-8', '')
        elif path.startswith('/assets/'):
            self._send_asset(conn, path, head_only=(method == 'HEAD'))
        elif path == '/favicon.ico':
            self._send(conn, 204, 'image/x-icon', '')
        elif path == '/api/ping':
            self._send_json(conn, {'ok': True, 'message': 'pong', 'version': getattr(config, 'VERSION', '')})
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
                log.info('HTTP', 'api command begin', cmd=_short_cmd(cmd), wait=0)
                reply = self.app.handle_command(cmd, source='http')
                log.info('HTTP', 'api command end', cmd=_short_cmd(cmd), reply_len=_safe_len(reply), wait=0)
                self._send(conn, 200, 'text/plain; charset=utf-8', reply if reply is not None else 'OK')
        elif path == '/api/binary':
            self._handle_binary(conn, qs)
        elif path == '/api/flyakari/test':
            self._send(conn, 200, 'text/plain; charset=utf-8', 'RinaboardIsOn')
        elif path == '/api/wifi/status':
            self._send_json(conn, self._wifi_status_obj())
        elif path == '/api/wifi/scan':
            log.info('HTTP', 'wifi scan requested')
            nets = self.app.network.scan() if self.app.network else []
            self._send_json(conn, {'ok': True, 'networks': nets})
        elif path == '/api/wifi/save':
            self._handle_wifi_save(conn, body)
        elif path == '/api/state':
            self._send_json(conn, self.app.state_json())
        elif path == '/api/faces':
            self._send_file(conn, self.app.faces.path, 'application/json; charset=utf-8')
        elif path == '/api/battery':
            self._send_json(conn, self.app.battery.snapshot())
        elif path == '/api/scan':
            log.info('HTTP', 'legacy wifi scan requested')
            self._send_json(conn, self.app.network.scan() if self.app.network else [])
        elif path == '/api/cmd':
            cmd = qs.get('c') or _decode_http_text(body)
            log.info('HTTP', 'api command begin', cmd=_short_cmd(cmd), path='/api/cmd')
            if cmd == 'requestSavedFaces370':
                self._send_file(conn, self.app.faces.path, 'application/json; charset=utf-8')
                return
            reply = self.app.handle_command(cmd, source='http')
            ctype = 'application/json; charset=utf-8' if isinstance(reply, str) and reply[:1] in ('{', '[') else 'text/plain; charset=utf-8'
            log.info('HTTP', 'api command end', cmd=_short_cmd(cmd), reply_len=_safe_len(reply), path='/api/cmd')
            self._send(conn, 200, ctype, reply if reply is not None else 'ok')
        else:
            if LOG_PROTOCOL_VERBOSE:
                log.debug('HTTP', 'unknown path', path=path)
            self._send(conn, 404, 'text/plain; charset=utf-8', 'not found')

    def _send_command_reply(self, conn, cmd):
        log.info('HTTP', 'api command begin', cmd=_short_cmd(cmd))
        if cmd == 'requestSavedFaces370':
            self._send_file(conn, self.app.faces.path, 'application/json; charset=utf-8')
            return
        reply = self.app.handle_command(cmd, source='http')
        ctype = 'application/json; charset=utf-8' if isinstance(reply, str) and reply[:1] in ('{', '[') else 'text/plain; charset=utf-8'
        log.info('HTTP', 'api command end', cmd=_short_cmd(cmd), reply_len=_safe_len(reply))
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
            'ap_ip': net.get('ap_ip', AP_IP),
            'ssid': self.app.network.ssid if self.app.network else '',
            'udp_port': UDP_PORT,
            'udp_rx': 0,
            'udp_tx': 0,
            'http_rx': 0,
            'rssi': rssi,
            'manual_control_mode': bool(getattr(self.app, 'manual_control_mode', False)),
            'control_mode': 'manual' if bool(getattr(self.app, 'manual_control_mode', False)) else 'web',
            'runtime': self.app.runtime_status_obj(),
        }

    def _wifi_status_obj(self):
        net = self.app.network.status() if self.app.network else {}
        try:
            import wifi_config
        except Exception:
            wifi_config = None
        ap_active = bool(net.get('ap_active', False))
        mode = net.get('mode', 'ap')
        return {
            'mode': mode,
            'can_configure': ap_active or mode in ('ap', 'sta+ap'),
            'sta_connected': bool(net.get('sta_connected', False)),
            'sta_ssid': self.app.network.ssid if self.app.network and bool(net.get('sta_connected', False)) else '',
            'sta_ip': net.get('sta_ip', self.app.network.ip if self.app.network and bool(net.get('sta_connected', False)) else ''),
            'ap_active': bool(net.get('ap_active', False)),
            'ap_ip': net.get('ap_ip', AP_IP),
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
        log.info('WIFI', 'save request', sta_ssid=sta_ssid, ap_ssid=ap_ssid, ap_channel=ch, ap_open=(not bool(ap_pass)))
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
        log.info('HTTP', 'binary api begin', bytes=len(data), wait=qs.get('wait', '0'))
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
        log.info('HTTP', 'binary api end', bytes=len(data), reply_len=_safe_len(reply))
        self._send(conn, 200, 'text/plain; charset=utf-8', reply if reply is not None else 'OK')

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

    def _file_exists(self, path):
        try:
            os.stat(path)
            return True
        except Exception:
            return False

    def _file_size(self, path):
        try:
            return int(os.stat(path)[6])
        except Exception:
            return -1

    def _send_asset(self, conn, path, head_only=False):
        # Optional large media assets from the 738NGX Unity project can be
        # uploaded under webui/assets/{music,video,voice}. They are not required
        # for LED timeline playback; they only let the browser play media from
        # the board when enough flash is available.
        rel = _url_decode(str(path or '').lstrip('/'))
        rel = rel.replace('..', '').replace('\\', '/')
        fs_path = 'webui/' + rel
        if rel.endswith('.ogg'):
            ctype = 'audio/ogg'
        elif rel.endswith('.mp3'):
            ctype = 'audio/mpeg'
        elif rel.endswith('.mp4'):
            ctype = 'video/mp4'
        elif rel.endswith('.png'):
            ctype = 'image/png'
        elif rel.endswith('.jpg') or rel.endswith('.jpeg'):
            ctype = 'image/jpeg'
        else:
            ctype = 'application/octet-stream'
        if not self._file_exists(fs_path):
            self._send(conn, 404, 'text/plain; charset=utf-8', 'asset not installed: ' + rel)
            return
        self._send_file(conn, fs_path, ctype, head_only=head_only)

    def _send_captive_page(self, conn):
        body = (
            '<!doctype html><html><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<meta http-equiv="refresh" content="0;url=http://' + AP_IP + '/">'
            '<title>RinaChanBoard</title></head><body>'
            '<p>Open <a href="http://' + AP_IP + '/">RinaChanBoard Web UI</a></p>'
            '</body></html>'
        )
        self._send(conn, 200, 'text/html; charset=utf-8', body)

    def _send_webui(self, conn, headers=None, head_only=False, force_plain=False):
        # 2.0.5: always serve the plain HTML file.
        # Do not use index.html.gz even when the browser advertises gzip support.
        log.info('HTTP', 'serve webui plain html', path=WEBUI_FILE)
        self._send_file(conn, WEBUI_FILE, 'text/html; charset=utf-8', head_only=head_only)

    def _send_static(self, conn, path, content_type, headers=None, head_only=False):
        # 2.0.5: always serve plain static files.
        # This avoids stale .gz assets left from previous firmware versions.
        log.info('HTTP', 'serve static plain', path=path, ctype=content_type)
        self._send_file(conn, path, content_type, head_only=head_only)

    def _send_lite_page(self, conn):
        body = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Rina Lite</title><style>body{font-family:system-ui;background:#0f1218;color:#edf2ff;margin:0;padding:16px}button,input{font:inherit;margin:4px;padding:8px;border-radius:8px;border:1px solid #30384a;background:#202838;color:#edf2ff}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#171c25;padding:8px;border-radius:8px}</style></head><body><h2>RinaChanBoard Lite</h2><p>Full UI: <a href="/" style="color:#75f0a9">/</a> | Full UI uses plain HTML/JS: <a href="/?v=208" style="color:#75f0a9">/?v=208</a></p><button onclick="go(\'/api/ping\')">Ping</button><button onclick="go(\'/api/status\')">Status</button><button onclick="go(\'/api/wifi/scan?t=\'+Date.now())">Wi-Fi Scan</button><br><input id="cmd" value="requestManualMode" style="width:90%"><br><button onclick="send()">Send Command</button><pre id="out">ready</pre><script>async function go(p){out.textContent=\'GET \'+p;try{let r=await fetch(p,{cache:\'no-store\'});out.textContent=await r.text()}catch(e){out.textContent=\'ERR \'+e}}async function send(){let body=new URLSearchParams({msg:cmd.value,wait:\'1\'});try{let r=await fetch(\'/api/send\',{method:\'POST\',headers:{\'Content-Type\':\'application/x-www-form-urlencoded\'},body});out.textContent=await r.text()}catch(e){out.textContent=\'ERR \'+e}}</script></body></html>'
        self._send(conn, 200, 'text/html; charset=utf-8', body)

    def _send_file(self, conn, path, content_type, content_encoding=None, head_only=False):
        body_sent = 0
        try:
            size = self._file_size(path)
            log.info('HTTP', 'send file begin', path=path, bytes=size, gzip=content_encoding or '', chunk=HTTP_SEND_CHUNK_BYTES)
            header = 'HTTP/1.1 200 OK\r\nContent-Type: %s\r\nConnection: close\r\n%sCache-Control: no-store\r\n' % (content_type, CORS_HEADERS)
            if size >= 0:
                header += 'Content-Length: %d\r\n' % size
            if content_encoding:
                header += 'Content-Encoding: %s\r\nVary: Accept-Encoding\r\n' % content_encoding
            header += '\r\n'
            if not self._send_bytes(conn, header.encode()):
                log.warn('HTTP', 'send file header aborted', path=path)
                return
            if head_only:
                log.info('HTTP', 'send file head done', path=path, bytes=size)
                return
            ok = True
            with open(path, 'rb') as f:
                while True:
                    chunk = f.read(int(HTTP_SEND_CHUNK_BYTES))
                    if not chunk:
                        break
                    if self._send_bytes(conn, chunk):
                        body_sent += len(chunk)
                    else:
                        ok = False
                        break
            if ok:
                log.info('HTTP', 'send file done', path=path, body_sent=body_sent, expected=size)
            else:
                log.warn('HTTP', 'send file aborted', path=path, body_sent=body_sent, expected=size)
        except Exception as e:
            log.warn('HTTP', 'send file failed', path=path, body_sent=body_sent, err=e)

    def _send(self, conn, status, content_type, body):
        if body is None:
            body = ''
        if isinstance(body, str):
            body = body.encode('utf-8')
        reason = {200: 'OK', 204: 'No Content', 400: 'Bad Request', 404: 'Not Found', 405: 'Method Not Allowed', 413: 'Payload Too Large', 500: 'Internal Server Error', 503: 'Service Unavailable', 504: 'Gateway Timeout'}.get(status, 'OK')
        header = 'HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n%sCache-Control: no-store\r\n\r\n' % (status, reason, content_type, len(body), CORS_HEADERS)
        log.info('HTTP', 'send response', status=status, bytes=len(body), ctype=content_type)
        if self._send_bytes(conn, header.encode()):
            self._send_bytes(conn, body)

    def _send_bytes(self, conn, data):
        if not data:
            return True
        pos = 0
        chunk_size = int(HTTP_SEND_CHUNK_BYTES)
        retry = 0
        total = len(data)
        while pos < total:
            self._urgent()
            end = min(total, pos + chunk_size)
            try:
                sent = conn.send(data[pos:end])
            except OSError as e:
                retry += 1
                if retry <= int(HTTP_SEND_RETRY_COUNT):
                    try:
                        time.sleep_ms(int(HTTP_SEND_RETRY_DELAY_MS))
                    except Exception:
                        pass
                    if retry == 1 or LOG_PROTOCOL_VERBOSE:
                        log.warn('HTTP', 'send retry', sent=pos, total=total, retry=retry, err=e)
                    continue
                log.warn('HTTP', 'client send dropped', sent=pos, total=total, retries=retry, err=e)
                return False
            if sent is None:
                sent = end - pos
            if sent <= 0:
                retry += 1
                if retry <= int(HTTP_SEND_RETRY_COUNT):
                    try:
                        time.sleep_ms(int(HTTP_SEND_RETRY_DELAY_MS))
                    except Exception:
                        pass
                    continue
                log.warn('HTTP', 'client send zero', sent=pos, total=total, retries=retry)
                return False
            pos += sent
            retry = 0
            if total > 1024:
                try:
                    time.sleep_ms(1)
                except Exception:
                    pass
        return True
