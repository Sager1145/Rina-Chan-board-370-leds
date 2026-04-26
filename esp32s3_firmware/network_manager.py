import time
try:
    import network
except Exception:
    network = None
import config
import logger as log
try:
    import wifi_config
except Exception:
    wifi_config = None
AP_AUTHMODE = getattr(config, 'AP_AUTHMODE', 3)
AP_AUTHMODE_FALLBACKS = getattr(config, 'AP_AUTHMODE_FALLBACKS', (3, 4, 2))
AP_IP = getattr(config, 'AP_IP', '192.168.4.1')
AP_NETMASK = getattr(config, 'AP_NETMASK', '255.255.255.0')
AP_GATEWAY = getattr(config, 'AP_GATEWAY', AP_IP)
AP_DNS = getattr(config, 'AP_DNS', AP_IP)
AP_CHANNEL = getattr(config, 'AP_CHANNEL', 6)
AP_HIDDEN = getattr(config, 'AP_HIDDEN', False)
AP_MAX_CLIENTS = getattr(config, 'AP_MAX_CLIENTS', 4)
AP_COUNTRY = getattr(config, 'AP_COUNTRY', 'US')
AP_COMPAT_OPEN = getattr(config, 'AP_COMPAT_OPEN', False)
AP_ALWAYS_ON = getattr(config, 'AP_ALWAYS_ON', True)
AP_START_RETRIES = getattr(config, 'AP_START_RETRIES', 3)
AP_START_WAIT_MS = getattr(config, 'AP_START_WAIT_MS', 3000)
AP_RESTART_DELAY_MS = getattr(config, 'AP_RESTART_DELAY_MS', 600)
AP_STABILIZE_MS = getattr(config, 'AP_STABILIZE_MS', 900)
class NetworkManager:
    __slots__ = ('sta','ap','ip','ssid','mode','ap_open')
    def __init__(self):
        self.sta = None
        self.ap = None
        self.ip = '0.0.0.0'
        self.ssid = ''
        self.mode = 'none'
        self.ap_open = False
    def _wifi_setting(self, name, default):
        if wifi_config is None:
            return default
        try:
            return getattr(wifi_config, name, default)
        except Exception:
            return default
    def _sleep_ms(self, ms):
        try:
            time.sleep_ms(int(ms))
        except Exception:
            time.sleep(float(ms) / 1000.0)
    def _disable_power_save(self, wlan, label):
        try:
            ps_none = getattr(network, 'WIFI_PS_NONE', None)
            if ps_none is not None:
                wlan.config(pm=ps_none)
        except Exception as e:
            print(label, 'power-save config failed:', e)
    def _auth_modes(self, preferred):
        raw_modes = [preferred]
        fallbacks = self._wifi_setting('AP_AUTHMODE_FALLBACKS', AP_AUTHMODE_FALLBACKS)
        if isinstance(fallbacks, (list, tuple)):
            raw_modes.extend(fallbacks)
        else:
            raw_modes.append(fallbacks)
        modes = []
        for raw in raw_modes:
            try:
                mode = int(raw)
            except Exception:
                continue
            if mode not in modes:
                modes.append(mode)
        return modes or [3, 4, 2]
    def begin(self):
        if network is None:
            print('network module unavailable')
            return False
        sta_ssid = self._wifi_setting('STA_SSID', '') or ''
        sta_pass = self._wifi_setting('STA_PASSWORD', '') or ''
        ap_ssid = self._wifi_setting('AP_SSID', 'RinaChanBoard-S3') or 'RinaChanBoard-S3'
        ap_pass = self._wifi_setting('AP_PASSWORD', '12345678') or ''
        ap_authmode = int(self._wifi_setting('AP_AUTHMODE', AP_AUTHMODE) or AP_AUTHMODE)
        ap_open = bool(self._wifi_setting('AP_COMPAT_OPEN', AP_COMPAT_OPEN))
        ap_channel = int(self._wifi_setting('AP_CHANNEL', AP_CHANNEL) or AP_CHANNEL)
        ap_channel = max(1, min(11, ap_channel))
        ap_hidden = bool(self._wifi_setting('AP_HIDDEN', AP_HIDDEN))
        ap_max_clients = int(self._wifi_setting('AP_MAX_CLIENTS', AP_MAX_CLIENTS) or AP_MAX_CLIENTS)
        ap_country = self._wifi_setting('AP_COUNTRY', AP_COUNTRY) or AP_COUNTRY
        try:
            if hasattr(network, 'country') and ap_country:
                network.country(str(ap_country))
        except Exception as e:
            print('WiFi country set failed:', e)
        self.sta = network.WLAN(network.STA_IF)
        if sta_ssid:
            self.sta.active(True)
            self._disable_power_save(self.sta, 'STA')
            try:
                self.sta.connect(sta_ssid, sta_pass)
                start = time.ticks_ms()
                while not self.sta.isconnected() and time.ticks_diff(time.ticks_ms(), start) < 8000:
                    time.sleep_ms(100)
            except Exception as e:
                print('STA connect failed:', e)
        else:
            try:
                self.sta.active(False)
            except Exception as e:
                print('STA disable failed:', e)
        sta_connected = False
        if self.sta.isconnected():
            sta_connected = True
            sta_ip = self.sta.ifconfig()[0]
            self.ip = sta_ip
            self.ssid = sta_ssid
            self.mode = 'sta'
            print('WiFi STA connected:', sta_ssid, sta_ip)
            if AP_ALWAYS_ON:
                ap_ok = self._start_ap(ap_ssid, ap_pass, ap_open, ap_channel, ap_hidden, ap_max_clients, ap_authmode)
                self.ip = sta_ip
                self.ssid = sta_ssid
                self.mode = 'sta+ap' if ap_ok else 'sta'
                return True
            return True
        return self._start_ap(ap_ssid, ap_pass, ap_open, ap_channel, ap_hidden, ap_max_clients, ap_authmode)
    def _config_ap(self, ap_ssid, ap_pass, ap_open, ap_channel, ap_hidden, ap_max_clients, ap_authmode):
        full = {
            'essid': ap_ssid,
            'channel': ap_channel,
            'hidden': ap_hidden,
            'max_clients': ap_max_clients,
        }
        channel_only = {'essid': ap_ssid, 'channel': ap_channel}
        attempts = []
        if ap_open:
            attempts.append(dict(full, authmode=0))
            attempts.append(dict(channel_only, authmode=0))
            attempts.append({'essid': ap_ssid, 'authmode': 0})
            attempts.append({'essid': ap_ssid})
        else:
            attempts.append(dict(full, password=ap_pass, authmode=ap_authmode))
            attempts.append(dict(full, password=ap_pass, security=ap_authmode))
            attempts.append(dict(channel_only, password=ap_pass, authmode=ap_authmode))
            attempts.append(dict(channel_only, password=ap_pass, security=ap_authmode))
            attempts.append({'essid': ap_ssid, 'password': ap_pass, 'authmode': ap_authmode})
            attempts.append({'essid': ap_ssid, 'password': ap_pass, 'security': ap_authmode})
            attempts.append({'essid': ap_ssid, 'password': ap_pass})
        for kwargs in attempts:
            try:
                self.ap.config(**kwargs)
                return True
            except Exception as e:
                print('AP config style failed:', kwargs, e)
        return False
    def _start_ap(self, ap_ssid, ap_pass, ap_open, ap_channel, ap_hidden, ap_max_clients, ap_authmode):
        if (not ap_open) and len(ap_pass) < 8:
            print('AP password too short; using open AP')
            ap_open = True
        self.ap = network.WLAN(network.AP_IF)
        auth_modes = [0] if ap_open else self._auth_modes(ap_authmode)
        for authmode in auth_modes:
            for attempt in range(1, int(AP_START_RETRIES) + 1):
                security_label = 'open' if ap_open else 'auth{}'.format(authmode)
                print('WiFi AP start attempt:', attempt, ap_ssid, security_label, 'ch', ap_channel)
                try:
                    self.ap.active(False)
                    self._sleep_ms(AP_RESTART_DELAY_MS)
                except Exception as e:
                    print('AP pre-disable failed:', e)
                pre_configured = self._config_ap(ap_ssid, ap_pass, ap_open, ap_channel, ap_hidden, ap_max_clients, authmode)
                try:
                    self.ap.ifconfig((AP_IP, AP_NETMASK, AP_GATEWAY, AP_DNS))
                except Exception as e:
                    print('AP ifconfig before active failed:', e)
                try:
                    self.ap.active(True)
                    self._sleep_ms(150)
                    self._disable_power_save(self.ap, 'AP')
                except Exception as e:
                    print('AP active failed:', e)
                    continue
                post_configured = self._config_ap(ap_ssid, ap_pass, ap_open, ap_channel, ap_hidden, ap_max_clients, authmode)
                configured = bool(pre_configured or post_configured)
                try:
                    self.ap.ifconfig((AP_IP, AP_NETMASK, AP_GATEWAY, AP_DNS))
                except Exception as e:
                    print('AP ifconfig after active failed:', e)
                start = time.ticks_ms()
                while (not self.ap.active()) and time.ticks_diff(time.ticks_ms(), start) < int(AP_START_WAIT_MS):
                    self._sleep_ms(50)
                self._sleep_ms(AP_STABILIZE_MS)
                if self.ap.active() and configured:
                    self.ip = self.ap.ifconfig()[0]
                    self.ssid = ap_ssid
                    self.mode = 'ap'
                    self.ap_open = bool(ap_open)
                    print('WiFi AP active:', ap_ssid, self.ip, 'password:', ('open' if ap_open else ap_pass), 'channel:', ap_channel, 'auth:', ('open' if ap_open else authmode))
                    print('WiFi AP connect hint: forget old saved network with the same name; then connect to', ap_ssid, 'and open http://' + self.ip + '/')
                    return True
                print('WiFi AP inactive or unconfigured:', ap_ssid, 'active:', self.ap.active(), 'configured:', configured)
        print('WiFi AP failed')
        return False
    def label(self):
        return '{} {}'.format(self.ssid or 'NO-WIFI', self.ip or '0.0.0.0')
    def ap_station_count(self):
        if self.ap is None:
            return 0
        try:
            stations = self.ap.status('stations')
            return len(stations or [])
        except Exception:
            return 0
    def status(self):
        out = {'mode': self.mode, 'ssid': self.ssid, 'ip': self.ip, 'ap_open': self.ap_open}
        try:
            if self.ap is not None:
                out['ap_active'] = self.ap.active()
                out['ap_ifconfig'] = self.ap.ifconfig()
                try:
                    out['ap_ip'] = self.ap.ifconfig()[0]
                except Exception:
                    out['ap_ip'] = AP_IP
                out['ap_station_count'] = self.ap_station_count()
        except Exception as e:
            out['ap_error'] = str(e)
        try:
            if self.sta is not None:
                out['sta_active'] = self.sta.active()
                out['sta_connected'] = self.sta.isconnected()
                out['sta_status'] = self.sta.status()
                try:
                    out['sta_ip'] = self.sta.ifconfig()[0] if self.sta.isconnected() else ''
                except Exception:
                    out['sta_ip'] = ''
        except Exception as e:
            out['sta_error'] = str(e)
        return out
    def scan(self):
        if self.sta is None:
            log.warn('WIFI', 'scan skipped: STA object missing')
            return []
        try:
            log.info('WIFI', 'scan start', sta_active=self.sta.active())
            if not self.sta.active():
                self.sta.active(True)
                self._sleep_ms(350)
            try:
                import gc
                gc.collect()
            except Exception:
                pass
            items = self.sta.scan()
            out = []
            seen = set()
            for item in items:
                ssid = item[0].decode() if isinstance(item[0], bytes) else str(item[0])
                if not ssid:
                    continue
                key = ssid
                rssi = int(item[3]) if len(item) > 3 else -999
                auth = int(item[4]) if len(item) > 4 else 0
                channel = int(item[2]) if len(item) > 2 else 0
                if key in seen:
                    continue
                seen.add(key)
                out.append({'ssid': ssid, 'rssi': rssi, 'auth': auth, 'channel': channel})
            out.sort(key=lambda x: x.get('rssi', -999), reverse=True)
            log.info('WIFI', 'scan done', count=len(out))
            return out
        except Exception as e:
            log.exception('WIFI', 'scan failed', e)
            return [{'error': str(e)}]
