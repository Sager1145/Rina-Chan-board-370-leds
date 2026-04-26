# ---------------------------------------------------------------------------
# wifi_module.py
#
# WiFi network module.
# Wraps ESP32S3Network for WiFi connection, UDP/HTTP server, and packet
# routing to the protocol layer.
# ---------------------------------------------------------------------------

from esp32s3_network import ESP32S3Network
from rina_protocol import REMOTE_UDP_PORT


class WiFiModule:
    """WiFi connection, packet routing, and IP/SSID query."""

    __slots__ = ("link", "proto", "_poll_fn")

    def __init__(self, log_limit=160):
        self.link = ESP32S3Network(log_limit=log_limit)
        self.proto = None
        self._poll_fn = None

    def start(self):
        self.link.start()

    def ping(self):
        self.link.ping()

    # ------------------------------------------------------------------
    # Protocol attachment
    # ------------------------------------------------------------------
    def attach_protocol(self, proto):
        """Attach protocol handler and build the polling function."""
        self.proto = proto
        proto.set_sender(
            lambda ip, port, data, link_id=0: self.link.send_udp(data, ip, port, link_id)
        )
        proto.log_provider = self.link.recent_log
        link = self.link

        def _poll():
            for _ in range(4):
                pkt = link.get_packet()
                if pkt is None:
                    return
                link_id, remote_ip, remote_port, payload = pkt
                try:
                    proto.handle_packet(payload, remote_ip, remote_port, link_id)
                except Exception as exc:
                    print("packet error:", exc)
                    try:
                        proto.send(remote_ip, REMOTE_UDP_PORT, b"Command Error!", link_id)
                    except Exception as send_exc:
                        print("send error:", send_exc)

        self._poll_fn = _poll

    # ------------------------------------------------------------------
    # Service (called every tick from main loop)
    # ------------------------------------------------------------------
    def service(self):
        if self._poll_fn is not None:
            self._poll_fn()

    # ------------------------------------------------------------------
    # Query
    # ------------------------------------------------------------------
    def get_ip(self):
        try:
            return self.link.get_ip() if self.link is not None else None
        except Exception:
            return None

    def get_ssid(self):
        try:
            if self.link is not None and hasattr(self.link, "get_ssid"):
                return self.link.get_ssid()
        except Exception:
            pass
        return None
