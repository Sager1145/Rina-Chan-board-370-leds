# ---------------------------------------------------------------------------
# face_module.py
#
# Expression / face management module.
# Handles face cycling (prev/next), auto-rotation, drawing the current face
# to the LED matrix, and face selection from the saved-faces list.
# ---------------------------------------------------------------------------

import time
import saved_faces_370
import board


class FaceModule:
    """Manages saved-face display, cycling, and auto-rotation."""

    __slots__ = (
        "state", "proto", "button_face_active",
        "_on_stop_overlays",
    )

    def __init__(self, state):
        self.state = state
        self.proto = None
        self.button_face_active = False
        # Callback: called when a face action needs overlays cleared
        self._on_stop_overlays = None

    def set_protocol(self, proto):
        self.proto = proto

    # ------------------------------------------------------------------
    # Drawing
    # ------------------------------------------------------------------
    def draw_current(self):
        """Draw the face at state.face_idx using the protocol renderer."""
        face = saved_faces_370.get(self.state.face_idx)
        face_hex = face.get("hex", "")
        if self.proto is not None and hasattr(self.proto, "update_physical_face_hex"):
            try:
                self.proto.update_physical_face_hex(face_hex, notify=False)
                self.button_face_active = True
                return
            except Exception as exc:
                print("saved face draw via protocol failed:", exc)
        # Fallback: clear display
        board.clear()
        board.show()
        self.button_face_active = True

    def render_current_visual(self, force=False):
        """Re-render whatever should be on screen (currently just the face)."""
        self.draw_current()

    # ------------------------------------------------------------------
    # Cycling
    # ------------------------------------------------------------------
    def cycle(self, delta):
        """Cycle face index by delta (+1 or -1)."""
        self.state.face_idx = (
            (self.state.face_idx + delta) % max(1, saved_faces_370.count())
        )

    def cycle_and_draw(self, delta, stop_overlays=True):
        """Cycle and immediately draw. Optionally stop overlays first."""
        if stop_overlays and self._on_stop_overlays:
            self._on_stop_overlays()
        self.cycle(delta)
        self.draw_current()

    # ------------------------------------------------------------------
    # Selection (from network / WebUI)
    # ------------------------------------------------------------------
    def select(self, index, redraw=True):
        """Select a specific face by index. Returns the face dict."""
        try:
            idx = int(index)
        except Exception:
            idx = 0
        count = max(1, saved_faces_370.count())
        self.state.face_idx = idx % count
        if redraw:
            self.draw_current()
        return saved_faces_370.get(self.state.face_idx)

    def on_faces_changed(self, selected_index=None, redraw=False):
        """Called when the saved-face list is modified externally."""
        count = max(1, saved_faces_370.count())
        if selected_index is not None:
            try:
                self.state.face_idx = int(selected_index) % count
            except Exception:
                self.state.face_idx = 0
        elif self.state.face_idx >= count:
            self.state.face_idx = count - 1
        if redraw:
            self.draw_current()
        return saved_faces_370.get(self.state.face_idx)

    # ------------------------------------------------------------------
    # Auto-cycle service (called from main loop)
    # ------------------------------------------------------------------
    def service_auto_cycle(self, next_auto_ms):
        """If auto mode, cycle when interval expires. Returns new deadline or None."""
        if not self.state.auto:
            return None
        now = time.ticks_ms()
        if time.ticks_diff(now, next_auto_ms) >= 0:
            self.cycle(1)
            self.draw_current()
            return time.ticks_add(now, int(self.state.interval_s * 1000))
        return None

    # ------------------------------------------------------------------
    # Callback setters
    # ------------------------------------------------------------------
    def set_on_stop_overlays(self, callback):
        self._on_stop_overlays = callback
