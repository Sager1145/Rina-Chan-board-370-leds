# ---------------------------------------------------------------------------
# unity_module.py
#
# Firmware-side WebUI runtime bridge for scroll text and Unity timeline playback.
# ---------------------------------------------------------------------------

# Runtime implementation lives in webui_runtime.py.  This module keeps the
# public app callbacks grouped with the Unity/scroll runtime feature boundary.

from app_module_base import AppModule


class UnityModule(AppModule):

    def handle_webui_runtime_command(self, command):
        return self.web_runtime.handle_command(command)

    def stop_webui_runtime(self, redraw=True):
        try:
            return self.web_runtime.stop(redraw=redraw)
        except Exception as exc:
            print("webui runtime stop failed:", exc)
            return False

