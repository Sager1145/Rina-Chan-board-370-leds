# ---------------------------------------------------------------------------
# wifi_module.py
#
# Wi-Fi / UDP / HTTP polling integration module.
# ---------------------------------------------------------------------------

from rina_protocol import REMOTE_UDP_PORT

from app_module_base import AppModule


class WiFiModule(AppModule):

    def attach_network(self, link, proto):
        self.link = link
        self.proto = proto
        def _poll():
            # Service both HTTP API requests and UDP packets from the native
            # ESP32-S3 network layer. Limit the number of packets per loop so
            # LED animation timing still gets CPU time.
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
        self.network_poll = _poll

    def service_network(self):
        if self.network_poll is not None:
            self.network_poll()

    def on_network_control(self):
        self.exit_manual_control_from_network("network control")
        self.stop_webui_runtime(redraw=False)
        self.button_face_active = False
        self.force_m_mode("network/WebUI control", persist=True)
        self.state.flash_active = False
        self.state.edge_flash_active = False
        self.state.battery_display_active = False
        self.state.battery_display_single_shot = False
        self.state.ip_display_active = False
        self.state.b6_pending = False
        self.state.b6_long_fired = False
