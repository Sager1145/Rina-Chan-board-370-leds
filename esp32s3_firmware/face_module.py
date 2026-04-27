# ---------------------------------------------------------------------------
# face_module.py
#
# Saved-face selection and drawing module.
# ---------------------------------------------------------------------------

import board
from board import clear, show

import saved_faces_370

from app_module_base import AppModule


class FaceModule(AppModule):

    def draw_current_face(self):
        # Button B1/B2 and A/M auto/manual now use the shared saved-custom-face
        # list.  The list is seeded with every face from the original Python
        # demo_faces.py file and can be extended by WebUI save operations.
        face = saved_faces_370.get(self.state.face_idx)
        face_hex = face.get("hex", "")
        if self.proto is not None and hasattr(self.proto, "update_physical_face_hex"):
            try:
                self.proto.update_physical_face_hex(face_hex, notify=False)
                self.button_face_active = True
                return
            except Exception as exc:
                print("saved face draw via protocol failed:", exc)

        # Fallback for very early boot if protocol is unavailable.
        # Do not load the old demo face module in the normal boot path; this firmware build
        # uses saved_faces_370 as the only face source to save RP2040 heap.
        clear()
        show()
        self.button_face_active = True

    def render_current_visual(self, force=False):
        self.draw_current_face()

    # ------------------------------------------------------------------
    # Flash / overlay rendering
    # ------------------------------------------------------------------

    def cycle_face(self, delta):
        self.stop_webui_runtime(redraw=False)
        self.state.face_idx = (self.state.face_idx + delta) % max(1, saved_faces_370.count())
        self.stop_battery_display()
        self.cancel_flash_and_redraw()

    def select_saved_face(self, index, redraw=True):
        self.exit_manual_control_from_network("selectFace370")
        self.stop_webui_runtime(redraw=False)
        self.force_m_mode("selectFace370", persist=True)
        try:
            idx = int(index)
        except Exception:
            idx = 0
        count = max(1, saved_faces_370.count())
        self.state.face_idx = idx % count
        self.stop_battery_display()
        if redraw:
            self.draw_current_face()
        return saved_faces_370.get(self.state.face_idx)

    def on_saved_faces_changed(self, selected_index=None, redraw=False):
        count = max(1, saved_faces_370.count())
        if selected_index is not None:
            try:
                self.state.face_idx = int(selected_index) % count
            except Exception:
                self.state.face_idx = 0
        elif self.state.face_idx >= count:
            self.state.face_idx = count - 1
        if redraw:
            self.draw_current_face()
        return saved_faces_370.get(self.state.face_idx)
