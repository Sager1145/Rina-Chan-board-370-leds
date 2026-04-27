# ---------------------------------------------------------------------------
# unity_module.py
#
# Firmware-side WebUI runtime bridge for scroll text and Unity timeline playback.
# ---------------------------------------------------------------------------

# Runtime implementation lives in webui_runtime.py.  This module keeps the
# public app callbacks grouped with the Unity/scroll runtime feature boundary.

# Import: Loads AppModule from app_module_base so this module can use that dependency.
from app_module_base import AppModule


# Class: Defines UnityModule as the state and behavior container for Unity Module.
class UnityModule(AppModule):

    # Function: Defines handle_webui_runtime_command(self, command) to handle handle webui runtime command behavior.
    def handle_webui_runtime_command(self, command):
        # Return: Sends the result returned by self.web_runtime.handle_command() back to the caller.
        return self.web_runtime.handle_command(command)

    # Function: Defines stop_webui_runtime(self, redraw) to handle stop webui runtime behavior.
    def stop_webui_runtime(self, redraw=True):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Return: Sends the result returned by self.web_runtime.stop() back to the caller.
            return self.web_runtime.stop(redraw=redraw)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Expression: Calls print() for its side effects.
            print("webui runtime stop failed:", exc)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False

