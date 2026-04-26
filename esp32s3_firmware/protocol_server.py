import socket
import time
import os
import ujson as json
import config
import logger as log
try:
    import gc
except Exception:
    gc = None
try:
    import machine
except Exception:
    machine = None
HTTP_PORT = getattr(config, 'HTTP_PORT', 80)
UDP_PORT = getattr(config, 'UDP_PORT', 1234)
AP_IP = getattr(config, 'AP_IP', '192.168.4.1')
MAX_HTTP_BODY = getattr(config, 'MAX_HTTP_BODY', 8192)
WEBUI_FILE = getattr(config, 'WEBUI_FILE', 'webui/index.html')
APP_JS_FILE = getattr(config, 'APP_JS_FILE', 'webui/app.js')
APP_JS_GZIP_FILE = getattr(config, 'APP_JS_GZIP_FILE', APP_JS_FILE + '.gz')
HTTP_CLIENT_TIMEOUT_MS = getattr(config, 'HTTP_CLIENT_TIMEOUT_MS', 3000)
HTTP_SEND_CHUNK_BYTES = getattr(config, 'HTTP_SEND_CHUNK_BYTES', 256)
HTTP_BODY_RECV_BYTES = getattr(config, 'HTTP_BODY_RECV_BYTES', 512)
HTTP_HEADER_MAX_BYTES = getattr(config, 'HTTP_HEADER_MAX_BYTES', 2048)
UDP_RECV_BYTES = getattr(config, 'UDP_RECV_BYTES', 768)
CORS = 'Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET,POST,OPTIONS,HEAD\r\nAccess-Control-Allow-Headers: Content-Type,Cache-Control\r\n'
CAPTIVE = ('/generate_204','/gen_204','/hotspot-detect.html','/library/test/success.html','/connecttest.txt','/ncsi.txt','/fwlink','/wifi','/0wifi')
def _gc(reason=None):
    if gc:
        try:
            gc.collect()
        except Exception:
            pass
def _dec(data):
    if isinstance(data, str):
        return data
    try:
        return data.decode('utf-8')
    except Exception:
        try:
            return data.decode()
        except Exception:
            return str(data)
def _url(s):
    s = _dec(s).replace('+', ' ')
    out = ''
    i = 0
    while i < len(s):
        if s[i] == '%' and i + 2 < len(s):
            try:
                out += chr(int(s[i + 1:i + 3], 16)); i += 3; continue
            except Exception:
                pass
        out += s[i]; i += 1
    return out
def _qs(path):
    if '?' not in path:
        return path, {}
    path, q = path.split('?', 1)
    out = {}
    for p in q.split('&'):
        if not p:
            continue
        if '=' in p:
            k, v = p.split('=', 1)
        else:
            k, v = p, ''
        out[_url(k)] = _url(v)
    return path, out
def _form(body):
    return _qs('?' + _dec(body))[1]
def _short(s, n=120):
    s = str(s or '').replace('\r', ' ').replace('\n', ' ')
    return s[:n] + ('...' if len(s) > n else '')
def _hex_to_bytes(text):
    vals = []
    for c in str(text or ''):
        if c in '0123456789abcdefABCDEF':
            vals.append(c)
    if len(vals) & 1:
        vals.append('0')
    b = bytearray(len(vals) // 2)
    for i in range(0, len(vals), 2):
        b[i // 2] = int(vals[i] + vals[i + 1], 16)
    return bytes(b)
def _bytes_to_hex(data):
    out = ''
    for b in data:
        out += '%02X' % b
    return out
def _exists(path):
    try:
        os.stat(path); return True
    except Exception:
        return False
def _size(path):
    try:
        return int(os.stat(path)[6])
    except Exception:
        return -1
class ProtocolServer:
    __slots__ = ('app','http','udp','client_timeout_s')
    def __init__(self, app):
        self.app = app
        self.http = None
        self.udp = None
        self.client_timeout_s = max(0.05, float(HTTP_CLIENT_TIMEOUT_MS) / 1000.0)
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
        log.info('SERVER', 'listening lite', http_port=HTTP_PORT, udp_port=UDP_PORT)
        _gc('server begin')
    def poll(self):
        self._poll_udp()
        self._poll_http()
    def _urgent(self):
        try:
            self.app.urgent_poll()
        except Exception:
            pass
    def _poll_udp(self):
        if self.udp is None:
            return
        try:
            data, addr = self.udp.recvfrom(int(UDP_RECV_BYTES))
        except OSError:
            return
        except MemoryError:
            _gc('udp'); return
        try:
            text = bool(data and all((32 <= b <= 126) or b in (9,10,13) for b in data[:64]))
            reply = self.app.handle_command(data.decode().strip(), 'udp') if text else self.app.handle_legacy_udp(data)
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
            log.warn('UDP', 'error', err=e)
        self._urgent()
    def _poll_http(self):
        if self.http is None:
            return
        try:
            conn, addr = self.http.accept()
        except OSError:
            return
        try:
            conn.settimeout(self.client_timeout_s)
            self._handle_http(conn)
        except MemoryError as e:
            _gc('http memory')
            try:
                self._send(conn, 503, 'text/plain; charset=utf-8', 'ERR memory; retry')
            except Exception:
                pass
            log.warn('HTTP', 'memory pressure', err=e)
        except Exception as e:
            try:
                self._send(conn, 500, 'text/plain; charset=utf-8', 'ERR ' + str(e))
            except Exception:
                pass
            log.warn('HTTP', 'error', err=e)
        try:
            conn.close()
        except Exception:
            pass
        _gc('http done')
    def _handle_http(self, conn):
        req = conn.recv(512)
        if not req:
            return
        if not (req.startswith(b'GET ') or req.startswith(b'POST ') or req.startswith(b'HEAD ') or req.startswith(b'OPTIONS ')):
            return
        head = req
        while b'\r\n\r\n' not in head and len(head) < int(HTTP_HEADER_MAX_BYTES):
            self._urgent()
            more = conn.recv(512)
            if not more:
                break
            head += more
        if b'\r\n\r\n' in head:
            header, body = head.split(b'\r\n\r\n', 1)
        else:
            header, body = head, b''
        lines = _dec(header).split('\r\n')
        first = lines[0].split()
        if len(first) < 2:
            self._send(conn, 400, 'text/plain; charset=utf-8', 'bad request'); return
        method, path = first[0], first[1]
        headers = {}
        for line in lines[1:]:
            if ':' in line:
                k, v = line.split(':', 1); headers[k.lower()] = v.strip()
        try:
            clen = int(headers.get('content-length', '0') or '0')
        except Exception:
            clen = 0
        if clen > MAX_HTTP_BODY:
            self._send(conn, 413, 'text/plain; charset=utf-8', 'body too large'); return
        while len(body) < clen:
            self._urgent()
            more = conn.recv(min(int(HTTP_BODY_RECV_BYTES), clen - len(body)))
            if not more:
                break
            body += more
        path, query = _qs(path)
        self._route(conn, method, path, query, body)
    def _route(self, conn, method, path, query, body):
        head_only = method == 'HEAD'
        if method == 'OPTIONS':
            self._send(conn, 204, 'text/plain', ''); return
        if path == '/' or path == '/index.html':
            self._send_file(conn, WEBUI_FILE, 'text/html; charset=utf-8', head_only=head_only); return
        if path == '/app.js':
            if _exists(APP_JS_GZIP_FILE):
                self._send_file(conn, APP_JS_GZIP_FILE, 'application/javascript; charset=utf-8', 'gzip', head_only); return
            self._send_file(conn, APP_JS_FILE, 'application/javascript; charset=utf-8', head_only=head_only); return
        if path in CAPTIVE:
            self._send(conn, 200, 'text/html; charset=utf-8', '<html><body><a href="http://' + AP_IP + '/">Open RinaChanBoard</a></body></html>'); return
        if path.startswith('/assets/'):
            self._asset(conn, path, head_only); return
        if path == '/favicon.ico' or path.startswith('/mmtls/'):
            self._send(conn, 204, 'text/plain', ''); return
        if path == '/api/ping':
            self._json(conn, {'ok': True, 'message': 'pong', 'version': getattr(config, 'VERSION', '')}); return
        if path == '/api/status':
            self._json(conn, self._status()); return
        if path == '/api/state':
            self._json(conn, self.app.state_json()); return
        if path == '/api/battery':
            self._json(conn, self.app.battery.snapshot()); return
        if path == '/api/faces':
            self._send_file(conn, self.app.faces.path, 'application/json; charset=utf-8'); return
        if path == '/i':
            self._send(conn, 200, 'text/plain; charset=utf-8', 'RinaChanBoard ESP32-S3\n' + json.dumps(self._status())); return
        if path == '/r':
            self._send(conn, 200, 'text/plain; charset=utf-8', 'Restarting...')
            if machine:
                machine.reset()
            return
        if path == '/api/wifi/status':
            self._json(conn, self._wifi_status()); return
        if path in ('/api/wifi/scan','/api/scan'):
            nets = self.app.network.scan() if self.app.network else []
            self._json(conn, {'ok': True, 'networks': nets} if path == '/api/wifi/scan' else nets); return
        if path == '/api/wifi/save':
            self._wifi_save(conn, body); return
        if path == '/api/binary':
            self._binary(conn, query); return
        if path in ('/api/request','/api/send','/api/cmd'):
            frm = _form(body)
            cmd = query.get('cmd') or query.get('c') or query.get('msg') or query.get('plain') or frm.get('cmd') or frm.get('msg') or frm.get('plain') or _dec(body)
            self._cmd(conn, cmd); return
        self._send(conn, 404, 'text/plain; charset=utf-8', 'not found')
    def _cmd(self, conn, cmd):
        if cmd == 'requestSavedFaces370':
            self._send_file(conn, self.app.faces.path, 'application/json; charset=utf-8'); return
        reply = self.app.handle_command(cmd, 'http')
        ctype = 'application/json; charset=utf-8' if isinstance(reply, str) and reply[:1] in ('{','[') else 'text/plain; charset=utf-8'
        self._send(conn, 200, ctype, reply if reply is not None else 'OK')
    def _status(self):
        net = self.app.network.status() if self.app.network else {}
        return {'mode':net.get('mode','ap'),'sta_status':net.get('sta_status',''),'ip':self.app.network.ip if self.app.network else AP_IP,'ap_ip':net.get('ap_ip', AP_IP),'ssid':self.app.network.ssid if self.app.network else '', 'udp_port':UDP_PORT, 'manual_control_mode':bool(getattr(self.app,'manual_control_mode',False)), 'control_mode':'manual' if bool(getattr(self.app,'manual_control_mode',False)) else 'web', 'runtime':self.app.runtime_status_obj()}
    def _wifi_status(self):
        net = self.app.network.status() if self.app.network else {}
        return {'mode':net.get('mode','ap'),'can_configure':True,'sta_connected':bool(net.get('sta_connected',False)),'sta_ssid':self.app.network.ssid if self.app.network and bool(net.get('sta_connected',False)) else '','sta_ip':net.get('sta_ip',''),'ap_active':bool(net.get('ap_active',False)),'ap_ip':net.get('ap_ip', AP_IP),'ap_ssid_cfg':getattr(config,'AP_SSID','RinaChanBoard-S3'),'ap_channel_cfg':getattr(config,'AP_CHANNEL',6)}
    def _wifi_save(self, conn, body):
        f = _form(body)
        sta = f.get('ssid',''); spw = f.get('password','')
        assid = f.get('ap_ssid', getattr(config, 'AP_SSID', 'RinaChanBoard-S3')) or 'RinaChanBoard-S3'
        apw = f.get('ap_password', getattr(config, 'AP_PASSWORD', '12345678'))
        try:
            ch = max(1, min(11, int(f.get('ap_channel', getattr(config, 'AP_CHANNEL', 6)) or 6)))
        except Exception:
            ch = 6
        esc = lambda s: str(s or '').replace('\\','\\\\').replace('"','\\"')
        text = 'STA_SSID="{}"\nSTA_PASSWORD="{}"\nAP_SSID="{}"\nAP_PASSWORD="{}"\nAP_COMPAT_OPEN={}\nAP_CHANNEL={}\n'.format(esc(sta),esc(spw),esc(assid),esc(apw),'True' if not apw else 'False',ch)
        try:
            open('wifi_config.py','w').write(text)
            self._json(conn, {'ok': True, 'message': 'Wi-Fi saved; rebooting'})
            time.sleep_ms(200)
            if machine:
                machine.reset()
        except Exception as e:
            self._json(conn, {'ok': False, 'error': str(e)}, 500)
    def _binary(self, conn, query):
        data = _hex_to_bytes(query.get('hex',''))
        if query.get('wait','0') == '1' and len(data) == 2:
            code = (data[0] << 8) | data[1]
            if code == 0x1001:
                rep = _hex_to_bytes(self.app.handle_command('requestFace','http'))
            elif code == 0x1002:
                rep = bytes((self.app.color[0] & 255, self.app.color[1] & 255, self.app.color[2] & 255))
            elif code == 0x1003:
                rep = bytes((int(max(0,min(255,(self.app.brightness*255+50)//100))),))
            elif code == 0x1004:
                rep = str(getattr(config,'VERSION','')).encode()
            else:
                rep = b'Command Error!'
            self._send(conn, 200, 'text/plain; charset=utf-8', _dec(rep) if query.get('format') == 'text' else _bytes_to_hex(rep)); return
        self._send(conn, 200, 'text/plain; charset=utf-8', self.app.handle_legacy_udp(data))
    def _asset(self, conn, path, head_only=False):
        rel = _url(path.lstrip('/')).replace('..','').replace('\\','/')
        fs = 'webui/' + rel
        ctype = 'application/octet-stream'
        if fs.endswith('.json') or fs.endswith('.json.gz'):
            ctype = 'application/json; charset=utf-8'
        elif fs.endswith('.js') or fs.endswith('.js.gz'):
            ctype = 'application/javascript; charset=utf-8'
        elif fs.endswith('.html'):
            ctype = 'text/html; charset=utf-8'
        gz = fs + '.gz'
        if _exists(gz):
            self._send_file(conn, gz, ctype, 'gzip', head_only); return
        if fs.endswith('.gz'):
            self._send_file(conn, fs, ctype, 'gzip', head_only); return
        self._send_file(conn, fs, ctype, head_only=head_only)
    def _json(self, conn, obj, status=200):
        self._send(conn, status, 'application/json; charset=utf-8', json.dumps(obj))
    def _send_file(self, conn, path, ctype, encoding=None, head_only=False):
        if not _exists(path):
            self._send(conn, 404, 'text/plain; charset=utf-8', 'missing ' + path); return
        size = _size(path)
        h = 'HTTP/1.1 200 OK\r\nContent-Type: %s\r\nConnection: close\r\n%sCache-Control: no-store\r\n' % (ctype, CORS)
        if size >= 0:
            h += 'Content-Length: %d\r\n' % size
        if encoding:
            h += 'Content-Encoding: %s\r\nVary: Accept-Encoding\r\n' % encoding
        h += '\r\n'
        if not self._send_bytes(conn, h.encode()) or head_only:
            return
        with open(path, 'rb') as f:
            while True:
                chunk = f.read(int(HTTP_SEND_CHUNK_BYTES))
                if not chunk:
                    break
                if not self._send_bytes(conn, chunk):
                    break
    def _send(self, conn, status, ctype, body):
        if body is None:
            body = ''
        if isinstance(body, str):
            body = body.encode('utf-8')
        reason = {200:'OK',204:'No Content',400:'Bad Request',404:'Not Found',413:'Payload Too Large',500:'Internal Server Error',503:'Service Unavailable'}.get(status,'OK')
        h = 'HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n%sCache-Control: no-store\r\n\r\n' % (status, reason, ctype, len(body), CORS)
        if self._send_bytes(conn, h.encode()) and body:
            self._send_bytes(conn, body)
    def _send_bytes(self, conn, data):
        pos = 0; n = len(data); step = int(HTTP_SEND_CHUNK_BYTES)
        while pos < n:
            self._urgent()
            try:
                sent = conn.send(data[pos:pos + step])
            except OSError:
                return False
            if not sent:
                sent = min(step, n - pos)
            pos += sent
        return True
