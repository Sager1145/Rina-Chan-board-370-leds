# ---------------------------------------------------------------------------
# esp32s3_wifi_ap.py
#
# Wi-Fi / AP boundary module for ESP32-S3 MicroPython builds.
#
# Only esp32s3_wifi_*.py files should directly touch network.WLAN,
# AP_IF, STA_IF, wifi_config.py, Wi-Fi scan, or Wi-Fi credential writes.
# Keep normal LED, WebUI, HTTP, UDP, asset, and animation changes out of this
# file unless the change is explicitly about Wi-Fi/AP behavior.
# ---------------------------------------------------------------------------

import gc
import time
import network

try:
    import wifi_config
except Exception:
    wifi_config = None

try:
    from rina_protocol import LOCAL_UDP_PORT
except Exception:
    LOCAL_UDP_PORT = 1234


def _ticks_ms():
    return time.ticks_ms() if hasattr(time, "ticks_ms") else int(time.time() * 1000)


def _safe_str(v):
    try:
        return str(v)
    except Exception:
        return ""


def _json_escape(s):
    s = _safe_str(s)
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    s = s.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return s


class ESP32S3WifiAP:
    __slots__ = (
        "sta", "ap", "sta_ip", "sta_ssid", "ap_ip", "ssid_label",
        "remember_cb", "last_start_ms",
    )

    # Default AP password used when AP_PASSWORD is empty.
    # Android/iOS often reject or aggressively drop open AP networks. Keeping
    # this fallback inside this isolated module makes the policy easy to audit.
    _AP_DEFAULT_PASSWORD = "rinachan"

    def __init__(self, remember_cb=None):
        self.sta = None
        self.ap = None
        self.sta_ip = None
        self.sta_ssid = None
        self.ap_ip = None
        self.ssid_label = None
        self.remember_cb = remember_cb
        self.last_start_ms = 0

    def _remember(self, prefix, text):
        if self.remember_cb is not None:
            try:
                self.remember_cb(prefix, text)
                return
            except Exception:
                pass
        print("[{:>8} ms] {} {}".format(_ticks_ms(), prefix, _safe_str(text)))

    def cfg(self, name, default=None):
        try:
            return getattr(wifi_config, name, default)
        except Exception:
            return default

    def start(self):
        """Start AP first, then optional STA. Do not change from other modules."""
        self.last_start_ms = _ticks_ms()
        ssid = self.cfg("WIFI_SSID", "") or ""
        password = self.cfg("WIFI_PASSWORD", "") or ""
        ap_ssid = self.cfg("AP_SSID", "RinaChanBoard-ESP32S3") or "RinaChanBoard-ESP32S3"
        ap_password = self.cfg("AP_PASSWORD", "") or ""
        ap_channel = int(self.cfg("AP_CHANNEL", 6) or 6)
        ap_authmode = int(self.cfg("AP_AUTHMODE", 0) or 0)

        # If no AP password was configured, keep the field user-empty in
        # wifi_config.py but run a WPA2 fallback at runtime for phone support.
        if not ap_password:
            ap_password = self._AP_DEFAULT_PASSWORD
            ap_authmode = 3  # WPA2-PSK

        gc.collect()  # defragment heap before Wi-Fi stack allocation
        self.ap = network.WLAN(network.AP_IF)
        self.ap.active(True)

        # Keep the AP subnet fixed. This stabilizes DHCP/captive-portal probes.
        try:
            self.ap.ifconfig(("192.168.4.1", "255.255.255.0", "192.168.4.1", "8.8.8.8"))
        except Exception:
            pass

        # Safety rule: do not call AP_IF.config(pm=...) and do not force
        # active(False)->active(True) on ESP32-S3 MicroPython/ESP-IDF builds.
        # Some builds hard-crash in the Wi-Fi driver before Python can catch it.
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
        self._remember("[WIFI]", "AP ssid={} pw={} ip={}".format(
            ap_ssid, ap_password, self.ap_ip))

        self.sta = network.WLAN(network.STA_IF)
        if ssid:
            self._start_sta(ssid, password)
        else:
            try:
                self.sta.active(False)
            except Exception:
                pass
            self._remember("[WIFI]", "STA disabled; edit wifi_config.py to join router Wi-Fi")
        return True

    def _start_sta(self, ssid, password):
        try:
            self.sta.active(True)
        except Exception:
            pass
        try:
            self.sta.config(dhcp_hostname="RinaChanBoard")
        except Exception:
            pass
        self._remember("[WIFI]", "STA connecting ssid={}".format(ssid))
        try:
            self.sta.connect(ssid, password)
            deadline = _ticks_ms() + 15000
            while (not self.sta.isconnected()) and (_ticks_ms() < deadline):
                time.sleep_ms(100) if hasattr(time, "sleep_ms") else time.sleep(0.1)
            if self.sta.isconnected():
                self.sta_ip = self.sta.ifconfig()[0]
                self.sta_ssid = ssid
                self._remember("[WIFI]", "STA connected ip={}".format(self.sta_ip))
            else:
                self._remember("[WIFI]", "STA connect timeout; AP remains active")
        except Exception as exc:
            self._remember("[WIFI]", "STA connect failed: {}".format(exc))

    def get_ip(self):
        return self.sta_ip or self.ap_ip

    def get_ssid(self):
        return self.sta_ssid or self.ssid_label

    def _sta_connected(self):
        try:
            return bool(self.sta is not None and self.sta.isconnected())
        except Exception:
            return False

    def values(self):
        sta_connected = self._sta_connected()
        sta_ip = ""
        sta_status_code = 0
        rssi = 0
        try:
            if self.sta is not None:
                sta_status_code = int(self.sta.status())
                if sta_connected:
                    sta_ip = self.sta.ifconfig()[0]
                    self.sta_ip = sta_ip
                    try:
                        rssi = int(self.sta.status('rssi'))
                    except Exception:
                        rssi = 0
        except Exception:
            pass
        ap_ip = self.ap_ip or ""
        try:
            if self.ap is not None:
                ap_ip = self.ap.ifconfig()[0]
                self.ap_ip = ap_ip
        except Exception:
            pass
        ap_ssid_cfg = self.cfg("AP_SSID", "RinaChanBoard-ESP32S3") or "RinaChanBoard-ESP32S3"
        sta_ssid_cfg = self.cfg("WIFI_SSID", "") or ""
        return {
            "sta_connected": sta_connected,
            "sta_status": sta_status_code,
            "sta_ip": sta_ip or self.sta_ip or "",
            "sta_ssid": self.sta_ssid or "",
            "sta_ssid_cfg": sta_ssid_cfg,
            "ap_ip": ap_ip,
            "ap_ssid": self.ssid_label or ap_ssid_cfg,
            "ap_ssid_cfg": ap_ssid_cfg,
            "rssi": int(rssi or 0),
        }

    def wifi_status_json(self, client_addr=None):
        v = self.values()
        remote_ip = ""
        try:
            remote_ip = client_addr[0]
        except Exception:
            remote_ip = ""
        can_configure = remote_ip.startswith("192.168.4.") or remote_ip in ("127.0.0.1", "")
        return ("{"
                "\"ok\":true,"
                "\"can_configure\":" + ("true" if can_configure else "false") + ","
                "\"client_ip\":\"" + _json_escape(remote_ip) + "\","
                "\"sta_connected\":" + ("true" if v["sta_connected"] else "false") + ","
                "\"sta_status\":" + str(int(v["sta_status"])) + ","
                "\"sta_ip\":\"" + _json_escape(v["sta_ip"]) + "\","
                "\"sta_ssid\":\"" + _json_escape(v["sta_ssid"]) + "\","
                "\"sta_ssid_cfg\":\"" + _json_escape(v["sta_ssid_cfg"]) + "\","
                "\"ap_ip\":\"" + _json_escape(v["ap_ip"]) + "\","
                "\"ap_ssid\":\"" + _json_escape(v["ap_ssid"]) + "\","
                "\"ap_ssid_cfg\":\"" + _json_escape(v["ap_ssid_cfg"]) + "\","
                "\"rssi\":" + str(int(v["rssi"])) + "}")

    def scan_json(self):
        nets = []
        try:
            if self.sta is None:
                self.sta = network.WLAN(network.STA_IF)
            try:
                self.sta.active(True)
            except Exception:
                pass
            raw = self.sta.scan()
            for item in raw:
                try:
                    ssid = item[0]
                    if isinstance(ssid, bytes):
                        ssid = ssid.decode("utf-8", "replace")
                    channel = int(item[2])
                    rssi = int(item[3])
                    auth = int(item[4])
                    hidden = int(item[5]) if len(item) > 5 else 0
                    if ssid:
                        nets.append((rssi, ssid, channel, auth, hidden))
                except Exception:
                    pass
            nets.sort(reverse=True)
        except Exception as exc:
            print("!!! [API Crash] Wi-Fi 扫描失败: {}".format(exc))
        parts = []
        for rssi, ssid, channel, auth, hidden in nets[:20]:
            parts.append("{\"ssid\":\"" + _json_escape(ssid) + "\",\"rssi\":" + str(rssi) + ",\"channel\":" + str(channel) + ",\"auth\":" + str(auth) + ",\"hidden\":" + str(hidden) + "}")
        return "{\"ok\":true,\"networks\":[" + ",".join(parts) + "]}"

    def _py_string(self, value):
        return repr(_safe_str(value))

    def save_config_json(self, args, udp_port=LOCAL_UDP_PORT):
        ssid = _safe_str(args.get("ssid", "")).strip()
        password = _safe_str(args.get("password", ""))
        ap_ssid = _safe_str(args.get("ap_ssid", "RinaChanBoard-ESP32S3")).strip() or "RinaChanBoard-ESP32S3"
        ap_password = _safe_str(args.get("ap_password", ""))
        try:
            ap_channel = int(args.get("ap_channel", "6") or 6)
        except Exception:
            ap_channel = 6
        if ap_channel < 1:
            ap_channel = 1
        if ap_channel > 13:
            ap_channel = 13
        ap_authmode = 3 if ap_password else 0
        try:
            with open("wifi_config.py", "w") as f:
                f.write("# Auto-generated by RinaChanBoard WebUI.\n")
                f.write("WIFI_SSID = {}\n".format(self._py_string(ssid)))
                f.write("WIFI_PASSWORD = {}\n".format(self._py_string(password)))
                f.write("AP_SSID = {}\n".format(self._py_string(ap_ssid)))
                f.write("AP_PASSWORD = {}\n".format(self._py_string(ap_password)))
                f.write("AP_CHANNEL = {}\n".format(int(ap_channel)))
                f.write("AP_AUTHMODE = {}\n".format(int(ap_authmode)))
                f.write("HTTP_PORT = 80\n")
                f.write("UDP_PORT = {}\n".format(int(udp_port or LOCAL_UDP_PORT)))
            return True, "{\"ok\":true,\"message\":\"Wi-Fi 配置已保存，设备即将重启。\"}", True
        except Exception as exc:
            print("!!! [API Crash] 保存 Wi-Fi 配置失败: {}".format(exc))
            return False, "{\"ok\":false,\"error\":\"" + _json_escape(exc) + "\"}", False
