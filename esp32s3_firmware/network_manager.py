import time
try:
    import network
except Exception:
    network = None

from config import (
    AP_AUTHMODE, AP_CHANNEL, AP_HIDDEN, AP_MAX_CLIENTS, AP_COUNTRY,
    AP_IP, AP_NETMASK, AP_GATEWAY, AP_DNS,
    AP_START_RETRIES, AP_START_WAIT_MS, AP_RESTART_DELAY_MS,
)
try:
    from config import AP_COMPAT_OPEN as CONFIG_AP_COMPAT_OPEN
except Exception:
    CONFIG_AP_COMPAT_OPEN = True
import logger as log
try:
    import wifi_config
except Exception:
    wifi_config = None


class NetworkManager:
    def __init__(self):
        self.sta = None
        self.ap = None
        self.ip = '0.0.0.0'
        self.ssid = ''
        self.mode = 'none'
        self.ap_open = False
        log.debug('NET', 'manager created')

    def _get_wifi_setting(self, name, default):
        if wifi_config is not None:
            try:
                return getattr(wifi_config, name, default)
            except Exception:
                return default
        return default

    def _sleep_ms(self, ms):
        try:
            time.sleep_ms(int(ms))
        except Exception:
            time.sleep(float(ms) / 1000.0)

    def begin(self):
        if network is None:
            log.error('NET', 'network module unavailable')
            return False

        sta_ssid = self._get_wifi_setting('STA_SSID', '') or ''
        sta_pass = self._get_wifi_setting('STA_PASSWORD', '') or ''
        ap_ssid = self._get_wifi_setting('AP_SSID', 'RINA-S3') or 'RINA-S3'
        ap_pass = self._get_wifi_setting('AP_PASSWORD', '12345678') or ''
        ap_open = bool(self._get_wifi_setting('AP_COMPAT_OPEN', CONFIG_AP_COMPAT_OPEN))
        ap_channel = int(self._get_wifi_setting('AP_CHANNEL', AP_CHANNEL) or AP_CHANNEL)
        ap_country = self._get_wifi_setting('AP_COUNTRY', AP_COUNTRY) or AP_COUNTRY
        ap_hidden = bool(self._get_wifi_setting('AP_HIDDEN', AP_HIDDEN))
        ap_max_clients = int(self._get_wifi_setting('AP_MAX_CLIENTS', AP_MAX_CLIENTS) or AP_MAX_CLIENTS)

        log.info('NET', 'begin', sta_enabled=bool(sta_ssid), ap_ssid=ap_ssid, ap_open=ap_open, channel=ap_channel, country=ap_country)
        try:
            if hasattr(network, 'country') and ap_country:
                network.country(str(ap_country))
                log.info('NET', 'wifi country set', country=ap_country)
        except Exception as e:
            log.warn('NET', 'wifi country set failed', country=ap_country, err=e)

        # In AP-only mode, keep STA disabled. On ESP32-S3 this improves soft-AP
        # stability and avoids scan/connect activity interfering with phone join.
        self.sta = network.WLAN(network.STA_IF)
        if sta_ssid:
            self.sta.active(True)
            try:
                log.info('NET', 'STA connecting', ssid=sta_ssid)
                self.sta.connect(sta_ssid, sta_pass)
                start = time.ticks_ms()
                last_report = start
                while not self.sta.isconnected() and time.ticks_diff(time.ticks_ms(), start) < 8000:
                    now = time.ticks_ms()
                    if time.ticks_diff(now, last_report) >= 1000:
                        last_report = now
                        try:
                            status = self.sta.status()
                        except Exception:
                            status = 'unknown'
                        log.debug('NET', 'STA waiting', ssid=sta_ssid, status=status, elapsed_ms=time.ticks_diff(now, start))
                    self._sleep_ms(100)
            except Exception as e:
                log.exception('NET', 'STA connect failed', e)
        else:
            try:
                self.sta.active(False)
                log.info('NET', 'STA disabled for AP-only mode')
            except Exception as e:
                log.warn('NET', 'STA disable failed', err=e)

        if self.sta is not None and self.sta.isconnected():
            self.ip = self.sta.ifconfig()[0]
            self.ssid = sta_ssid
            self.mode = 'sta'
            self.ap_open = False
            log.info('NET', 'STA connected', ssid=sta_ssid, ip=self.ip, ifconfig=self.sta.ifconfig())
            return True

        log.warn('NET', 'STA not connected, starting AP')
        return self._start_ap(ap_ssid, ap_pass, ap_open, ap_channel, ap_hidden, ap_max_clients)

    def _try_config(self, kwargs, label):
        try:
            self.ap.config(**kwargs)
            log.info('NET', 'AP config ok', style=label, args=kwargs)
            return True
        except Exception as e:
            log.warn('NET', 'AP config failed', style=label, args=kwargs, err=e)
            return False

    def _start_ap(self, ap_ssid, ap_pass, ap_open, ap_channel, ap_hidden, ap_max_clients):
        self.ap = network.WLAN(network.AP_IF)
        for attempt in range(1, int(AP_START_RETRIES) + 1):
            log.info('NET', 'AP start attempt', attempt=attempt, ssid=ap_ssid, open=ap_open)
            try:
                self.ap.active(False)
                self._sleep_ms(AP_RESTART_DELAY_MS)
            except Exception as e:
                log.warn('NET', 'AP pre-disable failed', attempt=attempt, err=e)

            configured = False
            base = {
                'essid': ap_ssid,
                'channel': ap_channel,
                'hidden': ap_hidden,
                'max_clients': ap_max_clients,
            }
            # Configure before active(True) first. Some ESP32-S3 MicroPython
            # builds are more reliable when the SoftAP profile is complete
            # before the interface starts beaconing. If this path fails, the
            # post-active config below is still attempted.
            if ap_open:
                configured = self._try_config(dict(base, authmode=0), 'pre-open-authmode')
                if not configured:
                    configured = self._try_config(dict(base, security=0), 'pre-open-security')
            else:
                if len(ap_pass) < 8:
                    log.warn('NET', 'AP password too short for WPA; falling back open', password_len=len(ap_pass))
                    ap_open = True
                    configured = self._try_config(dict(base, authmode=0), 'pre-short-pass-open')
                else:
                    configured = self._try_config(dict(base, password=ap_pass, authmode=AP_AUTHMODE), 'pre-wpa-authmode')
                    if not configured:
                        configured = self._try_config(dict(base, password=ap_pass, security=AP_AUTHMODE), 'pre-wpa-security')

            try:
                self.ap.active(True)
            except Exception as e:
                log.exception('NET', 'AP active true failed', e)
                continue

            start = time.ticks_ms()
            while not self.ap.active() and time.ticks_diff(time.ticks_ms(), start) < int(AP_START_WAIT_MS):
                self._sleep_ms(50)
            log.debug('NET', 'AP active status', active=self.ap.active())

            if not configured:
                if ap_open:
                    configured = self._try_config(dict(base, authmode=0), 'post-open-authmode')
                    if not configured:
                        configured = self._try_config(dict(base, security=0), 'post-open-security')
                    if not configured:
                        configured = self._try_config({'essid': ap_ssid}, 'post-open-minimal')
                else:
                    configured = self._try_config(dict(base, password=ap_pass, authmode=AP_AUTHMODE), 'post-wpa-authmode')
                    if not configured:
                        configured = self._try_config(dict(base, password=ap_pass, security=AP_AUTHMODE), 'post-wpa-security')
                    if not configured:
                        configured = self._try_config({'essid': ap_ssid, 'password': ap_pass}, 'post-wpa-minimal')

            if not configured:
                log.error('NET', 'AP config failed all styles', attempt=attempt)
                continue

            try:
                self.ap.ifconfig((AP_IP, AP_NETMASK, AP_GATEWAY, AP_DNS))
                log.info('NET', 'AP static ifconfig ok', ifconfig=self.ap.ifconfig())
            except Exception as e:
                log.warn('NET', 'AP static ifconfig failed', err=e)

            self._sleep_ms(800)
            try:
                active = self.ap.active()
                cfg_essid = self.ap.config('essid')
                cfg_channel = self.ap.config('channel')
            except Exception as e:
                active = False
                cfg_essid = '<unknown>'
                cfg_channel = '<unknown>'
                log.warn('NET', 'AP readback failed', err=e)

            if active:
                try:
                    self.ip = self.ap.ifconfig()[0]
                except Exception:
                    self.ip = AP_IP
                self.ssid = ap_ssid
                self.mode = 'ap'
                self.ap_open = bool(ap_open)
                try:
                    ifconfig = self.ap.ifconfig()
                except Exception:
                    ifconfig = '<unknown>'
                log.info('NET', 'AP ready', ssid=self.ssid, ip=self.ip, open=self.ap_open, channel=cfg_channel, readback_essid=cfg_essid, ifconfig=ifconfig)
                log.info('NET', 'PHONE CONNECT INFO', ssid=self.ssid, password=('none/open' if self.ap_open else ap_pass), url='http://{}/'.format(self.ip))
                return True

        log.error('NET', 'AP failed after retries', retries=AP_START_RETRIES)
        return False

    def ap_stations(self):
        if self.ap is None:
            return []
        try:
            stations = self.ap.status('stations')
            out = []
            for st in stations or []:
                try:
                    mac = st[0] if isinstance(st, (tuple, list)) else st
                    if isinstance(mac, bytes):
                        mac_s = ':'.join('%02X' % b for b in mac)
                    else:
                        mac_s = str(mac)
                    out.append(mac_s)
                except Exception:
                    out.append(str(st))
            return out
        except Exception as e:
            return []

    def ap_station_count(self):
        try:
            return len(self.ap_stations())
        except Exception:
            return 0

    def label(self):
        label = '{} {}'.format(self.ssid or 'NO-WIFI', self.ip or '0.0.0.0')
        log.debug('NET', 'label', label=label)
        return label

    def status(self):
        info = {
            'mode': self.mode,
            'ssid': self.ssid,
            'ip': self.ip,
            'ap_open': self.ap_open,
        }
        try:
            if self.ap is not None:
                info['ap_active'] = self.ap.active()
                info['ap_ifconfig'] = self.ap.ifconfig()
                info['ap_stations'] = self.ap_stations()
                info['ap_station_count'] = len(info.get('ap_stations') or [])
        except Exception as e:
            info['ap_error'] = str(e)
        try:
            if self.sta is not None:
                info['sta_active'] = self.sta.active()
                info['sta_connected'] = self.sta.isconnected()
                info['sta_status'] = self.sta.status()
        except Exception as e:
            info['sta_error'] = str(e)
        return info

    def scan(self):
        if self.sta is None:
            log.warn('NET', 'scan requested before STA init')
            return []
        try:
            if not self.sta.active():
                self.sta.active(True)
                self._sleep_ms(200)
            log.info('NET', 'scan start')
            items = self.sta.scan()
            out = []
            for item in items:
                ssid = item[0].decode() if isinstance(item[0], bytes) else str(item[0])
                out.append({'ssid': ssid, 'rssi': item[3], 'auth': item[4]})
            out.sort(key=lambda x: x.get('rssi', -999), reverse=True)
            log.info('NET', 'scan done', count=len(out))
            return out
        except Exception as e:
            log.exception('NET', 'scan failed', e)
            return [{'error': str(e)}]
