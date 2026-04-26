# ---------------------------------------------------------------------------
# esp32s3_network.py
#
# Native ESP32-S3 networking layer for the single-chip refactor.
# It replaces the old ESP8258 UART bridge with direct Wi-Fi, HTTP API and UDP
# packet handling running on the same MicroPython firmware as the LED logic.
# ---------------------------------------------------------------------------

import gc
import time
import socket
import network
try:
    import machine
except Exception:
    machine = None

from rina_protocol import LOCAL_UDP_PORT, REMOTE_UDP_PORT, HTTP_PSEUDO_IP, HTTP_PSEUDO_PORT
try:
    import wifi_config
except Exception:
    wifi_config = None

MAX_UDP_PAYLOAD = 1472
MAX_HTTP_BODY = 32768
WEBUI_FILE = "webui/index.html"
HTTP_TIMEOUT_MS = 1500


def _ticks_ms():
    return time.ticks_ms() if hasattr(time, "ticks_ms") else int(time.time() * 1000)


def _ticks_diff(a, b):
    return time.ticks_diff(a, b) if hasattr(time, "ticks_diff") else (a - b)


def _ticks_add(a, b):
    return time.ticks_add(a, b) if hasattr(time, "ticks_add") else (a + b)


def _safe_str(v):
    try:
        return str(v)
    except Exception:
        return ""


def _url_decode(s):
    if isinstance(s, bytes):
        try:
            s = s.decode("ascii", "ignore")
        except Exception:
            s = str(s)
    out = bytearray()
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == "+":
            out.append(32)
            i += 1
            continue
        if c == "%" and i + 2 < n:
            try:
                out.append(int(s[i + 1:i + 3], 16))
                i += 3
                continue
            except Exception:
                pass
        try:
            out.extend(c.encode("utf-8"))
        except Exception:
            out.append(ord("?"))
        i += 1
    try:
        return out.decode("utf-8", "replace")
    except Exception:
        return str(out)


def _parse_query(qs):
    out = {}
    if not qs:
        return out
    for part in qs.split("&"):
        if not part:
            continue
        if "=" in part:
            k, v = part.split("=", 1)
        else:
            k, v = part, ""
        out[_url_decode(k)] = _url_decode(v)
    return out


def _json_escape(s):
    s = _safe_str(s)
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    s = s.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return s


def _hex_to_bytes(hex_text):
    vals = []
    hexchars = "0123456789abcdefABCDEF"
    for c in _safe_str(hex_text):
        if c in hexchars:
            vals.append(c)
    if len(vals) % 2:
        raise ValueError("odd hex length")
    if len(vals) // 2 > MAX_UDP_PAYLOAD:
        raise ValueError("hex too long")
    b = bytearray(len(vals) // 2)
    for i in range(0, len(vals), 2):
        b[i // 2] = int(vals[i] + vals[i + 1], 16)
    return bytes(b)


def _bytes_to_hex(data):
    digits = "0123456789ABCDEF"
    parts = []
    for b in data:
        parts.append(digits[(b >> 4) & 0x0F] + digits[b & 0x0F])
    return " ".join(parts)


class ESP32S3Network:
    __slots__ = (
        "sta", "ap", "udp", "http", "packets", "log", "log_limit",
        "udp_rx", "udp_tx", "http_rx", "start_ms", "last_status_ms",
        "pending_client", "pending_format", "pending_deadline_ms",
        "sta_ip", "sta_ssid", "ap_ip", "ssid_label",
    )

    def __init__(self, log_limit=160):
        self.sta = None
        self.ap = None
        self.udp = None
        self.http = None
        self.packets = []
        self.log = []
        self.log_limit = int(log_limit)
        self.udp_rx = 0
        self.udp_tx = 0
        self.http_rx = 0
        self.start_ms = _ticks_ms()
        self.last_status_ms = 0
        self.pending_client = None
        self.pending_format = "text"
        self.pending_deadline_ms = 0
        self.sta_ip = None
        self.sta_ssid = None
        self.ap_ip = None
        self.ssid_label = None

    def _remember(self, prefix, text):
        line = "[{:>8} ms] {} {}".format(_ticks_ms(), prefix, _safe_str(text).replace("\n", " | "))
        if len(self.log) >= self.log_limit:
            self.log.pop(0)
        self.log.append(line)
        print(line)

    def recent_log(self):
        return "\n".join(self.log[-60:])

    def get_ip(self):
        return self.sta_ip or self.ap_ip

    def get_ssid(self):
        return self.sta_ssid or self.ssid_label

    def _cfg(self, name, default=None):
        try:
            return getattr(wifi_config, name, default)
        except Exception:
            return default

    def start(self):
        self._remember("[NET]", "ESP32-S3 native network start")
        self._start_wifi()
        self._start_udp()
        self._start_http()
        self._status_log()
        return True

    # Default AP password used when AP_PASSWORD is empty.
    # Android 10+ and iOS 14+ refuse or warn on open (authmode=0) networks,
    # which stops phones from connecting at all.  A fixed WPA2 password avoids
    # the security block without requiring the user to configure anything.
    _AP_DEFAULT_PASSWORD = "rinachan"

    def _start_wifi(self):
        ssid = self._cfg("WIFI_SSID", "") or ""
        password = self._cfg("WIFI_PASSWORD", "") or ""
        ap_ssid = self._cfg("AP_SSID", "RinaChanBoard-ESP32S3") or "RinaChanBoard-ESP32S3"
        ap_password = self._cfg("AP_PASSWORD", "") or ""
        ap_channel = int(self._cfg("AP_CHANNEL", 6) or 6)
        ap_authmode = int(self._cfg("AP_AUTHMODE", 0) or 0)

        # If no password was configured, use the built-in default so that
        # modern mobile OSes see a WPA2 network instead of an open one.
        if not ap_password:
            ap_password = self._AP_DEFAULT_PASSWORD
            ap_authmode = 3  # WPA2-PSK

        gc.collect()  # defragment heap before WiFi stack allocation
        self.ap = network.WLAN(network.AP_IF)
        self.ap.active(True)

        # Fix the AP subnet explicitly so the built-in DHCP server always
        # hands out 192.168.4.x addresses with a reachable DNS.  Without this,
        # iOS and Android captive-portal probes fail and the phone may drop the
        # connection immediately after associating.
        try:
            self.ap.ifconfig(("192.168.4.1", "255.255.255.0", "192.168.4.1", "8.8.8.8"))
        except Exception:
            pass

        # Disable AP power-save mode.  The default PS mode on ESP32-S3 skips
        # beacon frames to save power, which causes phones to lose the AP
        # during the WPA2 four-way handshake and fail to associate.
        try:
            self.ap.config(pm=network.WIFI_PS_NONE)
        except Exception:
            try:
                self.ap.config(pm=0)
            except Exception:
                pass

        try:
            self.ap.config(essid=ap_ssid, password=ap_password,
                           channel=ap_channel, authmode=ap_authmode)
        except Exception:
            try:
                self.ap.config(essid=ap_ssid)
            except Exception:
                pass
        try:
            self.ap_ip = self.ap.ifconfig()[0]
        except Exception:
            self.ap_ip = "192.168.4.1"
        self.ssid_label = ap_ssid
        self._remember("[NET]", "AP ssid={} pw={} ip={}".format(
            ap_ssid, ap_password, self.ap_ip))

        self.sta = network.WLAN(network.STA_IF)
        if ssid:
            self.sta.active(True)
            try:
                self.sta.config(dhcp_hostname="RinaChanBoard")
            except Exception:
                pass
            self._remember("[NET]", "STA connecting ssid={}".format(ssid))
            try:
                self.sta.connect(ssid, password)
                deadline = _ticks_add(_ticks_ms(), 15000)
                while not self.sta.isconnected() and _ticks_diff(deadline, _ticks_ms()) > 0:
                    time.sleep_ms(100) if hasattr(time, "sleep_ms") else time.sleep(0.1)
                if self.sta.isconnected():
                    self.sta_ip = self.sta.ifconfig()[0]
                    self.sta_ssid = ssid
                    self._remember("[NET]", "STA connected ip={}".format(self.sta_ip))
                else:
                    self._remember("[NET]", "STA connect timeout; AP remains active")
            except Exception as exc:
                self._remember("[NET]", "STA connect failed: {}".format(exc))
        else:
            try:
                self.sta.active(False)
            except Exception:
                pass
            self._remember("[NET]", "STA disabled; edit wifi_config.py to join router Wi-Fi")

    def _start_udp(self):
        port = int(self._cfg("UDP_PORT", LOCAL_UDP_PORT) or LOCAL_UDP_PORT)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            self.udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        except Exception:
            pass
        self.udp.bind(("0.0.0.0", port))
        self.udp.setblocking(False)
        self._remember("[NET]", "UDP listening port={}".format(port))

    def _start_http(self):
        port = int(self._cfg("HTTP_PORT", 80) or 80)
        self.http = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            self.http.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        except Exception:
            pass
        self.http.bind(("0.0.0.0", port))
        self.http.listen(3)
        self.http.setblocking(False)
        self._remember("[NET]", "HTTP listening port={} routes=/ /api/status /api/send /api/request /api/binary".format(port))

    def _status_log(self):
        self._remember("[STATUS]", "mode=ESP32S3_NATIVE; sta_ip={}; ap_ip={}; udp_rx={}; udp_tx={}; http_rx={}; heap={}".format(
            self.sta_ip, self.ap_ip, self.udp_rx, self.udp_tx, self.http_rx, self._free_heap()))

    def _free_heap(self):
        try:
            import gc
            return gc.mem_free()
        except Exception:
            return 0

    def poll(self):
        self._service_pending_timeout()
        self._poll_udp()
        self._poll_http_once()
        now = _ticks_ms()
        if _ticks_diff(now, self.last_status_ms) >= 30000:
            self.last_status_ms = now
            self._status_log()
        return len(self.packets)

    def get_packet(self):
        self.poll()
        if self.packets:
            return self.packets.pop(0)
        return None

    def _poll_udp(self):
        if self.udp is None:
            return
        while True:
            try:
                data, addr = self.udp.recvfrom(MAX_UDP_PAYLOAD)
            except OSError:
                return
            except Exception as exc:
                self._remember("[UDP]", "recv error {}".format(exc))
                return
            if not data:
                return
            self.udp_rx += 1
            ip, port = addr[0], int(addr[1])
            self.packets.append((0, ip, port, data))
            self._remember("[UDP]", "RX {}:{} len={}".format(ip, port, len(data)))

    def _poll_http_once(self):
        if self.http is None or self.pending_client is not None:
            return
        try:
            client, addr = self.http.accept()
        except OSError:
            return
        except Exception as exc:
            self._remember("[HTTP]", "accept error {}".format(exc))
            return
        try:
            self._handle_http_client(client, addr)
        except Exception as exc:
            self._remember("[HTTP]", "handler error {}".format(exc))
            try:
                self._send_response(client, 500, "text/plain; charset=utf-8", b"Internal Server Error")
            except Exception:
                pass
            try:
                client.close()
            except Exception:
                pass

    def _read_http_request(self, client):
        try:
            client.settimeout(0.15)
        except Exception:
            pass
        buf = b""
        while b"\r\n\r\n" not in buf and len(buf) < 8192:
            try:
                chunk = client.recv(1024)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
        if not buf:
            return None
        header_end = buf.find(b"\r\n\r\n")
        if header_end < 0:
            return None
        head = buf[:header_end].decode("utf-8", "ignore")
        body = buf[header_end + 4:]
        lines = head.split("\r\n")
        if not lines:
            return None
        parts = lines[0].split()
        if len(parts) < 2:
            return None
        method = parts[0].upper()
        target = parts[1]
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        clen = int(headers.get("content-length", "0") or "0")
        if clen > MAX_HTTP_BODY:
            raise ValueError("HTTP body too large")
        while len(body) < clen:
            try:
                chunk = client.recv(min(1024, clen - len(body)))
            except OSError:
                break
            if not chunk:
                break
            body += chunk
        return method, target, headers, body[:clen]

    def _handle_http_client(self, client, addr):
        req = self._read_http_request(client)
        if req is None:
            client.close(); return
        method, target, headers, body = req
        self.http_rx += 1
        if "?" in target:
            path, qs = target.split("?", 1)
        else:
            path, qs = target, ""
        args = _parse_query(qs)
        if method == "POST" and body:
            try:
                post_args = _parse_query(body.decode("utf-8", "ignore"))
                args.update(post_args)
            except Exception:
                pass

        if path in ("/", "/fwlink", "/wifi", "/0wifi"):
            self._serve_webui(client)
            return
        if path == "/api/status":
            self._api_status(client)
            return
        if path == "/api/request":
            cmd = args.get("cmd", "")
            if not cmd:
                self._send_response(client, 400, "text/plain; charset=utf-8", b"missing cmd")
                client.close(); return
            self._queue_http_command(client, cmd.encode(), True, "text")
            return
        if path == "/api/send":
            msg = args.get("msg", args.get("plain", ""))
            wait = args.get("wait", "0") == "1"
            if wait:
                self._queue_http_command(client, msg.encode(), True, "text")
            else:
                self.packets.append((0, HTTP_PSEUDO_IP, 0, msg.encode()))
                self._send_response(client, 200, "text/plain; charset=utf-8", b"OK")
                client.close()
            return
        if path == "/api/binary":
            try:
                data = _hex_to_bytes(args.get("hex", ""))
            except Exception:
                self._send_response(client, 400, "text/plain; charset=utf-8", b"bad hex")
                client.close(); return
            wait = args.get("wait", "0") == "1"
            fmt = args.get("format", "hex") or "hex"
            if wait:
                self._queue_http_command(client, data, True, fmt)
            else:
                self.packets.append((0, HTTP_PSEUDO_IP, 0, data))
                self._send_response(client, 200, "text/plain; charset=utf-8", b"OK")
                client.close()
            return
        if path == "/api/flyakari/test":
            self._queue_http_command(client, b"RinaBoardUdpTest", True, "text")
            return
        if path == "/i":
            text = "RinaChanBoard ESP32-S3 native\n" + self.status_text() + "\n"
            self._send_response(client, 200, "text/plain; charset=utf-8", text.encode())
            client.close(); return
        if path == "/r":
            self._send_response(client, 200, "text/plain; charset=utf-8", b"Restarting ESP32-S3...")
            client.close()
            time.sleep_ms(200) if hasattr(time, "sleep_ms") else time.sleep(0.2)
            if machine is not None:
                machine.reset()
            return
        self._send_response(client, 404, "text/plain; charset=utf-8", b"Not found")
        client.close()

    def _queue_http_command(self, client, data, wait_reply, fmt="text"):
        if self.pending_client is not None:
            self._send_response(client, 503, "text/plain; charset=utf-8", b"busy")
            client.close()
            return
        if not wait_reply:
            self.packets.append((0, HTTP_PSEUDO_IP, 0, data))
            self._send_response(client, 200, "text/plain; charset=utf-8", b"OK")
            client.close()
            return
        self.pending_client = client
        self.pending_format = fmt or "text"
        self.pending_deadline_ms = _ticks_add(_ticks_ms(), HTTP_TIMEOUT_MS)
        self.packets.append((0, HTTP_PSEUDO_IP, HTTP_PSEUDO_PORT, data))
        self._remember("[HTTP]", "queued command len={} fmt={}".format(len(data), self.pending_format))

    def _service_pending_timeout(self):
        if self.pending_client is None:
            return
        if _ticks_diff(_ticks_ms(), self.pending_deadline_ms) < 0:
            return
        client = self.pending_client
        self.pending_client = None
        try:
            self._send_response(client, 504, "text/plain; charset=utf-8", b"timeout/no reply")
        except Exception:
            pass
        try:
            client.close()
        except Exception:
            pass

    def _serve_webui(self, client):
        try:
            f = open(WEBUI_FILE, "rb")
        except Exception:
            self._send_response(client, 404, "text/plain; charset=utf-8", b"webui/index.html missing")
            client.close(); return
        try:
            client.send(b"HTTP/1.1 200 OK\r\n")
            client.send(b"Content-Type: text/html; charset=utf-8\r\n")
            client.send(b"Cache-Control: no-store\r\n")
            client.send(b"Connection: close\r\n\r\n")
            while True:
                chunk = f.read(1024)
                if not chunk:
                    break
                client.send(chunk)
        finally:
            try: f.close()
            except Exception: pass
            try: client.close()
            except Exception: pass
            gc.collect()

    def _send_response(self, client, code, ctype, body):
        if isinstance(body, str):
            body = body.encode()
        reason = {200:"OK",400:"Bad Request",404:"Not Found",413:"Payload Too Large",500:"Internal Server Error",503:"Busy",504:"Gateway Timeout"}.get(code, "OK")
        head = "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".format(code, reason, ctype, len(body))
        client.send(head.encode())
        if body:
            client.send(body)

    def status_text(self):
        sta_status = "CONNECTED" if (self.sta is not None and self.sta.isconnected()) else "DISCONNECTED"
        return "mode=ESP32S3_NATIVE; sta_status={}; ssid={}; ip={}; ap_ip={}; udp_port={}; udp_rx={}; udp_tx={}; http_rx={}; heap={}".format(
            sta_status, self.sta_ssid or "", self.sta_ip or "", self.ap_ip or "", LOCAL_UDP_PORT, self.udp_rx, self.udp_tx, self.http_rx, self._free_heap())

    def _api_status(self, client):
        sta_status = "CONNECTED" if (self.sta is not None and self.sta.isconnected()) else "DISCONNECTED"
        rssi = 0
        try:
            if self.sta is not None and self.sta.isconnected():
                rssi = self.sta.status('rssi')
        except Exception:
            rssi = 0
        body = ("{"
                "\"firmware\":\"1.6.0-esp32s3-native\","
                "\"mode\":\"ESP32S3_NATIVE\","
                "\"sta_status\":\"" + sta_status + "\","
                "\"ssid\":\"" + _json_escape(self.sta_ssid or self.ssid_label or "") + "\","
                "\"ip\":\"" + _json_escape(self.sta_ip or self.ap_ip or "") + "\","
                "\"ap_ip\":\"" + _json_escape(self.ap_ip or "") + "\","
                "\"rssi\":" + str(int(rssi or 0)) + ","
                "\"udp_port\":" + str(LOCAL_UDP_PORT) + ","
                "\"udp_rx\":" + str(self.udp_rx) + ","
                "\"udp_tx\":" + str(self.udp_tx) + ","
                "\"uart_rx_frames\":0,\"uart_tx_frames\":0,"
                "\"heap\":" + str(int(self._free_heap())) + "}")
        self._send_response(client, 200, "application/json; charset=utf-8", body.encode())
        client.close()

    def send_udp(self, data, remote_ip=None, remote_port=REMOTE_UDP_PORT, link_id=0):
        if data is None:
            data = b""
        if isinstance(data, str):
            data = data.encode()
        try:
            port = int(remote_port or REMOTE_UDP_PORT)
        except Exception:
            port = REMOTE_UDP_PORT
        ip = remote_ip or ""
        if ip == HTTP_PSEUDO_IP and port == HTTP_PSEUDO_PORT:
            client = self.pending_client
            fmt = self.pending_format
            self.pending_client = None
            if client is None:
                return True
            try:
                if fmt == "text":
                    self._send_response(client, 200, "text/plain; charset=utf-8", data)
                else:
                    self._send_response(client, 200, "text/plain; charset=utf-8", _bytes_to_hex(data).encode())
            finally:
                try:
                    client.close()
                except Exception:
                    pass
            return True
        if self.udp is None or not ip:
            return False
        try:
            self.udp.sendto(data, (ip, port))
            self.udp_tx += 1
            self._remember("[UDP]", "TX {}:{} len={}".format(ip, port, len(data)))
            return True
        except Exception as exc:
            self._remember("[UDP]", "TX failed {}:{} {}".format(ip, port, exc))
            return False

    def ping(self):
        self._remember("[NET]", "native network alive")
        return True
