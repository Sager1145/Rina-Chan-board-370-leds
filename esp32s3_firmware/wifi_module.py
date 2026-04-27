# ---------------------------------------------------------------------------
# wifi_module.py
#
# Wi-Fi / UDP / HTTP polling integration module.
# ---------------------------------------------------------------------------

# Import: Loads REMOTE_UDP_PORT from rina_protocol so this module can use that dependency.
from rina_protocol import REMOTE_UDP_PORT

# Import: Loads AppModule from app_module_base so this module can use that dependency.
from app_module_base import AppModule


# Class: Defines WiFiModule as the state and behavior container for Wi Fi Module.
class WiFiModule(AppModule):

    # Function: Defines attach_network(self, link, proto) to handle attach network behavior.
    def attach_network(self, link, proto):
        # Variable: self.link stores the current link value.
        self.link = link
        # Variable: self.proto stores the current proto value.
        self.proto = proto
        # Function: Defines _poll() to handle poll behavior.
        def _poll():
            # Service both HTTP API requests and UDP packets from the native
            # ESP32-S3 network layer. Limit the number of packets per loop so
            # LED animation timing still gets CPU time.
            # Loop: Iterates _ over range(4) so each item can be processed.
            for _ in range(4):
                # Variable: pkt stores the result returned by link.get_packet().
                pkt = link.get_packet()
                # Logic: Branches when pkt is None so the correct firmware path runs.
                if pkt is None:
                    # Return: Sends control back to the caller.
                    return
                # Variable: link_id, remote_ip, remote_port, payload stores the current pkt value.
                link_id, remote_ip, remote_port, payload = pkt
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Expression: Calls proto.handle_packet() for its side effects.
                    proto.handle_packet(payload, remote_ip, remote_port, link_id)
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception as exc:
                    # Expression: Calls print() for its side effects.
                    print("packet error:", exc)
                    # Error handling: Attempts the protected operation so failures can be handled safely.
                    try:
                        # Expression: Calls proto.send() for its side effects.
                        proto.send(remote_ip, REMOTE_UDP_PORT, b"Command Error!", link_id)
                    # Error handling: Runs this recovery branch when the protected operation fails.
                    except Exception as send_exc:
                        # Expression: Calls print() for its side effects.
                        print("send error:", send_exc)
        # Variable: self.network_poll stores the current _poll value.
        self.network_poll = _poll

    # Function: Defines service_network(self) to handle service network behavior.
    def service_network(self):
        # Logic: Branches when self.network_poll is not None so the correct firmware path runs.
        if self.network_poll is not None:
            # Expression: Calls self.network_poll() for its side effects.
            self.network_poll()

    # Function: Defines on_network_control(self) to handle on network control behavior.
    def on_network_control(self):
        # Expression: Calls self.exit_manual_control_from_network() for its side effects.
        self.exit_manual_control_from_network("network control")
        # Expression: Calls self.stop_webui_runtime() for its side effects.
        self.stop_webui_runtime(redraw=False)
        # Variable: self.button_face_active stores the enabled/disabled flag value.
        self.button_face_active = False
        # Expression: Calls self.force_m_mode() for its side effects.
        self.force_m_mode("network/WebUI control", persist=True)
        # Variable: self.state.flash_active stores the enabled/disabled flag value.
        self.state.flash_active = False
        # Variable: self.state.edge_flash_active stores the enabled/disabled flag value.
        self.state.edge_flash_active = False
        # Variable: self.state.battery_display_active stores the enabled/disabled flag value.
        self.state.battery_display_active = False
        # Variable: self.state.battery_display_single_shot stores the enabled/disabled flag value.
        self.state.battery_display_single_shot = False
        # Variable: self.state.ip_display_active stores the enabled/disabled flag value.
        self.state.ip_display_active = False
        # Variable: self.state.b6_pending stores the enabled/disabled flag value.
        self.state.b6_pending = False
        # Variable: self.state.b6_long_fired stores the enabled/disabled flag value.
        self.state.b6_long_fired = False
