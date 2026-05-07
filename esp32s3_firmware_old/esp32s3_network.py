# ---------------------------------------------------------------------------
# esp32s3_network.py
#
# Native ESP32-S3 socket/API layer for the single-chip refactor.
# Wi-Fi/AP driver handling is intentionally isolated in esp32s3_wifi_ap.py and
# esp32s3_wifi_boot.py. This file should only handle HTTP/UDP routing and
# delegate Wi-Fi routes to ESP32S3WifiAP.
# ---------------------------------------------------------------------------

# Import: Loads gc so this module can use that dependency.
import gc
# Import: Loads time so this module can use that dependency.
import time
# Import: Loads socket so this module can use that dependency.
import socket
# Error handling: Attempts the protected operation so failures can be handled safely.
try:
    # Import: Loads os so this module can use that dependency.
    import os
# Error handling: Runs this recovery branch when the protected operation fails.
except Exception:
    # Variable: os stores the empty sentinel value.
    os = None
# Error handling: Attempts the protected operation so failures can be handled safely.
try:
    # Import: Loads machine so this module can use that dependency.
    import machine
# Error handling: Runs this recovery branch when the protected operation fails.
except Exception:
    # Variable: machine stores the empty sentinel value.
    machine = None

# Import: Loads LOCAL_UDP_PORT, REMOTE_UDP_PORT, HTTP_PSEUDO_IP, HTTP_PSEUDO_PORT from rina_protocol so this module can use that dependency.
from rina_protocol import LOCAL_UDP_PORT, REMOTE_UDP_PORT, HTTP_PSEUDO_IP, HTTP_PSEUDO_PORT
# Import: Loads ESP32S3WifiAP from esp32s3_wifi_ap so this module can use that dependency.
from esp32s3_wifi_ap import ESP32S3WifiAP

# Variable: MAX_UDP_PAYLOAD stores the configured literal value.
MAX_UDP_PAYLOAD = 1472
# Variable: MAX_HTTP_BODY stores the configured literal value.
MAX_HTTP_BODY = 32768
# Variable: WEBUI_GZIP_FILE stores the configured text value.
WEBUI_GZIP_FILE = "webui_index.html.gz"
# Variable: HTTP_TIMEOUT_MS stores the configured literal value.
HTTP_TIMEOUT_MS = 1500
# Variable: STATIC_CHUNK_SIZE stores the configured literal value.
STATIC_CHUNK_SIZE = 512
# Variable: HTTP_SEND_SLICE_SIZE stores the configured literal value.
HTTP_SEND_SLICE_SIZE = 256
# Variable: HTTP_SEND_TIMEOUT_S stores the configured literal value.
HTTP_SEND_TIMEOUT_S = 0.25


# Function: Defines _ticks_ms() to handle ticks ms behavior.
def _ticks_ms():
    # Return: Sends the conditional expression time.ticks_ms() if hasattr(time, "ticks_ms") else int(time.time() * 1000) back to the caller.
    return time.ticks_ms() if hasattr(time, "ticks_ms") else int(time.time() * 1000)


# Function: Defines _ticks_diff(a, b) to handle ticks diff behavior.
def _ticks_diff(a, b):
    # Return: Sends the conditional expression time.ticks_diff(a, b) if hasattr(time, "ticks_diff") else (a - b) back to the caller.
    return time.ticks_diff(a, b) if hasattr(time, "ticks_diff") else (a - b)


# Function: Defines _ticks_add(a, b) to handle ticks add behavior.
def _ticks_add(a, b):
    # Return: Sends the conditional expression time.ticks_add(a, b) if hasattr(time, "ticks_add") else (a + b) back to the caller.
    return time.ticks_add(a, b) if hasattr(time, "ticks_add") else (a + b)


# Function: Defines _yield_network() to handle yield network behavior.
def _yield_network():
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Expression: Calls time.sleep_ms() for its side effects.
        time.sleep_ms(0)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls time.sleep() for its side effects.
            time.sleep(0)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass


# Function: Defines _safe_str(v) to handle safe str behavior.
def _safe_str(v):
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Return: Sends the result returned by str() back to the caller.
        return str(v)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Return: Sends the configured text value back to the caller.
        return ""


# Function: Defines _url_decode(s) to handle url decode behavior.
def _url_decode(s):
    # Logic: Branches when isinstance(s, bytes) so the correct firmware path runs.
    if isinstance(s, bytes):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: s stores the result returned by s.decode().
            s = s.decode("ascii", "ignore")
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: s stores the result returned by str().
            s = str(s)
    # Variable: out stores the result returned by bytearray().
    out = bytearray()
    # Variable: i stores the configured literal value.
    i = 0
    # Variable: n stores the result returned by len().
    n = len(s)
    # Loop: Repeats while i < n remains true.
    while i < n:
        # Variable: c stores the selected item s[i].
        c = s[i]
        # Logic: Branches when c == "+" so the correct firmware path runs.
        if c == "+":
            # Expression: Calls out.append() for its side effects.
            out.append(32)
            # Variable: Updates i in place using the configured literal value.
            i += 1
            # Control: Skips to the next loop iteration after this case is handled.
            continue
        # Logic: Branches when c == "%" and i + 2 < n so the correct firmware path runs.
        if c == "%" and i + 2 < n:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls out.append() for its side effects.
                out.append(int(s[i + 1:i + 3], 16))
                # Variable: Updates i in place using the configured literal value.
                i += 3
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls out.extend() for its side effects.
            out.extend(c.encode("utf-8"))
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Expression: Calls out.append() for its side effects.
            out.append(ord("?"))
        # Variable: Updates i in place using the configured literal value.
        i += 1
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Return: Sends the result returned by out.decode() back to the caller.
        return out.decode("utf-8", "replace")
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Return: Sends the result returned by str() back to the caller.
        return str(out)


# Function: Defines _parse_query(qs) to handle parse query behavior.
def _parse_query(qs):
    # Variable: out stores the lookup table used by this module.
    out = {}
    # Logic: Branches when not qs so the correct firmware path runs.
    if not qs:
        # Return: Sends the current out value back to the caller.
        return out
    # Loop: Iterates part over qs.split("&") so each item can be processed.
    for part in qs.split("&"):
        # Logic: Branches when not part so the correct firmware path runs.
        if not part:
            # Control: Skips to the next loop iteration after this case is handled.
            continue
        # Logic: Branches when "=" in part so the correct firmware path runs.
        if "=" in part:
            # Variable: k, v stores the result returned by part.split().
            k, v = part.split("=", 1)
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: k, v stores the collection of values used later in this module.
            k, v = part, ""
        # Variable: out[...] stores the result returned by _url_decode().
        out[_url_decode(k)] = _url_decode(v)
    # Return: Sends the current out value back to the caller.
    return out


# Function: Defines _json_escape(s) to handle json escape behavior.
def _json_escape(s):
    # Variable: s stores the result returned by _safe_str().
    s = _safe_str(s)
    # Variable: s stores the result returned by s.replace.replace().
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    # Variable: s stores the result returned by s.replace.replace.replace().
    s = s.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    # Return: Sends the current s value back to the caller.
    return s


# Function: Defines _hex_to_bytes(hex_text) to handle hex to bytes behavior.
def _hex_to_bytes(hex_text):
    # Variable: vals stores the collection of values used later in this module.
    vals = []
    # Variable: hexchars stores the configured text value.
    hexchars = "0123456789abcdefABCDEF"
    # Loop: Iterates c over _safe_str(hex_text) so each item can be processed.
    for c in _safe_str(hex_text):
        # Logic: Branches when c in hexchars so the correct firmware path runs.
        if c in hexchars:
            # Expression: Calls vals.append() for its side effects.
            vals.append(c)
    # Logic: Branches when len(vals) % 2 so the correct firmware path runs.
    if len(vals) % 2:
        # Error handling: Raises this exception so invalid state is reported immediately.
        raise ValueError("odd hex length")
    # Logic: Branches when len(vals) // 2 > MAX_UDP_PAYLOAD so the correct firmware path runs.
    if len(vals) // 2 > MAX_UDP_PAYLOAD:
        # Error handling: Raises this exception so invalid state is reported immediately.
        raise ValueError("hex too long")
    # Variable: b stores the result returned by bytearray().
    b = bytearray(len(vals) // 2)
    # Loop: Iterates i over range(0, len(vals), 2) so each item can be processed.
    for i in range(0, len(vals), 2):
        # Variable: b[...] stores the result returned by int().
        b[i // 2] = int(vals[i] + vals[i + 1], 16)
    # Return: Sends the result returned by bytes() back to the caller.
    return bytes(b)


# Function: Defines _bytes_to_hex(data) to handle bytes to hex behavior.
def _bytes_to_hex(data):
    # Variable: digits stores the configured text value.
    digits = "0123456789ABCDEF"
    # Variable: parts stores the collection of values used later in this module.
    parts = []
    # Loop: Iterates b over data so each item can be processed.
    for b in data:
        # Expression: Calls parts.append() for its side effects.
        parts.append(digits[(b >> 4) & 0x0F] + digits[b & 0x0F])
    # Return: Sends the result returned by join() back to the caller.
    return " ".join(parts)


# Class: Defines ESP32S3Network as the state and behavior container for ESP32 S3 Network.
class ESP32S3Network:
    # Variable: __slots__ stores the collection of values used later in this module.
    __slots__ = (
        "wifi", "udp", "http", "packets", "log", "log_limit",
        "udp_rx", "udp_tx", "http_rx", "start_ms", "last_status_ms",
        "pending_client", "pending_format", "pending_deadline_ms",
    )

    # Function: Defines __init__(self, log_limit) to handle init behavior.
    def __init__(self, log_limit=160):
        # Variable: self.wifi stores the result returned by ESP32S3WifiAP().
        self.wifi = ESP32S3WifiAP(self._remember)
        # Variable: self.udp stores the empty sentinel value.
        self.udp = None
        # Variable: self.http stores the empty sentinel value.
        self.http = None
        # Variable: self.packets stores the collection of values used later in this module.
        self.packets = []
        # Variable: self.log stores the collection of values used later in this module.
        self.log = []
        # Variable: self.log_limit stores the result returned by int().
        self.log_limit = int(log_limit)
        # Variable: self.udp_rx stores the configured literal value.
        self.udp_rx = 0
        # Variable: self.udp_tx stores the configured literal value.
        self.udp_tx = 0
        # Variable: self.http_rx stores the configured literal value.
        self.http_rx = 0
        # Variable: self.start_ms stores the result returned by _ticks_ms().
        self.start_ms = _ticks_ms()
        # Variable: self.last_status_ms stores the configured literal value.
        self.last_status_ms = 0
        # Variable: self.pending_client stores the empty sentinel value.
        self.pending_client = None
        # Variable: self.pending_format stores the configured text value.
        self.pending_format = "text"
        # Variable: self.pending_deadline_ms stores the configured literal value.
        self.pending_deadline_ms = 0

    # Function: Defines _remember(self, prefix, text) to handle remember behavior.
    def _remember(self, prefix, text):
        # Variable: line stores the result returned by format().
        line = "[{:>8} ms] {} {}".format(_ticks_ms(), prefix, _safe_str(text).replace("\n", " | "))
        # Logic: Branches when len(self.log) >= self.log_limit so the correct firmware path runs.
        if len(self.log) >= self.log_limit:
            # Expression: Calls self.log.pop() for its side effects.
            self.log.pop(0)
        # Expression: Calls self.log.append() for its side effects.
        self.log.append(line)
        # Expression: Calls print() for its side effects.
        print(line)

    # Function: Defines recent_log(self) to handle recent log behavior.
    def recent_log(self):
        # Return: Sends the result returned by join() back to the caller.
        return "\n".join(self.log[-60:])

    # Function: Defines get_ip(self) to handle get ip behavior.
    def get_ip(self):
        # Return: Sends the result returned by self.wifi.get_ip() back to the caller.
        return self.wifi.get_ip()

    # Function: Defines get_ssid(self) to handle get ssid behavior.
    def get_ssid(self):
        # Return: Sends the result returned by self.wifi.get_ssid() back to the caller.
        return self.wifi.get_ssid()

    # Function: Defines _cfg(self, name, default) to handle cfg behavior.
    def _cfg(self, name, default=None):
        # Return: Sends the result returned by self.wifi.cfg() back to the caller.
        return self.wifi.cfg(name, default)

    # Function: Defines start(self) to handle start behavior.
    def start(self):
        # Expression: Calls self._remember() for its side effects.
        self._remember("[NET]", "ESP32-S3 native network start")
        # Expression: Calls self._start_wifi() for its side effects.
        self._start_wifi()
        # Expression: Calls self._start_udp() for its side effects.
        self._start_udp()
        # Expression: Calls self._start_http() for its side effects.
        self._start_http()
        # Expression: Calls self._status_log() for its side effects.
        self._status_log()
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True

    # Function: Defines _start_wifi(self) to handle start wifi behavior.
    def _start_wifi(self):
        # AP/STA behavior is intentionally isolated in esp32s3_wifi_ap.py.
        # Return: Sends the result returned by self.wifi.start() back to the caller.
        return self.wifi.start()

    # Function: Defines _start_udp(self) to handle start udp behavior.
    def _start_udp(self):
        # Variable: port stores the result returned by int().
        port = int(self._cfg("UDP_PORT", LOCAL_UDP_PORT) or LOCAL_UDP_PORT)
        # Variable: self.udp stores the result returned by socket.socket().
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls self.udp.setsockopt() for its side effects.
            self.udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass
        # Expression: Calls self.udp.bind() for its side effects.
        self.udp.bind(("0.0.0.0", port))
        # Expression: Calls self.udp.setblocking() for its side effects.
        self.udp.setblocking(False)
        # Expression: Calls self._remember() for its side effects.
        self._remember("[NET]", "UDP listening port={}".format(port))

    # Function: Defines _start_http(self) to handle start http behavior.
    def _start_http(self):
        # Variable: port stores the result returned by int().
        port = int(self._cfg("HTTP_PORT", 80) or 80)
        # Variable: self.http stores the result returned by socket.socket().
        self.http = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls self.http.setsockopt() for its side effects.
            self.http.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass
        # Expression: Calls self.http.bind() for its side effects.
        self.http.bind(("0.0.0.0", port))
        # Expression: Calls self.http.listen() for its side effects.
        self.http.listen(3)
        # Expression: Calls self.http.setblocking() for its side effects.
        self.http.setblocking(False)
        # Expression: Calls self._remember() for its side effects.
        self._remember("[NET]", "HTTP listening port={} routes=/ /api/status /api/send /api/request /api/binary /api/wifi/status /api/wifi/scan /api/wifi/save".format(port))

    # Function: Defines _status_log(self) to handle status log behavior.
    def _status_log(self):
        # Variable: w stores the result returned by self.wifi.values().
        w = self.wifi.values()
        # Expression: Calls self._remember() for its side effects.
        self._remember("[STATUS]", "mode=ESP32S3_NATIVE; sta_ip={}; ap_ip={}; udp_rx={}; udp_tx={}; http_rx={}; heap={}".format(
            w.get("sta_ip", ""), w.get("ap_ip", ""), self.udp_rx, self.udp_tx, self.http_rx, self._free_heap()))

    # Function: Defines _free_heap(self) to handle free heap behavior.
    def _free_heap(self):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Import: Loads gc so this module can use that dependency.
            import gc
            # Return: Sends the result returned by gc.mem_free() back to the caller.
            return gc.mem_free()
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Return: Sends the configured literal value back to the caller.
            return 0

    # Function: Defines poll(self) to handle poll behavior.
    def poll(self):
        # Expression: Calls self._service_pending_timeout() for its side effects.
        self._service_pending_timeout()
        # Expression: Calls self._poll_udp() for its side effects.
        self._poll_udp()
        # Expression: Calls self._poll_http_once() for its side effects.
        self._poll_http_once()
        # Variable: now stores the result returned by _ticks_ms().
        now = _ticks_ms()
        # Logic: Branches when _ticks_diff(now, self.last_status_ms) >= 30000 so the correct firmware path runs.
        if _ticks_diff(now, self.last_status_ms) >= 30000:
            # Variable: self.last_status_ms stores the current now value.
            self.last_status_ms = now
            # Expression: Calls self._status_log() for its side effects.
            self._status_log()
        # Return: Sends the result returned by len() back to the caller.
        return len(self.packets)

    # Function: Defines get_packet(self) to handle get packet behavior.
    def get_packet(self):
        # Expression: Calls self.poll() for its side effects.
        self.poll()
        # Logic: Branches when self.packets so the correct firmware path runs.
        if self.packets:
            # Return: Sends the result returned by self.packets.pop() back to the caller.
            return self.packets.pop(0)
        # Return: Sends the empty sentinel value back to the caller.
        return None

    # Function: Defines _poll_udp(self) to handle poll udp behavior.
    def _poll_udp(self):
        # Logic: Branches when self.udp is None so the correct firmware path runs.
        if self.udp is None:
            # Return: Sends control back to the caller.
            return
        # Loop: Repeats while True remains true.
        while True:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: data, addr stores the result returned by self.udp.recvfrom().
                data, addr = self.udp.recvfrom(MAX_UDP_PAYLOAD)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except OSError:
                # Return: Sends control back to the caller.
                return
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls self._remember() for its side effects.
                self._remember("[UDP]", "recv error {}".format(exc))
                # Return: Sends control back to the caller.
                return
            # Logic: Branches when not data so the correct firmware path runs.
            if not data:
                # Return: Sends control back to the caller.
                return
            # Variable: Updates self.udp_rx in place using the configured literal value.
            self.udp_rx += 1
            # Variable: ip, port stores the collection of values used later in this module.
            ip, port = addr[0], int(addr[1])
            # Expression: Calls self.packets.append() for its side effects.
            self.packets.append((0, ip, port, data))
            # Expression: Calls self._remember() for its side effects.
            self._remember("[UDP]", "RX {}:{} len={}".format(ip, port, len(data)))

    # Function: Defines _poll_http_once(self) to handle poll http once behavior.
    def _poll_http_once(self):
        # Logic: Branches when self.http is None or self.pending_client is not None so the correct firmware path runs.
        if self.http is None or self.pending_client is not None:
            # Return: Sends control back to the caller.
            return
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: client, addr stores the result returned by self.http.accept().
            client, addr = self.http.accept()
        # Error handling: Runs this recovery branch when the protected operation fails.
        except OSError:
            # Return: Sends control back to the caller.
            return
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Expression: Calls self._remember() for its side effects.
            self._remember("[HTTP]", "accept error {}".format(exc))
            # Return: Sends control back to the caller.
            return
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls self._handle_http_client() for its side effects.
            self._handle_http_client(client, addr)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Expression: Calls self._remember() for its side effects.
            self._remember("[HTTP]", "handler error {}".format(exc))
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self._send_response() for its side effects.
                self._send_response(client, 500, "text/plain; charset=utf-8", b"Internal Server Error")
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls client.close() for its side effects.
                client.close()
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass

    # Function: Defines _read_http_request(self, client) to handle read http request behavior.
    def _read_http_request(self, client):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls client.settimeout() for its side effects.
            client.settimeout(0.15)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass
        # Variable: buf stores the configured literal value.
        buf = b""
        # Loop: Repeats while b"\r\n\r\n" not in buf and len(buf) < 8192 remains true.
        while b"\r\n\r\n" not in buf and len(buf) < 8192:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: chunk stores the result returned by client.recv().
                chunk = client.recv(1024)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except OSError:
                # Control: Stops the loop once the required condition has been met.
                break
            # Logic: Branches when not chunk so the correct firmware path runs.
            if not chunk:
                # Control: Stops the loop once the required condition has been met.
                break
            # Variable: Updates buf in place using the current chunk value.
            buf += chunk
        # Logic: Branches when not buf so the correct firmware path runs.
        if not buf:
            # Return: Sends the empty sentinel value back to the caller.
            return None
        # Variable: header_end stores the result returned by buf.find().
        header_end = buf.find(b"\r\n\r\n")
        # Logic: Branches when header_end < 0 so the correct firmware path runs.
        if header_end < 0:
            # Return: Sends the empty sentinel value back to the caller.
            return None
        # Variable: head stores the result returned by decode().
        head = buf[:header_end].decode("utf-8", "ignore")
        # Variable: body stores the selected item buf[header_end + 4:].
        body = buf[header_end + 4:]
        # Variable: lines stores the result returned by head.split().
        lines = head.split("\r\n")
        # Logic: Branches when not lines so the correct firmware path runs.
        if not lines:
            # Return: Sends the empty sentinel value back to the caller.
            return None
        # Variable: parts stores the result returned by split().
        parts = lines[0].split()
        # Logic: Branches when len(parts) < 2 so the correct firmware path runs.
        if len(parts) < 2:
            # Return: Sends the empty sentinel value back to the caller.
            return None
        # Variable: method stores the result returned by upper().
        method = parts[0].upper()
        # Variable: target stores the selected item parts[1].
        target = parts[1]
        # Variable: headers stores the lookup table used by this module.
        headers = {}
        # Loop: Iterates line over lines[1:] so each item can be processed.
        for line in lines[1:]:
            # Logic: Branches when ":" in line so the correct firmware path runs.
            if ":" in line:
                # Variable: k, v stores the result returned by line.split().
                k, v = line.split(":", 1)
                # Variable: headers[...] stores the result returned by v.strip().
                headers[k.strip().lower()] = v.strip()
        # Variable: clen stores the result returned by int().
        clen = int(headers.get("content-length", "0") or "0")
        # Logic: Branches when clen > MAX_HTTP_BODY so the correct firmware path runs.
        if clen > MAX_HTTP_BODY:
            # Error handling: Raises this exception so invalid state is reported immediately.
            raise ValueError("HTTP body too large")
        # Loop: Repeats while len(body) < clen remains true.
        while len(body) < clen:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: chunk stores the result returned by client.recv().
                chunk = client.recv(min(1024, clen - len(body)))
            # Error handling: Runs this recovery branch when the protected operation fails.
            except OSError:
                # Control: Stops the loop once the required condition has been met.
                break
            # Logic: Branches when not chunk so the correct firmware path runs.
            if not chunk:
                # Control: Stops the loop once the required condition has been met.
                break
            # Variable: Updates body in place using the current chunk value.
            body += chunk
        # Return: Sends the collection of values used later in this module back to the caller.
        return method, target, headers, body[:clen]

    # Function: Defines _handle_http_client(self, client, addr) to handle handle http client behavior.
    def _handle_http_client(self, client, addr):
        # Variable: req stores the result returned by self._read_http_request().
        req = self._read_http_request(client)
        # Logic: Branches when req is None so the correct firmware path runs.
        if req is None:
            # Return: Sends control back to the caller.
            # Expression: Calls client.close() for its side effects.
            client.close(); return
        # Variable: method, target, headers, body stores the current req value.
        method, target, headers, body = req
        # Variable: Updates self.http_rx in place using the configured literal value.
        self.http_rx += 1
        # Logic: Branches when "?" in target so the correct firmware path runs.
        if "?" in target:
            # Variable: path, qs stores the result returned by target.split().
            path, qs = target.split("?", 1)
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: path, qs stores the collection of values used later in this module.
            path, qs = target, ""
        # Variable: args stores the result returned by _parse_query().
        args = _parse_query(qs)
        # Logic: Branches when method == "GET" so the correct firmware path runs.
        if method == "GET":
            # Expression: Calls print() for its side effects.
            print(">>> [HTTP GET] 请求路径: {}".format(target))
        # Logic: Branches when method == "POST" and body so the correct firmware path runs.
        if method == "POST" and body:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: post_args stores the result returned by _parse_query().
                post_args = _parse_query(body.decode("utf-8", "ignore"))
                # Expression: Calls args.update() for its side effects.
                args.update(post_args)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("!!! [API Parse] POST 数据解析失败 path={} error={}".format(path, exc))

        # Logic: Branches when method == "OPTIONS" so the correct firmware path runs.
        if method == "OPTIONS":
            # Expression: Calls self._send_response() for its side effects.
            self._send_response(client, 200, "text/plain; charset=utf-8", b"OK")
            # Expression: Calls client.close() for its side effects.
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try: client.close()
            # Control: Leaves this branch intentionally empty.
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception: pass
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when path in ("/", "/fwlink", "/wifi", "/0wifi") so the correct firmware path runs.
        if path in ("/", "/fwlink", "/wifi", "/0wifi"):
            # Expression: Calls self._serve_webui() for its side effects.
            self._serve_webui(client)
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when path == "/api/status" so the correct firmware path runs.
        if path == "/api/status":
            # Expression: Calls self._api_status() for its side effects.
            self._api_status(client)
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when path == "/api/wifi/status" so the correct firmware path runs.
        if path == "/api/wifi/status":
            # Expression: Calls self._api_wifi_status() for its side effects.
            self._api_wifi_status(client, addr)
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when path == "/api/wifi/scan" so the correct firmware path runs.
        if path == "/api/wifi/scan":
            # Expression: Calls self._api_wifi_scan() for its side effects.
            self._api_wifi_scan(client)
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when path == "/api/wifi/save" so the correct firmware path runs.
        if path == "/api/wifi/save":
            # Expression: Calls print() for its side effects.
            print(">>> [API Command] 收到前端指令: wifiSave")
            # Expression: Calls self._api_wifi_save() for its side effects.
            self._api_wifi_save(client, args)
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when path == "/api/request" so the correct firmware path runs.
        if path == "/api/request":
            # Variable: cmd stores the result returned by args.get().
            cmd = args.get("cmd", "")
            # Expression: Calls print() for its side effects.
            print(">>> [API Command] 收到前端指令: {}".format(_safe_str(cmd)[:160]))
            # Logic: Branches when not cmd so the correct firmware path runs.
            if not cmd:
                # Expression: Calls self._send_response() for its side effects.
                self._send_response(client, 400, "text/plain; charset=utf-8", b"missing cmd")
                # Return: Sends control back to the caller.
                # Expression: Calls client.close() for its side effects.
                client.close(); return
            # Expression: Calls self._queue_http_command() for its side effects.
            self._queue_http_command(client, cmd.encode(), True, "text")
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when path == "/api/send" so the correct firmware path runs.
        if path == "/api/send":
            # Variable: msg stores the result returned by args.get().
            msg = args.get("msg", args.get("plain", ""))
            # Expression: Calls print() for its side effects.
            print(">>> [API Command] 收到前端指令: {}".format(_safe_str(msg)[:160]))
            # Variable: wait stores the comparison result args.get("wait", "0") == "1".
            wait = args.get("wait", "0") == "1"
            # Logic: Branches when wait so the correct firmware path runs.
            if wait:
                # Expression: Calls self._queue_http_command() for its side effects.
                self._queue_http_command(client, msg.encode(), True, "text")
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.packets.append() for its side effects.
                self.packets.append((0, HTTP_PSEUDO_IP, 0, msg.encode()))
                # Expression: Calls self._send_response() for its side effects.
                self._send_response(client, 200, "text/plain; charset=utf-8", b"OK")
                # Expression: Calls client.close() for its side effects.
                client.close()
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when path == "/api/binary" so the correct firmware path runs.
        if path == "/api/binary":
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: data stores the result returned by _hex_to_bytes().
                data = _hex_to_bytes(args.get("hex", ""))
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("!!! [API Parse] binary hex 解析失败: {}".format(exc))
                # Expression: Calls self._send_response() for its side effects.
                self._send_response(client, 400, "text/plain; charset=utf-8", b"bad hex")
                # Return: Sends control back to the caller.
                # Expression: Calls client.close() for its side effects.
                client.close(); return
            # Variable: wait stores the comparison result args.get("wait", "0") == "1".
            wait = args.get("wait", "0") == "1"
            # Variable: fmt stores the combined condition args.get("format", "hex") or "hex".
            fmt = args.get("format", "hex") or "hex"
            # Expression: Calls print() for its side effects.
            print(">>> [API Command] 收到前端二进制指令: len={} wait={} fmt={}".format(len(data), wait, fmt))
            # Logic: Branches when wait so the correct firmware path runs.
            if wait:
                # Expression: Calls self._queue_http_command() for its side effects.
                self._queue_http_command(client, data, True, fmt)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.packets.append() for its side effects.
                self.packets.append((0, HTTP_PSEUDO_IP, 0, data))
                # Expression: Calls self._send_response() for its side effects.
                self._send_response(client, 200, "text/plain; charset=utf-8", b"OK")
                # Expression: Calls client.close() for its side effects.
                client.close()
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when path == "/api/flyakari/test" so the correct firmware path runs.
        if path == "/api/flyakari/test":
            # Expression: Calls print() for its side effects.
            print(">>> [API Command] 收到前端指令: RinaBoardUdpTest")
            # Expression: Calls self._queue_http_command() for its side effects.
            self._queue_http_command(client, b"RinaBoardUdpTest", True, "text")
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when path == "/i" so the correct firmware path runs.
        if path == "/i":
            # Variable: text stores the calculated expression "RinaChanBoard ESP32-S3 native\n" + self.status_text() + "\n".
            text = "RinaChanBoard ESP32-S3 native\n" + self.status_text() + "\n"
            # Expression: Calls self._send_response() for its side effects.
            self._send_response(client, 200, "text/plain; charset=utf-8", text.encode())
            # Return: Sends control back to the caller.
            # Expression: Calls client.close() for its side effects.
            client.close(); return
        # Logic: Branches when path == "/r" so the correct firmware path runs.
        if path == "/r":
            # Expression: Calls self._send_response() for its side effects.
            self._send_response(client, 200, "text/plain; charset=utf-8", b"Restarting ESP32-S3...")
            # Expression: Calls client.close() for its side effects.
            client.close()
            # Expression: Evaluates this expression for its effect in the current scope.
            time.sleep_ms(200) if hasattr(time, "sleep_ms") else time.sleep(0.2)
            # Logic: Branches when machine is not None so the correct firmware path runs.
            if machine is not None:
                # Expression: Calls machine.reset() for its side effects.
                machine.reset()
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when method in ("GET", "HEAD") so the correct firmware path runs.
        if method in ("GET", "HEAD"):
            # Expression: Calls self._send_file() for its side effects.
            self._send_file(client, self._static_path_to_file(path))
            # Return: Sends control back to the caller.
            return
        # Expression: Calls print() for its side effects.
        print("!!! [404 Error] 未知接口: {}".format(path))
        # Expression: Calls self._send_response() for its side effects.
        self._send_response(client, 404, "text/plain; charset=utf-8", b"Not found")
        # Expression: Calls client.close() for its side effects.
        client.close()

    # Function: Defines _queue_http_command(self, client, data, wait_reply, fmt) to handle queue http command behavior.
    def _queue_http_command(self, client, data, wait_reply, fmt="text"):
        # Logic: Branches when self.pending_client is not None so the correct firmware path runs.
        if self.pending_client is not None:
            # Expression: Calls self._send_response() for its side effects.
            self._send_response(client, 503, "text/plain; charset=utf-8", b"busy")
            # Expression: Calls client.close() for its side effects.
            client.close()
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when not wait_reply so the correct firmware path runs.
        if not wait_reply:
            # Expression: Calls self.packets.append() for its side effects.
            self.packets.append((0, HTTP_PSEUDO_IP, 0, data))
            # Expression: Calls self._send_response() for its side effects.
            self._send_response(client, 200, "text/plain; charset=utf-8", b"OK")
            # Expression: Calls client.close() for its side effects.
            client.close()
            # Return: Sends control back to the caller.
            return
        # Variable: self.pending_client stores the current client value.
        self.pending_client = client
        # Variable: self.pending_format stores the combined condition fmt or "text".
        self.pending_format = fmt or "text"
        # Variable: self.pending_deadline_ms stores the result returned by _ticks_add().
        self.pending_deadline_ms = _ticks_add(_ticks_ms(), HTTP_TIMEOUT_MS)
        # Expression: Calls self.packets.append() for its side effects.
        self.packets.append((0, HTTP_PSEUDO_IP, HTTP_PSEUDO_PORT, data))
        # Expression: Calls self._remember() for its side effects.
        self._remember("[HTTP]", "queued command len={} fmt={}".format(len(data), self.pending_format))

    # Function: Defines _service_pending_timeout(self) to handle service pending timeout behavior.
    def _service_pending_timeout(self):
        # Logic: Branches when self.pending_client is None so the correct firmware path runs.
        if self.pending_client is None:
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when _ticks_diff(_ticks_ms(), self.pending_deadline_ms) < 0 so the correct firmware path runs.
        if _ticks_diff(_ticks_ms(), self.pending_deadline_ms) < 0:
            # Return: Sends control back to the caller.
            return
        # Variable: client stores the referenced self.pending_client value.
        client = self.pending_client
        # Variable: self.pending_client stores the empty sentinel value.
        self.pending_client = None
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls self._send_response() for its side effects.
            self._send_response(client, 504, "text/plain; charset=utf-8", b"timeout/no reply")
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls client.close() for its side effects.
            client.close()
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass

    # Function: Defines _safe_send(self, client, data, label) to handle safe send behavior.
    def _safe_send(self, client, data, label=""):
        # Logic: Branches when data is None so the correct firmware path runs.
        if data is None:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when isinstance(data, str) so the correct firmware path runs.
        if isinstance(data, str):
            # Variable: data stores the result returned by data.encode().
            data = data.encode()
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls client.settimeout() for its side effects.
            client.settimeout(HTTP_SEND_TIMEOUT_S)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: view stores the result returned by memoryview().
            view = memoryview(data)
            # Variable: sent stores the configured literal value.
            sent = 0
            # Variable: total stores the result returned by len().
            total = len(view)
            # Never hand a large remaining memoryview to send().  On ESP32 AP, a
            # slow/disconnected phone can otherwise pin the single firmware loop
            # until the socket times out, which looks like an AP freeze.
            # Loop: Repeats while sent < total remains true.
            while sent < total:
                # Variable: end stores the calculated expression sent + HTTP_SEND_SLICE_SIZE.
                end = sent + HTTP_SEND_SLICE_SIZE
                # Logic: Branches when end > total so the correct firmware path runs.
                if end > total:
                    # Variable: end stores the current total value.
                    end = total
                # Variable: n stores the result returned by client.send().
                n = client.send(view[sent:end])
                # Logic: Branches when n is None so the correct firmware path runs.
                if n is None:
                    # Return: Sends the enabled/disabled flag value back to the caller.
                    return True
                # Logic: Branches when n <= 0 so the correct firmware path runs.
                if n <= 0:
                    # Error handling: Raises this exception so invalid state is reported immediately.
                    raise OSError("send returned {}".format(n))
                # Variable: Updates sent in place using the current n value.
                sent += n
                # Expression: Calls _yield_network() for its side effects.
                _yield_network()
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Error handling: Runs this recovery branch when the protected operation fails.
        except OSError as exc:
            # Expression: Calls print() for its side effects.
            print("!!! [Socket Error] 发送数据给客户端时断开，错误码: {}".format(exc))
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self._remember() for its side effects.
                self._remember("[SOCK]", "send failed {} {}".format(label, exc))
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Expression: Calls print() for its side effects.
            print("!!! [Socket Error] 发送数据给客户端时发生异常: {}".format(exc))
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self._remember() for its side effects.
                self._remember("[SOCK]", "send exception {} {}".format(label, exc))
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False

    # Function: Defines _mime_type(self, filepath) to handle mime type behavior.
    def _mime_type(self, filepath):
        # Variable: p stores the result returned by _safe_str.lower().
        p = _safe_str(filepath).lower()
        # Logic: Branches when p.endswith(".html") or p.endswith(".html.gz") so the correct firmware path runs.
        if p.endswith(".html") or p.endswith(".html.gz"):
            # Return: Sends the configured text value back to the caller.
            return "text/html; charset=utf-8"
        # Logic: Branches when p.endswith(".js") or p.endswith(".js.gz") so the correct firmware path runs.
        if p.endswith(".js") or p.endswith(".js.gz"):
            # Return: Sends the configured text value back to the caller.
            return "application/javascript; charset=utf-8"
        # Logic: Branches when p.endswith(".css") or p.endswith(".css.gz") so the correct firmware path runs.
        if p.endswith(".css") or p.endswith(".css.gz"):
            # Return: Sends the configured text value back to the caller.
            return "text/css; charset=utf-8"
        # Logic: Branches when p.endswith(".json") or p.endswith(".json.gz") so the correct firmware path runs.
        if p.endswith(".json") or p.endswith(".json.gz"):
            # Return: Sends the configured text value back to the caller.
            return "application/json; charset=utf-8"
        # Logic: Branches when p.endswith(".rnt") or p.endswith(".txt") or p.endswith(".md") so the correct firmware path runs.
        if p.endswith(".rnt") or p.endswith(".txt") or p.endswith(".md"):
            # Return: Sends the configured text value back to the caller.
            return "text/plain; charset=utf-8"
        # Logic: Branches when p.endswith(".png") so the correct firmware path runs.
        if p.endswith(".png"):
            # Return: Sends the configured text value back to the caller.
            return "image/png"
        # Logic: Branches when p.endswith(".ico") so the correct firmware path runs.
        if p.endswith(".ico"):
            # Return: Sends the configured text value back to the caller.
            return "image/x-icon"
        # Logic: Branches when p.endswith(".wasm") so the correct firmware path runs.
        if p.endswith(".wasm"):
            # Return: Sends the configured text value back to the caller.
            return "application/wasm"
        # Return: Sends the configured text value back to the caller.
        return "application/octet-stream"

    # Function: Defines _static_path_to_file(self, path) to handle static path to file behavior.
    def _static_path_to_file(self, path):
        # Variable: raw stores the result returned by _url_decode().
        raw = _url_decode(path or "/")
        # Logic: Branches when raw.startswith("/") so the correct firmware path runs.
        if raw.startswith("/"):
            # Variable: raw stores the selected item raw[1:].
            raw = raw[1:]
        # Variable: raw stores the result returned by replace().
        raw = raw.split("?", 1)[0].replace("\\", "/")
        # Logic: Branches when raw in ("", "index.html", "webui_index.html", "fwlink", "wifi", "0wifi") so the correct firmware path runs.
        if raw in ("", "index.html", "webui_index.html", "fwlink", "wifi", "0wifi"):
            # Return: Sends the current WEBUI_GZIP_FILE value back to the caller.
            return WEBUI_GZIP_FILE
        # Logic: Branches when raw.startswith("webui/") so the correct firmware path runs.
        if raw.startswith("webui/"):
            # Variable: raw stores the selected item raw[6:].
            raw = raw[6:]
        # Loop: Repeats while raw.startswith("/") remains true.
        while raw.startswith("/"):
            # Variable: raw stores the selected item raw[1:].
            raw = raw[1:]
        # Logic: Branches when not raw or ".." in raw or raw.startswith("/") so the correct firmware path runs.
        if not raw or ".." in raw or raw.startswith("/"):
            # Return: Sends the empty sentinel value back to the caller.
            return None
        # Return: Sends the current raw value back to the caller.
        return raw

    # Function: Defines _file_size(self, filepath) to handle file size behavior.
    def _file_size(self, filepath):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Logic: Branches when os is not None so the correct firmware path runs.
            if os is not None:
                # Return: Sends the result returned by int() back to the caller.
                return int(os.stat(filepath)[6])
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass
        # Return: Sends the empty sentinel value back to the caller.
        return None

    # Function: Defines _send_file(self, client, filepath) to handle send file behavior.
    def _send_file(self, client, filepath):
        # Logic: Branches when not filepath so the correct firmware path runs.
        if not filepath:
            # Expression: Calls print() for its side effects.
            print("!!! [404 Error] 文件不存在或读取失败: {}".format(filepath))
            # Expression: Calls self._send_response() for its side effects.
            self._send_response(client, 404, "text/plain; charset=utf-8", b"Not found")
            # Expression: Calls client.close() for its side effects.
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try: client.close()
            # Control: Leaves this branch intentionally empty.
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception: pass
            # Return: Sends control back to the caller.
            return
        # Expression: Calls gc.collect() for its side effects.
        gc.collect()
        # Expression: Calls print() for its side effects.
        print(">>> [Memory] 发送 {} 前剩余内存: {} bytes".format(filepath, self._free_heap()))
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: f stores the result returned by open().
            f = open(filepath, "rb")
            # Expression: Calls print() for its side effects.
            print(">>> [File] 成功打开文件: {}".format(filepath))
        # Error handling: Runs this recovery branch when the protected operation fails.
        except OSError as exc:
            # Expression: Calls print() for its side effects.
            print("!!! [404 Error] 文件不存在或读取失败: {} ({})".format(filepath, exc))
            # Expression: Calls self._send_response() for its side effects.
            self._send_response(client, 404, "text/plain; charset=utf-8", b"Not found")
            # Expression: Calls client.close() for its side effects.
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try: client.close()
            # Control: Leaves this branch intentionally empty.
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception: pass
            # Expression: Calls gc.collect() for its side effects.
            gc.collect()
            # Return: Sends control back to the caller.
            return
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Expression: Calls print() for its side effects.
            print("!!! [404 Error] 文件不存在或读取失败: {} ({})".format(filepath, exc))
            # Expression: Calls self._send_response() for its side effects.
            self._send_response(client, 404, "text/plain; charset=utf-8", b"Not found")
            # Expression: Calls client.close() for its side effects.
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try: client.close()
            # Control: Leaves this branch intentionally empty.
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception: pass
            # Expression: Calls gc.collect() for its side effects.
            gc.collect()
            # Return: Sends control back to the caller.
            return
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: header stores the result returned by format().
            header = "HTTP/1.1 200 OK\r\nContent-Type: {}\r\n".format(self._mime_type(filepath))
            # Variable: size stores the result returned by self._file_size().
            size = self._file_size(filepath)
            # Logic: Branches when size is not None so the correct firmware path runs.
            if size is not None:
                # Variable: Updates header in place using the result returned by format().
                header += "Content-Length: {}\r\n".format(size)
            # Logic: Branches when _safe_str(filepath).lower().endswith(".gz") so the correct firmware path runs.
            if _safe_str(filepath).lower().endswith(".gz"):
                # Variable: Updates header in place using the configured text value.
                header += "Content-Encoding: gzip\r\n"
            # Variable: Updates header in place using the configured text value.
            header += "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            # Logic: Branches when not self._safe_send(client, header.encode(), filepath + " header") so the correct firmware path runs.
            if not self._safe_send(client, header.encode(), filepath + " header"):
                # Return: Sends control back to the caller.
                return
            # Loop: Repeats while True remains true.
            while True:
                # Variable: chunk stores the result returned by f.read().
                chunk = f.read(STATIC_CHUNK_SIZE)
                # Logic: Branches when not chunk so the correct firmware path runs.
                if not chunk:
                    # Control: Stops the loop once the required condition has been met.
                    break
                # Logic: Branches when not self._safe_send(client, chunk, filepath) so the correct firmware path runs.
                if not self._safe_send(client, chunk, filepath):
                    # Control: Stops the loop once the required condition has been met.
                    break
                # Expression: Calls _yield_network() for its side effects.
                _yield_network()
        # Cleanup: Runs this cleanup branch whether the protected operation succeeds or fails.
        finally:
            # Expression: Calls f.close() for its side effects.
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try: f.close()
            # Control: Leaves this branch intentionally empty.
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception: pass
            # Expression: Calls client.close() for its side effects.
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try: client.close()
            # Control: Leaves this branch intentionally empty.
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception: pass
            # Expression: Calls gc.collect() for its side effects.
            gc.collect()
            # Expression: Calls print() for its side effects.
            print(">>> [Memory] 发送完成，剩余内存: {} bytes".format(self._free_heap()))

    # Function: Defines _serve_webui(self, client) to handle serve webui behavior.
    def _serve_webui(self, client):
        # Expression: Calls self._send_file() for its side effects.
        self._send_file(client, WEBUI_GZIP_FILE)

    # Function: Defines _send_response(self, client, code, ctype, body) to handle send response behavior.
    def _send_response(self, client, code, ctype, body):
        # Logic: Branches when isinstance(body, str) so the correct firmware path runs.
        if isinstance(body, str):
            # Variable: body stores the result returned by body.encode().
            body = body.encode()
        # Variable: reason stores the result returned by get().
        reason = {200:"OK",400:"Bad Request",404:"Not Found",413:"Payload Too Large",500:"Internal Server Error",503:"Busy",504:"Gateway Timeout"}.get(code, "OK")
        # Variable: head stores the result returned by format().
        head = "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".format(code, reason, ctype, len(body))
        # Logic: Branches when not self._safe_send(client, head.encode(), "response header") so the correct firmware path runs.
        if not self._safe_send(client, head.encode(), "response header"):
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Logic: Branches when body so the correct firmware path runs.
        if body:
            # Return: Sends the result returned by self._safe_send() back to the caller.
            return self._safe_send(client, body, "response body")
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True

    # Function: Defines _json_response(self, client, body) to handle json response behavior.
    def _json_response(self, client, body):
        # Expression: Calls self._send_response() for its side effects.
        self._send_response(client, 200, "application/json; charset=utf-8", body)
        # Expression: Calls client.close() for its side effects.
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try: client.close()
        # Control: Leaves this branch intentionally empty.
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception: pass

    # Function: Defines _api_wifi_status(self, client, client_addr) to handle api wifi status behavior.
    def _api_wifi_status(self, client, client_addr=None):
        # Expression: Calls self._json_response() for its side effects.
        self._json_response(client, self.wifi.wifi_status_json(client_addr))

    # Function: Defines _api_wifi_scan(self, client) to handle api wifi scan behavior.
    def _api_wifi_scan(self, client):
        # Expression: Calls self._json_response() for its side effects.
        self._json_response(client, self.wifi.scan_json())

    # Function: Defines _api_wifi_save(self, client, args) to handle api wifi save behavior.
    def _api_wifi_save(self, client, args):
        # Variable: ok, body, should_reset stores the result returned by self.wifi.save_config_json().
        ok, body, should_reset = self.wifi.save_config_json(args, LOCAL_UDP_PORT)
        # Logic: Branches when ok so the correct firmware path runs.
        if ok:
            # Expression: Calls self._json_response() for its side effects.
            self._json_response(client, body)
            # Expression: Evaluates this expression for its effect in the current scope.
            time.sleep_ms(300) if hasattr(time, "sleep_ms") else time.sleep(0.3)
            # Logic: Branches when should_reset and machine is not None so the correct firmware path runs.
            if should_reset and machine is not None:
                # Expression: Calls machine.reset() for its side effects.
                machine.reset()
            # Return: Sends control back to the caller.
            return
        # Expression: Calls self._send_response() for its side effects.
        self._send_response(client, 500, "application/json; charset=utf-8", body)
        # Expression: Calls client.close() for its side effects.
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try: client.close()
        # Control: Leaves this branch intentionally empty.
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception: pass

    # Function: Defines status_text(self) to handle status text behavior.
    def status_text(self):
        # Variable: w stores the result returned by self.wifi.values().
        w = self.wifi.values()
        # Variable: sta_status stores the conditional expression "CONNECTED" if w.get("sta_connected") else "DISCONNECTED".
        sta_status = "CONNECTED" if w.get("sta_connected") else "DISCONNECTED"
        # Return: Sends the result returned by format() back to the caller.
        return "mode=ESP32S3_NATIVE; sta_status={}; ssid={}; ip={}; ap_ip={}; udp_port={}; udp_rx={}; udp_tx={}; http_rx={}; heap={}".format(
            sta_status, w.get("sta_ssid", ""), w.get("sta_ip", ""), w.get("ap_ip", ""), LOCAL_UDP_PORT, self.udp_rx, self.udp_tx, self.http_rx, self._free_heap())

    # Function: Defines _api_status(self, client) to handle api status behavior.
    def _api_status(self, client):
        # Variable: w stores the result returned by self.wifi.values().
        w = self.wifi.values()
        # Variable: sta_status stores the conditional expression "CONNECTED" if w.get("sta_connected") else "DISCONNECTED".
        sta_status = "CONNECTED" if w.get("sta_connected") else "DISCONNECTED"
        # Variable: body stores the calculated expression "{" "\"firmware\":\"1.6.7-mobile-face-manager-responsive\"," "\"mode\":\"ESP32S3_NATI....
        body = ("{"
                "\"firmware\":\"1.6.7-mobile-face-manager-responsive\","
                "\"mode\":\"ESP32S3_NATIVE\","
                "\"sta_status\":\"" + sta_status + "\","
                "\"ssid\":\"" + _json_escape(w.get("sta_ssid", "") or w.get("ap_ssid", "")) + "\","
                "\"ip\":\"" + _json_escape(w.get("sta_ip", "") or w.get("ap_ip", "")) + "\","
                "\"ap_ip\":\"" + _json_escape(w.get("ap_ip", "")) + "\","
                "\"rssi\":" + str(int(w.get("rssi", 0) or 0)) + ","
                "\"udp_port\":" + str(LOCAL_UDP_PORT) + ","
                "\"udp_rx\":" + str(self.udp_rx) + ","
                "\"udp_tx\":" + str(self.udp_tx) + ","
                "\"uart_rx_frames\":0,\"uart_tx_frames\":0,"
                "\"heap\":" + str(int(self._free_heap())) + "}")
        # Expression: Calls self._send_response() for its side effects.
        self._send_response(client, 200, "application/json; charset=utf-8", body.encode())
        # Expression: Calls client.close() for its side effects.
        client.close()

    # Function: Defines send_udp(self, data, remote_ip, remote_port, link_id) to handle send udp behavior.
    def send_udp(self, data, remote_ip=None, remote_port=REMOTE_UDP_PORT, link_id=0):
        # Logic: Branches when data is None so the correct firmware path runs.
        if data is None:
            # Variable: data stores the configured literal value.
            data = b""
        # Logic: Branches when isinstance(data, str) so the correct firmware path runs.
        if isinstance(data, str):
            # Variable: data stores the result returned by data.encode().
            data = data.encode()
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: port stores the result returned by int().
            port = int(remote_port or REMOTE_UDP_PORT)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: port stores the current REMOTE_UDP_PORT value.
            port = REMOTE_UDP_PORT
        # Variable: ip stores the combined condition remote_ip or "".
        ip = remote_ip or ""
        # Logic: Branches when ip == HTTP_PSEUDO_IP and port == HTTP_PSEUDO_PORT so the correct firmware path runs.
        if ip == HTTP_PSEUDO_IP and port == HTTP_PSEUDO_PORT:
            # Variable: client stores the referenced self.pending_client value.
            client = self.pending_client
            # Variable: fmt stores the referenced self.pending_format value.
            fmt = self.pending_format
            # Variable: self.pending_client stores the empty sentinel value.
            self.pending_client = None
            # Logic: Branches when client is None so the correct firmware path runs.
            if client is None:
                # Return: Sends the enabled/disabled flag value back to the caller.
                return True
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Logic: Branches when fmt == "text" so the correct firmware path runs.
                if fmt == "text":
                    # Expression: Calls self._send_response() for its side effects.
                    self._send_response(client, 200, "text/plain; charset=utf-8", data)
                # Logic: Runs this fallback branch when the earlier condition did not match.
                else:
                    # Expression: Calls self._send_response() for its side effects.
                    self._send_response(client, 200, "text/plain; charset=utf-8", _bytes_to_hex(data).encode())
            # Cleanup: Runs this cleanup branch whether the protected operation succeeds or fails.
            finally:
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Expression: Calls client.close() for its side effects.
                    client.close()
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception:
                    # Control: Leaves this branch intentionally empty.
                    pass
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when self.udp is None or not ip so the correct firmware path runs.
        if self.udp is None or not ip:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls self.udp.sendto() for its side effects.
            self.udp.sendto(data, (ip, port))
            # Variable: Updates self.udp_tx in place using the configured literal value.
            self.udp_tx += 1
            # Expression: Calls self._remember() for its side effects.
            self._remember("[UDP]", "TX {}:{} len={}".format(ip, port, len(data)))
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Expression: Calls self._remember() for its side effects.
            self._remember("[UDP]", "TX failed {}:{} {}".format(ip, port, exc))
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False

    # Function: Defines ping(self) to handle ping behavior.
    def ping(self):
        # Expression: Calls self._remember() for its side effects.
        self._remember("[NET]", "native network alive")
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True
