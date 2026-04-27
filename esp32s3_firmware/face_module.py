# ---------------------------------------------------------------------------
# face_module.py
#
# Saved-face selection and drawing module.
# ---------------------------------------------------------------------------

# Import: Loads board so this module can use that dependency.
import board
# Import: Loads clear, show from board so this module can use that dependency.
from board import clear, show

# Import: Loads saved_faces_370 so this module can use that dependency.
import saved_faces_370

# Import: Loads AppModule from app_module_base so this module can use that dependency.
from app_module_base import AppModule


# Class: Defines FaceModule as the state and behavior container for Face Module.
class FaceModule(AppModule):

    # Function: Defines draw_current_face(self) to handle draw current face behavior.
    def draw_current_face(self):
        # Button B1/B2 and A/M auto/manual now use the shared saved-custom-face
        # list.  The list is seeded with every face from the original Python
        # demo_faces.py file and can be extended by WebUI save operations.
        # Variable: face stores the result returned by saved_faces_370.get().
        face = saved_faces_370.get(self.state.face_idx)
        # Variable: face_hex stores the result returned by face.get().
        face_hex = face.get("hex", "")
        # Logic: Branches when self.proto is not None and hasattr(self.proto, "update_physical_face_hex") so the correct firmware path runs.
        if self.proto is not None and hasattr(self.proto, "update_physical_face_hex"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.proto.update_physical_face_hex() for its side effects.
                self.proto.update_physical_face_hex(face_hex, notify=False)
                # Variable: self.button_face_active stores the enabled/disabled flag value.
                self.button_face_active = True
                # Return: Sends control back to the caller.
                return
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("saved face draw via protocol failed:", exc)

        # Fallback for very early boot if protocol is unavailable.
        # Do not load the old demo face module in the normal boot path; this firmware build
        # uses saved_faces_370 as the only face source to save RP2040 heap.
        # Expression: Calls clear() for its side effects.
        clear()
        # Expression: Calls show() for its side effects.
        show()
        # Variable: self.button_face_active stores the enabled/disabled flag value.
        self.button_face_active = True

    # Function: Defines render_current_visual(self, force) to handle render current visual behavior.
    def render_current_visual(self, force=False):
        # Expression: Calls self.draw_current_face() for its side effects.
        self.draw_current_face()

    # ------------------------------------------------------------------
    # Flash / overlay rendering
    # ------------------------------------------------------------------

    # Function: Defines cycle_face(self, delta) to handle cycle face behavior.
    def cycle_face(self, delta):
        # Expression: Calls self.stop_webui_runtime() for its side effects.
        self.stop_webui_runtime(redraw=False)
        # Variable: self.state.face_idx stores the calculated expression (self.state.face_idx + delta) % max(1, saved_faces_370.count()).
        self.state.face_idx = (self.state.face_idx + delta) % max(1, saved_faces_370.count())
        # Expression: Calls self.stop_battery_display() for its side effects.
        self.stop_battery_display()
        # Expression: Calls self.cancel_flash_and_redraw() for its side effects.
        self.cancel_flash_and_redraw()

    # Function: Defines select_saved_face(self, index, redraw) to handle select saved face behavior.
    def select_saved_face(self, index, redraw=True):
        # Expression: Calls self.exit_manual_control_from_network() for its side effects.
        self.exit_manual_control_from_network("selectFace370")
        # Expression: Calls self.stop_webui_runtime() for its side effects.
        self.stop_webui_runtime(redraw=False)
        # Expression: Calls self.force_m_mode() for its side effects.
        self.force_m_mode("selectFace370", persist=True)
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: idx stores the result returned by int().
            idx = int(index)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: idx stores the configured literal value.
            idx = 0
        # Variable: count stores the result returned by max().
        count = max(1, saved_faces_370.count())
        # Variable: self.state.face_idx stores the calculated expression idx % count.
        self.state.face_idx = idx % count
        # Expression: Calls self.stop_battery_display() for its side effects.
        self.stop_battery_display()
        # Logic: Branches when redraw so the correct firmware path runs.
        if redraw:
            # Expression: Calls self.draw_current_face() for its side effects.
            self.draw_current_face()
        # Return: Sends the result returned by saved_faces_370.get() back to the caller.
        return saved_faces_370.get(self.state.face_idx)

    # Function: Defines on_saved_faces_changed(self, selected_index, redraw) to handle on saved faces changed behavior.
    def on_saved_faces_changed(self, selected_index=None, redraw=False):
        # Variable: count stores the result returned by max().
        count = max(1, saved_faces_370.count())
        # Logic: Branches when selected_index is not None so the correct firmware path runs.
        if selected_index is not None:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: self.state.face_idx stores the calculated expression int(selected_index) % count.
                self.state.face_idx = int(selected_index) % count
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Variable: self.state.face_idx stores the configured literal value.
                self.state.face_idx = 0
        # Logic: Branches when self.state.face_idx >= count so the correct firmware path runs.
        elif self.state.face_idx >= count:
            # Variable: self.state.face_idx stores the calculated expression count - 1.
            self.state.face_idx = count - 1
        # Logic: Branches when redraw so the correct firmware path runs.
        if redraw:
            # Expression: Calls self.draw_current_face() for its side effects.
            self.draw_current_face()
        # Return: Sends the result returned by saved_faces_370.get() back to the caller.
        return saved_faces_370.get(self.state.face_idx)
