# ---------------------------------------------------------------------------
# home_module.py
#
# Home / main control module.
# Manages flash overlays (interval/brightness/mode), edge flash animation,
# brightness control, A/M mode toggle, and manual control mode.
# Orchestrates interactions between modules.
# ---------------------------------------------------------------------------

import time
import board
import display_num
from board import (
    COLS, ROWS, logical_to_led_index, np, scale_color, show,
)
from config import (
    FLASH_HOLD_MS, EDGE_FLASH_ATTACK_MS, EDGE_FLASH_DECAY_MS,
    EDGE_FLASH_TOTAL_MS, EDGE_FLASH_COLOR,
    BRIGHTNESS_MIN, BRIGHTNESS_MAX, DEFAULT_BRIGHTNESS,
    INTERVAL_MIN_S, INTERVAL_MAX_S,
)
from brightness_modes import effective_brightness
from settings_store import clamp_interval, clamp_brightness, save_settings


class HomeModule:
    """Flash overlays, edge flash, brightness, A/M mode, manual control."""

    __slots__ = (
        "state", "battery_state", "color_module",
        "face_mod", "scroll_mod", "battery_mod", "unity_mod",
        "_save_settings_fn",
    )

    def __init__(self, state, battery_state, color_module):
        self.state = state
        self.battery_state = battery_state
        self.color_module = color_module
        # Module references (set during wiring)
        self.face_mod = None
        self.scroll_mod = None
        self.battery_mod = None
        self.unity_mod = None
        self._save_settings_fn = None

    def set_modules(self, face, scroll, battery, unity):
        self.face_mod = face
        self.scroll_mod = scroll
        self.battery_mod = battery
        self.unity_mod = unity

    def set_save_fn(self, fn):
        self._save_settings_fn = fn

    def _save(self):
        if self._save_settings_fn:
            self._save_settings_fn()

    # ------------------------------------------------------------------
    # Brightness
    # ------------------------------------------------------------------
    def apply_brightness(self):
        board.set_max_brightness(effective_brightness(
            self.state.brightness, badapple_mode=False, demo_mode=False,
        ))

    def sync_protocol_brightness(self, proto):
        """Keep web/API brightness in sync after hardware button changes."""
        if proto is not None and hasattr(proto, "bright"):
            try:
                proto.bright = int(effective_brightness(
                    self.state.brightness, badapple_mode=False, demo_mode=False
                ))
            except Exception as exc:
                print("brightness state sync failed:", exc)

    def adjust_brightness(self, delta, proto=None):
        old_val = self.state.brightness
        self.state.brightness = clamp_brightness(self.state.brightness + delta)
        self.apply_brightness()
        self.sync_protocol_brightness(proto)
        if self.state.brightness != old_val:
            self._save()
        if delta < 0 and self.state.brightness <= BRIGHTNESS_MIN:
            self.start_edge_flash("bottom")
        elif delta > 0 and self.state.brightness >= BRIGHTNESS_MAX:
            self.start_edge_flash("top")
        if self.battery_mod:
            self.battery_mod.stop()
        display_num.render_brightness_percent(self.state.brightness)
        self.overlay_edge_flash()
        self.start_or_extend_flash("brightness", self.state.brightness)

    def reset_brightness(self, proto=None):
        old_val = self.state.brightness
        self.state.brightness = DEFAULT_BRIGHTNESS
        self.apply_brightness()
        self.sync_protocol_brightness(proto)
        if self.state.brightness != old_val:
            self._save()
        if self.battery_mod:
            self.battery_mod.stop()
        display_num.render_brightness_percent(self.state.brightness)
        self.start_or_extend_flash("brightness", self.state.brightness)

    # ------------------------------------------------------------------
    # Interval
    # ------------------------------------------------------------------
    def adjust_interval(self, delta):
        self.state.special_demo_mode = False
        old_val = self.state.interval_s
        self.state.interval_s = clamp_interval(self.state.interval_s + delta)
        if self.state.interval_s != old_val:
            self._save()
        if delta < 0 and self.state.interval_s <= INTERVAL_MIN_S:
            self.start_edge_flash("bottom")
        elif delta > 0 and self.state.interval_s >= INTERVAL_MAX_S:
            self.start_edge_flash("top")
        if self.battery_mod:
            self.battery_mod.stop()
        display_num.render_interval(self.state.interval_s)
        self.start_or_extend_flash("interval", self.state.interval_s)
        self.overlay_edge_flash()

    # ------------------------------------------------------------------
    # A/M mode toggle
    # ------------------------------------------------------------------
    def toggle_auto(self):
        old_auto = bool(self.state.auto)
        self.enter_manual_control("button auto-toggle")
        self._stop_runtime_animations(redraw=False)
        self.state.special_demo_mode = False
        self.state.auto = not old_auto
        self._save()
        print("auto =", self.state.auto)
        if self.battery_mod:
            self.battery_mod.stop()
        display_num.render_mode(self.state.auto)
        self.start_or_extend_flash("mode", self.state.auto)

    # ------------------------------------------------------------------
    # Manual control mode
    # ------------------------------------------------------------------
    def force_m_mode(self, source="network", persist=True):
        """Force M mode without the big M overlay."""
        was_auto = bool(self.state.auto)
        self.state.auto = False
        if was_auto:
            print("auto = False (M mode)", source)
            if persist:
                self._save()
        return False

    def enter_manual_control(self, source="button"):
        """Physical button takes ownership."""
        self._stop_runtime_animations(redraw=False)
        self.state.special_demo_mode = False
        self.force_m_mode(source, persist=False)
        self.state.flash_active = False
        self.state.edge_flash_active = False
        if self.battery_mod:
            self.state.battery_display_active = False
            self.state.battery_display_single_shot = False
        self.state.ip_display_active = False
        self.state.b6_pending = False
        self.state.b6_long_fired = False
        self.state.manual_control_mode = True
        print("manual_control_mode = True", source)

    def exit_manual_control(self, source="network"):
        if self.state.manual_control_mode:
            print("manual_control_mode = False", source)
        self.state.manual_control_mode = False

    def on_network_control(self):
        """Network/WebUI takes control."""
        self.exit_manual_control("network control")
        self._stop_runtime_animations(redraw=False)
        if self.face_mod:
            self.face_mod.button_face_active = False
        self.state.special_demo_mode = False
        self.force_m_mode("network/WebUI control", persist=True)
        self.state.flash_active = False
        self.state.edge_flash_active = False
        self.state.battery_display_active = False
        self.state.battery_display_single_shot = False
        self.state.ip_display_active = False
        self.state.b6_pending = False
        self.state.b6_long_fired = False

    def manual_control_status_json(self):
        return ("{\"manual_control_mode\":" +
                ("true" if self.state.manual_control_mode else "false") +
                ",\"auto\":" +
                ("true" if self.state.auto else "false") + "}")

    def set_manual_control_mode(self, enabled, redraw=False, source=""):
        """Explicit manual control mode toggle (from WebUI)."""
        enabled = bool(enabled)
        if enabled:
            self.enter_manual_control(source or "manual control")
        self.state.manual_control_mode = enabled
        print("manual_control_mode =", enabled, source)
        if redraw and self.face_mod:
            self.face_mod.draw_current()
        return self.state.manual_control_mode

    # ------------------------------------------------------------------
    # Flash overlay
    # ------------------------------------------------------------------
    def start_or_extend_flash(self, kind=None, value=None):
        self.state.flash_active = True
        self.state.flash_kind = kind
        self.state.flash_value = value
        self.state.flash_expires_ms = time.ticks_add(time.ticks_ms(), FLASH_HOLD_MS)

    def end_flash_if_expired(self):
        if not self.state.flash_active:
            return False
        if time.ticks_diff(time.ticks_ms(), self.state.flash_expires_ms) >= 0:
            self.state.flash_active = False
            self.state.flash_kind = None
            self.state.flash_value = None
            if self.face_mod:
                self.face_mod.render_current_visual(force=True)
            return True
        return False

    def cancel_flash_and_redraw(self):
        self.state.flash_active = False
        self.state.flash_kind = None
        self.state.flash_value = None
        if self.face_mod:
            self.face_mod.render_current_visual(force=True)

    def render_flash_overlay_base(self):
        if self.state.flash_kind == "interval":
            display_num.render_interval(self.state.flash_value)
        elif self.state.flash_kind == "brightness":
            display_num.render_brightness_percent(self.state.flash_value)
        elif self.state.flash_kind == "mode":
            display_num.render_mode(self.state.flash_value)

    def render_flash_overlay_with_edge(self):
        if not self.state.flash_active:
            return
        self.render_flash_overlay_base()
        self.overlay_edge_flash()

    # ------------------------------------------------------------------
    # Edge flash animation
    # ------------------------------------------------------------------
    def start_edge_flash(self, edge):
        self.state.edge_flash_active = True
        self.state.edge_flash_edge = edge
        self.state.edge_flash_started_ms = time.ticks_ms()

    def edge_flash_factor(self, elapsed_ms):
        if elapsed_ms < 0 or elapsed_ms > EDGE_FLASH_TOTAL_MS:
            return 0.0
        if elapsed_ms <= EDGE_FLASH_ATTACK_MS:
            return elapsed_ms / float(EDGE_FLASH_ATTACK_MS)
        t = (elapsed_ms - EDGE_FLASH_ATTACK_MS) / float(EDGE_FLASH_DECAY_MS)
        return 1.0 - t

    def overlay_edge_flash(self):
        if not self.state.edge_flash_active:
            return False
        elapsed = time.ticks_diff(
            time.ticks_ms(), self.state.edge_flash_started_ms
        )
        factor = self.edge_flash_factor(elapsed)
        if factor <= 0.0:
            self.state.edge_flash_active = False
            return False
        y = 0 if self.state.edge_flash_edge == "top" else (ROWS - 1)
        center = (COLS - 1) / 2.0
        max_dist = center if center > 0 else 1.0
        for x in range(COLS):
            idx = logical_to_led_index(x, y)
            if idx is None:
                continue
            dist = abs(x - center)
            spatial = 1.0 - (dist / max_dist)
            if spatial < 0.20:
                spatial = 0.20
            level = factor * spatial
            if level <= 0.0:
                continue
            flash_color = EDGE_FLASH_COLOR
            if self.state.flash_kind == "interval":
                flash_color = display_num.MODE_COLOR
            np[idx] = scale_color((
                int(flash_color[0] * level),
                int(flash_color[1] * level),
                int(flash_color[2] * level),
            ))
        show()
        return True

    # ------------------------------------------------------------------
    # Protocol callbacks
    # ------------------------------------------------------------------
    def on_protocol_color_updated(self, color):
        """Called when protocol color changes. Redraw face if needed."""
        if (self.face_mod and self.face_mod.button_face_active and
                self.face_mod.proto is not None and
                getattr(self.face_mod.proto, "display_mode", "legacy") == "physical"):
            try:
                self.face_mod.draw_current()
            except Exception:
                pass

    def on_protocol_brightness_updated(self, bright):
        """Called when protocol brightness changes. Sync to board percent."""
        try:
            pct = int((int(bright) * 100 + 85) // 170)
        except Exception:
            return
        if pct < BRIGHTNESS_MIN:
            pct = BRIGHTNESS_MIN
        if pct > BRIGHTNESS_MAX:
            pct = BRIGHTNESS_MAX
        if self.state.brightness != pct:
            self.state.brightness = pct
            self.apply_brightness()
            self._save()

    # ------------------------------------------------------------------
    # Service (called from main loop for flash expiry / edge flash)
    # ------------------------------------------------------------------
    def service(self):
        """Service flash expiry and edge flash rendering."""
        if (not self.state.battery_display_active and
                not self.state.ip_display_active):
            self.end_flash_if_expired()
        if self.state.flash_active and self.state.edge_flash_active:
            self.render_flash_overlay_with_edge()
        elif self.state.edge_flash_active and not self.state.flash_active:
            self.state.edge_flash_active = False

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    def _stop_runtime_animations(self, redraw=False):
        """Stop both scroll and unity if active."""
        if self.scroll_mod:
            self.scroll_mod.stop(redraw=False)
        if self.unity_mod:
            self.unity_mod.stop(redraw=False)

    def stop_all_overlays(self):
        """Clear all overlays and redraw face (used by face cycling)."""
        if self.battery_mod:
            self.battery_mod.stop()
        self.cancel_flash_and_redraw()

    def prepare_for_runtime(self):
        """Clear overlays before a WebUI scroll/timeline starts."""
        self.exit_manual_control("webui runtime")
        self.state.special_demo_mode = False
        self.force_m_mode("webui runtime", persist=True)
        self.state.flash_active = False
        self.state.flash_kind = None
        self.state.flash_value = None
        self.state.edge_flash_active = False
        self.state.battery_display_active = False
        self.state.battery_display_single_shot = False
        self.state.ip_display_active = False
        self.state.b6_pending = False
        self.state.b6_long_fired = False
        if self.face_mod:
            self.face_mod.button_face_active = False
