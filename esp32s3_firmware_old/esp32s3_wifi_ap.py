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

# Import: Loads gc so this module can use that dependency.
import gc
# Import: Loads time so this module can use that dependency.
import time
# Import: Loads network so this module can use that dependency.
import network

# Error handling: Attempts the protected operation so failures can be handled safely.
try:
    # Import: Loads wifi_config so this module can use that dependency.
    import wifi_config
# Error handling: Runs this recovery branch when the protected operation fails.
except Exception:
    # Variable: wifi_config stores the empty sentinel value.
    wifi_config = None

# Error handling: Attempts the protected operation so failures can be handled safely.
try:
    # Import: Loads LOCAL_UDP_PORT from rina_protocol so this module can use that dependency.
    from rina_protocol import LOCAL_UDP_PORT
# Error handling: Runs this recovery branch when the protected operation fails.
except Exception:
    # Variable: LOCAL_UDP_PORT stores the configured literal value.
    LOCAL_UDP_PORT = 1234


# Function: Defines _ticks_ms() to handle ticks ms behavior.
def _ticks_ms():
    # Return: Sends the conditional expression time.ticks_ms() if hasattr(time, "ticks_ms") else int(time.time() * 1000) back to the caller.
    return time.ticks_ms() if hasattr(time, "ticks_ms") else int(time.time() * 1000)


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


# Class: Defines ESP32S3WifiAP as the state and behavior container for ESP32 S3 Wifi AP.
class ESP32S3WifiAP:
    # Variable: __slots__ stores the collection of values used later in this module.
    __slots__ = (
        "sta", "ap", "sta_ip", "sta_ssid", "ap_ip", "ssid_label",
        "remember_cb", "last_start_ms",
    )

    # Default AP password used when AP_PASSWORD is empty.
    # Android/iOS often reject or aggressively drop open AP networks. Keeping
    # this fallback inside this isolated module makes the policy easy to audit.
    # Variable: _AP_DEFAULT_PASSWORD stores the configured text value.
    _AP_DEFAULT_PASSWORD = "rinachan"

    # Function: Defines __init__(self, remember_cb) to handle init behavior.
    def __init__(self, remember_cb=None):
        # Variable: self.sta stores the empty sentinel value.
        self.sta = None
        # Variable: self.ap stores the empty sentinel value.
        self.ap = None
        # Variable: self.sta_ip stores the empty sentinel value.
        self.sta_ip = None
        # Variable: self.sta_ssid stores the empty sentinel value.
        self.sta_ssid = None
        # Variable: self.ap_ip stores the empty sentinel value.
        self.ap_ip = None
        # Variable: self.ssid_label stores the empty sentinel value.
        self.ssid_label = None
        # Variable: self.remember_cb stores the current remember_cb value.
        self.remember_cb = remember_cb
        # Variable: self.last_start_ms stores the configured literal value.
        self.last_start_ms = 0

    # Function: Defines _remember(self, prefix, text) to handle remember behavior.
    def _remember(self, prefix, text):
        # Logic: Branches when self.remember_cb is not None so the correct firmware path runs.
        if self.remember_cb is not None:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.remember_cb() for its side effects.
                self.remember_cb(prefix, text)
                # Return: Sends control back to the caller.
                return
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass
        # Expression: Calls print() for its side effects.
        print("[{:>8} ms] {} {}".format(_ticks_ms(), prefix, _safe_str(text)))

    # Function: Defines cfg(self, name, default) to handle cfg behavior.
    def cfg(self, name, default=None):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Return: Sends the result returned by getattr() back to the caller.
            return getattr(wifi_config, name, default)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Return: Sends the current default value back to the caller.
            return default

    # Function: Defines start(self) to handle start behavior.
    def start(self):
        # Module: Documents the purpose of this scope.
        """Start AP first, then optional STA. Do not change from other modules."""
        # Variable: self.last_start_ms stores the result returned by _ticks_ms().
        self.last_start_ms = _ticks_ms()
        # Variable: ssid stores the combined condition self.cfg("WIFI_SSID", "") or "".
        ssid = self.cfg("WIFI_SSID", "") or ""
        # Variable: password stores the combined condition self.cfg("WIFI_PASSWORD", "") or "".
        password = self.cfg("WIFI_PASSWORD", "") or ""
        # Variable: ap_ssid stores the combined condition self.cfg("AP_SSID", "RinaChanBoard-ESP32S3") or "RinaChanBoard-ESP32S3".
        ap_ssid = self.cfg("AP_SSID", "RinaChanBoard-ESP32S3") or "RinaChanBoard-ESP32S3"
        # Variable: ap_password stores the combined condition self.cfg("AP_PASSWORD", "") or "".
        ap_password = self.cfg("AP_PASSWORD", "") or ""
        # Variable: ap_channel stores the result returned by int().
        ap_channel = int(self.cfg("AP_CHANNEL", 6) or 6)
        # Variable: ap_authmode stores the result returned by int().
        ap_authmode = int(self.cfg("AP_AUTHMODE", 0) or 0)

        # If no AP password was configured, keep the field user-empty in
        # wifi_config.py but run a WPA2 fallback at runtime for phone support.
        # Logic: Branches when not ap_password so the correct firmware path runs.
        if not ap_password:
            # Variable: ap_password stores the referenced self._AP_DEFAULT_PASSWORD value.
            ap_password = self._AP_DEFAULT_PASSWORD
            # Variable: ap_authmode stores the configured literal value.
            ap_authmode = 3  # WPA2-PSK

        # Expression: Calls gc.collect() for its side effects.
        gc.collect()  # defragment heap before Wi-Fi stack allocation
        # Variable: self.ap stores the result returned by network.WLAN().
        self.ap = network.WLAN(network.AP_IF)
        # Expression: Calls self.ap.active() for its side effects.
        self.ap.active(True)

        # Keep the AP subnet fixed. This stabilizes DHCP/captive-portal probes.
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls self.ap.ifconfig() for its side effects.
            self.ap.ifconfig(("192.168.4.1", "255.255.255.0", "192.168.4.1", "8.8.8.8"))
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass

        # Safety rule: do not call AP_IF.config(pm=...) and do not force
        # active(False)->active(True) on ESP32-S3 MicroPython/ESP-IDF builds.
        # Some builds hard-crash in the Wi-Fi driver before Python can catch it.
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls self.ap.config() for its side effects.
            self.ap.config(essid=ap_ssid, password=ap_password,
                           channel=ap_channel, authmode=ap_authmode)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.ap.config() for its side effects.
                self.ap.config(essid=ap_ssid)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass

        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: self.ap_ip stores the selected item self.ap.ifconfig()[0].
            self.ap_ip = self.ap.ifconfig()[0]
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: self.ap_ip stores the configured text value.
            self.ap_ip = "192.168.4.1"
        # Variable: self.ssid_label stores the current ap_ssid value.
        self.ssid_label = ap_ssid
        # Expression: Calls self._remember() for its side effects.
        self._remember("[WIFI]", "AP ssid={} pw={} ip={}".format(
            ap_ssid, ap_password, self.ap_ip))

        # Variable: self.sta stores the result returned by network.WLAN().
        self.sta = network.WLAN(network.STA_IF)
        # Logic: Branches when ssid so the correct firmware path runs.
        if ssid:
            # Expression: Calls self._start_sta() for its side effects.
            self._start_sta(ssid, password)
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.sta.active() for its side effects.
                self.sta.active(False)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass
            # Expression: Calls self._remember() for its side effects.
            self._remember("[WIFI]", "STA disabled; edit wifi_config.py to join router Wi-Fi")
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True

    # Function: Defines _start_sta(self, ssid, password) to handle start sta behavior.
    def _start_sta(self, ssid, password):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls self.sta.active() for its side effects.
            self.sta.active(True)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls self.sta.config() for its side effects.
            self.sta.config(dhcp_hostname="RinaChanBoard")
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass
        # Expression: Calls self._remember() for its side effects.
        self._remember("[WIFI]", "STA connecting ssid={}".format(ssid))
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Expression: Calls self.sta.connect() for its side effects.
            self.sta.connect(ssid, password)
            # Variable: deadline stores the calculated expression _ticks_ms() + 15000.
            deadline = _ticks_ms() + 15000
            # Loop: Repeats while (not self.sta.isconnected()) and (_ticks_ms() < deadline) remains true.
            while (not self.sta.isconnected()) and (_ticks_ms() < deadline):
                # Expression: Evaluates this expression for its effect in the current scope.
                time.sleep_ms(100) if hasattr(time, "sleep_ms") else time.sleep(0.1)
            # Logic: Branches when self.sta.isconnected() so the correct firmware path runs.
            if self.sta.isconnected():
                # Variable: self.sta_ip stores the selected item self.sta.ifconfig()[0].
                self.sta_ip = self.sta.ifconfig()[0]
                # Variable: self.sta_ssid stores the current ssid value.
                self.sta_ssid = ssid
                # Expression: Calls self._remember() for its side effects.
                self._remember("[WIFI]", "STA connected ip={}".format(self.sta_ip))
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self._remember() for its side effects.
                self._remember("[WIFI]", "STA connect timeout; AP remains active")
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Expression: Calls self._remember() for its side effects.
            self._remember("[WIFI]", "STA connect failed: {}".format(exc))

    # Function: Defines get_ip(self) to handle get ip behavior.
    def get_ip(self):
        # Return: Sends the combined condition self.sta_ip or self.ap_ip back to the caller.
        return self.sta_ip or self.ap_ip

    # Function: Defines get_ssid(self) to handle get ssid behavior.
    def get_ssid(self):
        # Return: Sends the combined condition self.sta_ssid or self.ssid_label back to the caller.
        return self.sta_ssid or self.ssid_label

    # Function: Defines _sta_connected(self) to handle sta connected behavior.
    def _sta_connected(self):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Return: Sends the result returned by bool() back to the caller.
            return bool(self.sta is not None and self.sta.isconnected())
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False

    # Function: Defines values(self) to handle values behavior.
    def values(self):
        # Variable: sta_connected stores the result returned by self._sta_connected().
        sta_connected = self._sta_connected()
        # Variable: sta_ip stores the configured text value.
        sta_ip = ""
        # Variable: sta_status_code stores the configured literal value.
        sta_status_code = 0
        # Variable: rssi stores the configured literal value.
        rssi = 0
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Logic: Branches when self.sta is not None so the correct firmware path runs.
            if self.sta is not None:
                # Variable: sta_status_code stores the result returned by int().
                sta_status_code = int(self.sta.status())
                # Logic: Branches when sta_connected so the correct firmware path runs.
                if sta_connected:
                    # Variable: sta_ip stores the selected item self.sta.ifconfig()[0].
                    sta_ip = self.sta.ifconfig()[0]
                    # Variable: self.sta_ip stores the current sta_ip value.
                    self.sta_ip = sta_ip
                    # Error handling: Attempts the protected operation so failures can be handled safely.
                    try:
                        # Variable: rssi stores the result returned by int().
                        rssi = int(self.sta.status('rssi'))
                    # Error handling: Runs this recovery branch when the protected operation fails.
                    except Exception:
                        # Variable: rssi stores the configured literal value.
                        rssi = 0
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass
        # Variable: ap_ip stores the combined condition self.ap_ip or "".
        ap_ip = self.ap_ip or ""
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Logic: Branches when self.ap is not None so the correct firmware path runs.
            if self.ap is not None:
                # Variable: ap_ip stores the selected item self.ap.ifconfig()[0].
                ap_ip = self.ap.ifconfig()[0]
                # Variable: self.ap_ip stores the current ap_ip value.
                self.ap_ip = ap_ip
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Control: Leaves this branch intentionally empty.
            pass
        # Variable: ap_ssid_cfg stores the combined condition self.cfg("AP_SSID", "RinaChanBoard-ESP32S3") or "RinaChanBoard-ESP32S3".
        ap_ssid_cfg = self.cfg("AP_SSID", "RinaChanBoard-ESP32S3") or "RinaChanBoard-ESP32S3"
        # Variable: sta_ssid_cfg stores the combined condition self.cfg("WIFI_SSID", "") or "".
        sta_ssid_cfg = self.cfg("WIFI_SSID", "") or ""
        # Return: Sends the lookup table used by this module back to the caller.
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

    # Function: Defines wifi_status_json(self, client_addr) to handle wifi status json behavior.
    def wifi_status_json(self, client_addr=None):
        # Variable: v stores the result returned by self.values().
        v = self.values()
        # Variable: remote_ip stores the configured text value.
        remote_ip = ""
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: remote_ip stores the selected item client_addr[0].
            remote_ip = client_addr[0]
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: remote_ip stores the configured text value.
            remote_ip = ""
        # Variable: can_configure stores the combined condition remote_ip.startswith("192.168.4.") or remote_ip in ("127.0.0.1", "").
        can_configure = remote_ip.startswith("192.168.4.") or remote_ip in ("127.0.0.1", "")
        # Return: Sends the calculated expression "{" "\"ok\":true," "\"can_configure\":" + ("true" if can_configure else "false") + ",... back to the caller.
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

    # Function: Defines scan_json(self) to handle scan json behavior.
    def scan_json(self):
        # Variable: nets stores the collection of values used later in this module.
        nets = []
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Logic: Branches when self.sta is None so the correct firmware path runs.
            if self.sta is None:
                # Variable: self.sta stores the result returned by network.WLAN().
                self.sta = network.WLAN(network.STA_IF)
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.sta.active() for its side effects.
                self.sta.active(True)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass
            # Variable: raw stores the result returned by self.sta.scan().
            raw = self.sta.scan()
            # Loop: Iterates item over raw so each item can be processed.
            for item in raw:
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Variable: ssid stores the selected item item[0].
                    ssid = item[0]
                    # Logic: Branches when isinstance(ssid, bytes) so the correct firmware path runs.
                    if isinstance(ssid, bytes):
                        # Variable: ssid stores the result returned by ssid.decode().
                        ssid = ssid.decode("utf-8", "replace")
                    # Variable: channel stores the result returned by int().
                    channel = int(item[2])
                    # Variable: rssi stores the result returned by int().
                    rssi = int(item[3])
                    # Variable: auth stores the result returned by int().
                    auth = int(item[4])
                    # Variable: hidden stores the conditional expression int(item[5]) if len(item) > 5 else 0.
                    hidden = int(item[5]) if len(item) > 5 else 0
                    # Logic: Branches when ssid so the correct firmware path runs.
                    if ssid:
                        # Expression: Calls nets.append() for its side effects.
                        nets.append((rssi, ssid, channel, auth, hidden))
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception:
                    # Control: Leaves this branch intentionally empty.
                    pass
            # Expression: Calls nets.sort() for its side effects.
            nets.sort(reverse=True)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Expression: Calls print() for its side effects.
            print("!!! [API Crash] Wi-Fi 扫描失败: {}".format(exc))
        # Variable: parts stores the collection of values used later in this module.
        parts = []
        # Loop: Iterates rssi, ssid, channel, auth, hidden over nets[:20] so each item can be processed.
        for rssi, ssid, channel, auth, hidden in nets[:20]:
            # Expression: Calls parts.append() for its side effects.
            parts.append("{\"ssid\":\"" + _json_escape(ssid) + "\",\"rssi\":" + str(rssi) + ",\"channel\":" + str(channel) + ",\"auth\":" + str(auth) + ",\"hidden\":" + str(hidden) + "}")
        # Return: Sends the calculated expression "{\"ok\":true,\"networks\":[" + ",".join(parts) + "]}" back to the caller.
        return "{\"ok\":true,\"networks\":[" + ",".join(parts) + "]}"

    # Function: Defines _py_string(self, value) to handle py string behavior.
    def _py_string(self, value):
        # Return: Sends the result returned by repr() back to the caller.
        return repr(_safe_str(value))

    # Function: Defines save_config_json(self, args, udp_port) to handle save config json behavior.
    def save_config_json(self, args, udp_port=LOCAL_UDP_PORT):
        # Variable: ssid stores the result returned by _safe_str.strip().
        ssid = _safe_str(args.get("ssid", "")).strip()
        # Variable: password stores the result returned by _safe_str().
        password = _safe_str(args.get("password", ""))
        # Variable: ap_ssid stores the combined condition _safe_str(args.get("ap_ssid", "RinaChanBoard-ESP32S3")).strip() or "RinaChanBoard-ESP....
        ap_ssid = _safe_str(args.get("ap_ssid", "RinaChanBoard-ESP32S3")).strip() or "RinaChanBoard-ESP32S3"
        # Variable: ap_password stores the result returned by _safe_str().
        ap_password = _safe_str(args.get("ap_password", ""))
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: ap_channel stores the result returned by int().
            ap_channel = int(args.get("ap_channel", "6") or 6)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: ap_channel stores the configured literal value.
            ap_channel = 6
        # Logic: Branches when ap_channel < 1 so the correct firmware path runs.
        if ap_channel < 1:
            # Variable: ap_channel stores the configured literal value.
            ap_channel = 1
        # Logic: Branches when ap_channel > 13 so the correct firmware path runs.
        if ap_channel > 13:
            # Variable: ap_channel stores the configured literal value.
            ap_channel = 13
        # Variable: ap_authmode stores the conditional expression 3 if ap_password else 0.
        ap_authmode = 3 if ap_password else 0
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Resource: Opens managed resources for this block and releases them automatically.
            with open("wifi_config.py", "w") as f:
                # Expression: Calls f.write() for its side effects.
                f.write("# Auto-generated by RinaChanBoard WebUI.\n")
                # Expression: Calls f.write() for its side effects.
                f.write("WIFI_SSID = {}\n".format(self._py_string(ssid)))
                # Expression: Calls f.write() for its side effects.
                f.write("WIFI_PASSWORD = {}\n".format(self._py_string(password)))
                # Expression: Calls f.write() for its side effects.
                f.write("AP_SSID = {}\n".format(self._py_string(ap_ssid)))
                # Expression: Calls f.write() for its side effects.
                f.write("AP_PASSWORD = {}\n".format(self._py_string(ap_password)))
                # Expression: Calls f.write() for its side effects.
                f.write("AP_CHANNEL = {}\n".format(int(ap_channel)))
                # Expression: Calls f.write() for its side effects.
                f.write("AP_AUTHMODE = {}\n".format(int(ap_authmode)))
                # Expression: Calls f.write() for its side effects.
                f.write("HTTP_PORT = 80\n")
                # Expression: Calls f.write() for its side effects.
                f.write("UDP_PORT = {}\n".format(int(udp_port or LOCAL_UDP_PORT)))
            # Return: Sends the collection of values used later in this module back to the caller.
            return True, "{\"ok\":true,\"message\":\"Wi-Fi 配置已保存，设备即将重启。\"}", True
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Expression: Calls print() for its side effects.
            print("!!! [API Crash] 保存 Wi-Fi 配置失败: {}".format(exc))
            # Return: Sends the collection of values used later in this module back to the caller.
            return False, "{\"ok\":false,\"error\":\"" + _json_escape(exc) + "\"}", False
