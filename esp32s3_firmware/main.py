import gc
import time
import ujson as json

import board
import logger as log
import display_num
import display_text
from battery import BatteryMonitor, battery_color
from buttons import ButtonBank
from config import *
from default_faces import DEFAULT_START_INDEX
from face_codec import normalize_bitmap, legacy_hex_to_bitmap, legacy_bits_to_grid, legacy_grid_to_bitmap
from face_parts import compose_part_bitmap
from network_manager import NetworkManager
from saved_faces import SavedFaceStore
from settings_store import load_settings, save_settings, clamp_brightness, clamp_interval
from protocol_server import ProtocolServer


def ticks_ms():
    return time.ticks_ms()


def add_ms(t, ms):
    return time.ticks_add(t, int(ms))


def diff_ms(a, b):
    return time.ticks_diff(a, b)


class RinaChanApp:
    def __init__(self):
        self.settings = load_settings()
        self.faces = SavedFaceStore()
        self.face_index = int(self.settings.get('face_index', DEFAULT_START_INDEX))
        if self.face_index < 0 or self.face_index >= self.faces.count():
            self.face_index = DEFAULT_START_INDEX if DEFAULT_START_INDEX < self.faces.count() else 0
        self.auto = bool(self.settings.get('auto', False))
        self.interval_s = clamp_interval(self.settings.get('interval_s', DEFAULT_INTERVAL_S))
        self.brightness = clamp_brightness(self.settings.get('brightness', DEFAULT_BRIGHTNESS))
        self.color = tuple(self.settings.get('color', PINK)) if isinstance(self.settings.get('color', None), list) else PINK
        self.dim_color = DIM
        self.manual_control_mode = bool(self.settings.get('manual_control_mode', False))
        self.control_mode = 'manual' if self.manual_control_mode else 'web'

        self.battery = BatteryMonitor(self.settings)
        self.buttons = ButtonBank()
        self.network = None
        self.server = None

        self.runtime_type = None
        self.runtime_name = ''
        self.runtime_started_ms = 0
        self.runtime_reason = ''
        self.scroll_text = ''
        self.scroll_speed_ms = 90
        self.scroll_x = COLS
        self.scroll_next_ms = 0

        self.timeline = {}
        self.timeline_fps = 30.0
        self.timeline_last_frame = 0
        self.timeline_loop = False
        self.timeline_expected_count = 0
        self.timeline_name = ''
        self.timeline_current_frame = 0

        self.next_auto_ms = add_ms(ticks_ms(), int(self.interval_s * 1000))
        self.flash_until_ms = 0
        self.flash_kind = None
        self.battery_overlay_active = False
        self.battery_overlay_single = False
        self.battery_overlay_until_ms = 0
        self.battery_overlay_next_phase_ms = 0
        self.battery_overlay_phase = 0
        self.battery_visual_next_ms = 0

        self.prev_b3_down = False
        self.prev_b6_down = False
        self.b3_consumed = False
        self.b6_pending = False
        self.b6_press_started_ms = 0
        self.b6_long_fired = False
        self.demo_combo_started_ms = None
        self.demo_combo_fired = False
        self.ip_combo_started_ms = None
        self.ip_combo_fired = False
        self.brightness_combo_latched = False
        self.last_heartbeat_ms = ticks_ms()
        self.settings_dirty = False
        self.settings_save_due_ms = 0
        self.settings_dirty_reason = ''
        self._servicing_buttons = False
        log.info('APP', 'constructed', version=VERSION, face_index=self.face_index, face_count=self.faces.count(), auto=self.auto, interval_s=self.interval_s, brightness=self.brightness, manual=self.manual_control_mode)

    # -------------------- persistence/state --------------------
    def save_runtime_settings(self, immediate=False, reason=''):
        # Flash writes are intentionally deferred by default.  Writing JSON to
        # flash during every button press makes the board feel frozen; the
        # visible action is now drawn first, then settings are committed shortly
        # after the user stops pressing buttons.
        if not immediate:
            self.mark_settings_dirty(reason or 'deferred')
            return
        data = {
            'face_index': self.face_index,
            'auto': self.auto,
            'interval_s': self.interval_s,
            'brightness': self.brightness,
            'manual_control_mode': self.manual_control_mode,
            'color': list(self.color),
        }
        data.update(self.battery.export_state())
        self.settings = data
        self.settings_dirty = False
        self.settings_save_due_ms = 0
        log.info('APP', 'save runtime settings', face_index=self.face_index, auto=self.auto, interval_s=self.interval_s, brightness=self.brightness, manual=self.manual_control_mode, reason=reason)
        save_settings(data)

    def mark_settings_dirty(self, reason=''):
        self.settings_dirty = True
        self.settings_dirty_reason = reason or self.settings_dirty_reason or 'state changed'
        self.settings_save_due_ms = add_ms(ticks_ms(), DEFERRED_SETTINGS_SAVE_MS)
        log.debug('APP', 'settings save deferred', reason=self.settings_dirty_reason, due_ms=DEFERRED_SETTINGS_SAVE_MS)

    def service_deferred_save(self):
        if not self.settings_dirty:
            return
        now = ticks_ms()
        if diff_ms(now, self.settings_save_due_ms) < 0:
            return
        # Do not block an active physical-button sequence with a flash write.
        if self.buttons.any_down():
            self.settings_save_due_ms = add_ms(now, DEFERRED_SETTINGS_SAVE_MS)
            return
        self.save_runtime_settings(immediate=True, reason=self.settings_dirty_reason)

    def apply_brightness(self):
        cap = board.brightness_percent_to_cap(self.brightness)
        log.info('APP', 'apply brightness', percent=self.brightness, cap=cap)
        board.set_max_brightness(cap)

    def state_json(self):
        return {
            'version': VERSION,
            'ip': self.network.ip if self.network else '0.0.0.0',
            'ssid': self.network.ssid if self.network else '',
            'network': self.network.status() if self.network else {},
            'face_index': self.face_index,
            'face_count': self.faces.count(),
            'auto': self.auto,
            'interval_s': self.interval_s,
            'brightness': self.brightness,
            'runtime': self.runtime_status_obj(),
            'manual_control_mode': self.manual_control_mode,
            'control_mode': 'manual' if self.manual_control_mode else 'web',
            'buttons': list(BUTTON_PINS),
        }

    def runtime_status_obj(self):
        return {
            'active': self.runtime_type is not None,
            'type': self.runtime_type or 'none',
            'name': self.runtime_name,
            'frame': self.timeline_current_frame if self.runtime_type == 'timeline' else None,
            'loaded_frames': len(self.timeline),
        }

    # -------------------- drawing --------------------
    def draw_saved_face(self, index=None):
        if index is not None:
            self.face_index = int(index) % max(1, self.faces.count())
        item = self.faces.get(self.face_index)
        if not item:
            log.warn('APP', 'draw saved face missing', index=self.face_index)
            board.clear(True)
            return
        log.info('APP', 'draw saved face', index=self.face_index, name=item.get('name'), type=item.get('type'), locked=item.get('locked'))
        board.draw_bitmap(normalize_bitmap(item.get('data')), on_color=self.color, dim_color=self.dim_color)

    def render_current_visual(self):
        if self.runtime_type:
            return
        if self.battery_overlay_active:
            self.render_battery_overlay(force=True)
        else:
            self.draw_saved_face()

    def show_overlay_text(self, kind, value=None):
        log.info('APP', 'overlay show', kind=kind, value=value)
        self.flash_kind = kind
        self.flash_until_ms = add_ms(ticks_ms(), FLASH_HOLD_MS)
        if kind == 'brightness':
            display_num.render_brightness_percent(self.brightness)
        elif kind == 'interval':
            display_num.render_interval(self.interval_s)
        elif kind == 'mode':
            display_num.render_mode(self.auto)
        elif kind == 'manual':
            display_text.draw_centered('MAN' if self.manual_control_mode else 'WEB', color=PURPLE)
        elif kind == 'info':
            display_text.draw_centered(str(value or 'OK'), color=BLUE)

    def stop_overlay_if_expired(self):
        if self.flash_until_ms and diff_ms(ticks_ms(), self.flash_until_ms) >= 0:
            log.debug('APP', 'overlay expired', kind=self.flash_kind)
            self.flash_until_ms = 0
            self.flash_kind = None
            if not self.battery_overlay_active:
                self.draw_saved_face()

    # -------------------- battery overlay --------------------
    def render_battery_overlay(self, force=False):
        now = ticks_ms()
        if (not force) and self.battery_visual_next_ms and diff_ms(now, self.battery_visual_next_ms) < 0:
            return
        snap = self.battery.snapshot()
        pct = 0 if snap.get('percent') is None else snap.get('percent')
        col = battery_color(pct)
        charging = bool(snap.get('charging'))
        charge_ms = now % 1000
        flash_last_col = charging and ((now // BATTERY_CHARGE_FLASH_MS) & 1) == 0
        phase_count = 4 if charging else 3
        if self.battery_overlay_phase >= phase_count:
            self.battery_overlay_phase = 0
        if self.battery_overlay_phase == 0:
            display_num.render_battery_percent(int(pct), color=col, charging=charging, charging_phase_ms=charge_ms, charge_step_interval_s=0.3, flash_last_column=flash_last_col, animate=charging)
        elif self.battery_overlay_phase == 1:
            display_num.render_battery_voltage(snap.get('battery_voltage'), int(pct), color=col, charging=charging, charging_phase_ms=charge_ms, charge_step_interval_s=0.3, flash_last_column=flash_last_col, animate=charging)
        elif self.battery_overlay_phase == 2:
            display_num.render_battery_time(snap.get('estimated_hours'), int(pct), color=col, charging=charging, charging_phase_ms=charge_ms, charge_step_interval_s=0.3, flash_last_column=flash_last_col, animate=charging)
        else:
            display_num.render_charge_voltage(snap.get('charge_voltage'), int(pct), icon_color=col, charging=charging, charging_phase_ms=charge_ms, charge_step_interval_s=0.3, flash_last_column=flash_last_col, animate=charging)
        self.battery_visual_next_ms = add_ms(now, BATTERY_ANIMATION_REFRESH_MS)

    def start_battery_overlay(self, single=False):
        log.info('APP', 'battery overlay start', single=single)
        self.stop_runtime('battery')
        self.battery_overlay_active = True
        self.battery_overlay_single = bool(single)
        self.battery_overlay_phase = 0
        now = ticks_ms()
        self.battery_overlay_until_ms = add_ms(now, 2000) if single else 0
        self.battery_overlay_next_phase_ms = add_ms(now, BATTERY_DISPLAY_CYCLE_MS)
        self.battery_visual_next_ms = 0
        self.render_battery_overlay(force=True)

    def stop_battery_overlay(self):
        if self.battery_overlay_active:
            log.info('APP', 'battery overlay stop')
            self.battery_overlay_active = False
            self.battery_overlay_single = False
            self.draw_saved_face()

    def service_battery_overlay(self):
        if not self.battery_overlay_active:
            return
        now = ticks_ms()
        if self.battery_overlay_single and diff_ms(now, self.battery_overlay_until_ms) >= 0:
            self.stop_battery_overlay()
            return
        if diff_ms(now, self.battery_overlay_next_phase_ms) >= 0:
            self.battery_overlay_phase += 1
            log.debug('APP', 'battery overlay phase', phase=self.battery_overlay_phase)
            self.battery_overlay_next_phase_ms = add_ms(now, BATTERY_DISPLAY_CYCLE_MS)
            self.battery_visual_next_ms = 0
        self.render_battery_overlay()

    # -------------------- runtime animations --------------------
    def stop_runtime(self, reason=''):
        if self.runtime_type:
            log.info('RUNTIME', 'stop', type=self.runtime_type, reason=reason, name=self.runtime_name)
        else:
            log.debug('RUNTIME', 'stop requested idle', reason=reason)
        self.runtime_type = None
        self.runtime_name = ''
        self.runtime_reason = reason

    def start_scroll(self, speed_ms, text):
        self.stop_battery_overlay()
        self.runtime_type = 'scroll'
        self.runtime_name = 'scrollText370'
        self.runtime_started_ms = ticks_ms()
        self.scroll_speed_ms = max(20, int(float(speed_ms)))
        self.scroll_text = str(text)
        self.scroll_x = COLS
        self.scroll_next_ms = 0
        log.info('RUNTIME', 'scroll start', speed_ms=self.scroll_speed_ms, text=self.scroll_text)

    def service_scroll(self):
        now = ticks_ms()
        if self.scroll_next_ms and diff_ms(now, self.scroll_next_ms) < 0:
            return
        display_text.draw_text_at(self.scroll_text, self.scroll_x, y0=5, color=self.color)
        self.scroll_x -= 1
        if self.scroll_x < -display_text.text_width(self.scroll_text):
            log.debug('RUNTIME', 'scroll loop restart', text=self.scroll_text)
            self.scroll_x = COLS
        self.scroll_next_ms = add_ms(now, self.scroll_speed_ms)

    def timeline_begin(self, fps, last_frame, loop, count, name):
        self.stop_runtime('timeline begin')
        self.timeline = {}
        self.timeline_fps = max(1.0, float(fps))
        self.timeline_last_frame = int(last_frame)
        self.timeline_loop = str(loop).lower() in ('1', 'true', 'yes', 'loop')
        self.timeline_expected_count = min(MAX_TIMELINE_FRAMES, int(count))
        self.timeline_name = str(name)[:48]
        log.info('TIMELINE', 'begin', fps=self.timeline_fps, last_frame=self.timeline_last_frame, loop=self.timeline_loop, expected=self.timeline_expected_count, name=self.timeline_name)
        gc.collect()

    def timeline_chunk(self, payload):
        added = 0
        for part in payload.split(';'):
            if not part:
                continue
            if ',' not in part:
                continue
            frame_s, hexdata = part.split(',', 1)
            try:
                frame = int(frame_s)
            except Exception:
                continue
            if len(self.timeline) >= MAX_TIMELINE_FRAMES and frame not in self.timeline:
                continue
            hexdata = ''.join(hexdata.strip().split())
            if len(hexdata) > MAX_TIMELINE_FRAME_HEX:
                hexdata = hexdata[:MAX_TIMELINE_FRAME_HEX]
            self.timeline[frame] = hexdata
            added += 1
        log.info('TIMELINE', 'chunk', added=added, loaded=len(self.timeline))
        return added

    def timeline_play(self):
        if not self.timeline:
            log.warn('TIMELINE', 'play rejected no frames')
            return False
        self.stop_battery_overlay()
        self.runtime_type = 'timeline'
        self.runtime_name = self.timeline_name or 'timeline370'
        self.runtime_started_ms = ticks_ms()
        self.timeline_current_frame = 0
        log.info('TIMELINE', 'play start', name=self.runtime_name, fps=self.timeline_fps, frames=len(self.timeline), last_frame=self.timeline_last_frame, loop=self.timeline_loop)
        return True

    def timeline_preview(self, frame):
        frame = int(frame)
        if frame in self.timeline:
            log.info('TIMELINE', 'preview', frame=frame)
            board.draw_frame_hex(self.timeline[frame], on_color=self.color)
            self.timeline_current_frame = frame
            return True
        log.warn('TIMELINE', 'preview missing frame', frame=frame)
        return False

    def service_timeline(self):
        now = ticks_ms()
        elapsed_s = max(0, diff_ms(now, self.runtime_started_ms) / 1000.0)
        frame = int(elapsed_s * self.timeline_fps)
        if frame > self.timeline_last_frame:
            if self.timeline_loop and self.timeline_last_frame > 0:
                frame = frame % (self.timeline_last_frame + 1)
                self.runtime_started_ms = now - int((frame / self.timeline_fps) * 1000)
            else:
                self.stop_runtime('timeline finished')
                self.draw_saved_face()
                return
        if frame == self.timeline_current_frame and frame != 0:
            return
        self.timeline_current_frame = frame
        if LOG_FRAME_VERBOSE or (frame % max(1, int(self.timeline_fps)) == 0):
            log.debug('TIMELINE', 'frame', frame=frame)
        # Draw exact frame, or nearest prior uploaded keyframe.
        key = frame
        if key not in self.timeline:
            while key > 0 and key not in self.timeline:
                key -= 1
        if key in self.timeline:
            board.draw_frame_hex(self.timeline[key], on_color=self.color)

    def service_runtime(self):
        if self.runtime_type == 'scroll':
            self.service_scroll()
        elif self.runtime_type == 'timeline':
            self.service_timeline()

    # -------------------- control actions --------------------
    def set_manual_mode(self, on):
        old = self.manual_control_mode
        self.manual_control_mode = bool(on)
        self.control_mode = 'manual' if self.manual_control_mode else 'web'
        if old != self.manual_control_mode:
            log.info('CONTROL', 'manual mode changed', old=old, new=self.manual_control_mode, mode=self.control_mode)
        else:
            log.debug('CONTROL', 'manual mode unchanged', value=self.manual_control_mode)
        self.save_runtime_settings()

    def network_control_entered(self, cmd):
        log.debug('CONTROL', 'network command entered', cmd=str(cmd)[:80], manual=self.manual_control_mode)
        # Web/network ordinary control takes ownership and exits manual mode.
        if not (cmd.startswith('request') or cmd.startswith('runtimeStatus')):
            if self.manual_control_mode and not (cmd.startswith('manualMode') or cmd.startswith('manualControlMode')):
                self.set_manual_mode(False)
        ordinary = (
            'brightness|', 'color|', 'bitmap370Json|', 'fullFaceHex370|',
            'partFace370|', 'prevFace370', 'nextFace370', 'toggleAuto370',
            'manualMode|', 'manualControlMode|'
        )
        if cmd.startswith(ordinary):
            self.stop_runtime('network control')

    def button_control_entered(self):
        log.debug('CONTROL', 'button command entered', manual=self.manual_control_mode)
        if not self.manual_control_mode:
            self.set_manual_mode(True)
        self.stop_runtime('button')

    def cycle_face(self, delta):
        if self.faces.count() <= 0:
            return
        self.stop_battery_overlay()
        old = self.face_index
        self.face_index = (self.face_index + int(delta)) % self.faces.count()
        log.info('CONTROL', 'cycle face', old=old, new=self.face_index, delta=delta)
        self.draw_saved_face()
        self.save_runtime_settings()

    def adjust_interval(self, delta):
        old = self.interval_s
        self.interval_s = clamp_interval(self.interval_s + float(delta))
        log.info('CONTROL', 'adjust interval', old=old, new=self.interval_s, delta=delta)
        self.next_auto_ms = add_ms(ticks_ms(), int(self.interval_s * 1000))
        self.show_overlay_text('interval')
        self.save_runtime_settings()

    def adjust_brightness(self, delta):
        old = self.brightness
        self.brightness = clamp_brightness(self.brightness + int(delta))
        log.info('CONTROL', 'adjust brightness', old=old, new=self.brightness, delta=delta)
        self.apply_brightness()
        self.show_overlay_text('brightness')
        self.save_runtime_settings()

    def reset_brightness(self):
        old = self.brightness
        self.brightness = DEFAULT_BRIGHTNESS
        log.info('CONTROL', 'reset brightness', old=old, new=self.brightness)
        self.apply_brightness()
        self.show_overlay_text('brightness')
        self.save_runtime_settings()

    def toggle_auto(self):
        old = self.auto
        self.auto = not self.auto
        log.info('CONTROL', 'toggle auto', old=old, new=self.auto)
        self.next_auto_ms = add_ms(ticks_ms(), int(self.interval_s * 1000))
        self.show_overlay_text('mode')
        self.save_runtime_settings()

    # -------------------- protocol command parser --------------------
    def handle_command(self, cmd, source='local'):
        if cmd is None:
            return 'ERR empty'
        cmd = str(cmd).strip()
        if not cmd:
            return 'ERR empty'
        log.info('CMD', 'received', source=source, cmd=cmd[:160])
        self.network_control_entered(cmd) if source in ('http', 'udp') else None
        try:
            if cmd == 'requestSavedFaces370':
                return self.faces.to_json()
            if cmd == 'requestState':
                return json.dumps(self.state_json())
            if cmd in ('runtimeStatus', 'requestRuntimeStatus'):
                return json.dumps(self.runtime_status_obj())
            if cmd.startswith('runtimeStop'):
                reason = cmd.split('|', 1)[1] if '|' in cmd else ''
                self.stop_runtime(reason)
                self.draw_saved_face()
                return 'ok'
            if cmd == 'requestManualMode' or cmd == 'requestControlMode':
                return json.dumps({'manual_control_mode': self.manual_control_mode, 'control_mode': 'manual' if self.manual_control_mode else 'web'})
            if cmd.startswith('manualMode|'):
                v = cmd.split('|', 1)[1]
                self.set_manual_mode((not self.manual_control_mode) if v == 'toggle' else bool(int(v)))
                self.show_overlay_text('manual')
                return 'ok'
            if cmd.startswith('manualControlMode|'):
                self.set_manual_mode(bool(int(cmd.split('|', 1)[1])))
                self.show_overlay_text('manual')
                return 'ok'
            if cmd.startswith('saveFaces370Json|'):
                payload = cmd.split('|', 1)[1]
                self.faces.set_all(payload)
                if self.face_index >= self.faces.count():
                    self.face_index = max(0, self.faces.count() - 1)
                self.save_runtime_settings()
                return self.faces.to_json()
            if cmd.startswith('addFace370Json|'):
                idx = self.faces.add(json.loads(cmd.split('|', 1)[1]))
                return json.dumps({'ok': True, 'index': idx})
            if cmd.startswith('selectFace370|'):
                self.stop_runtime('selectFace370')
                self.stop_battery_overlay()
                idx = int(cmd.split('|', 1)[1])
                self.draw_saved_face(idx)
                self.save_runtime_settings()
                return 'ok'
            if cmd.startswith('deleteFace370Index|'):
                ok, msg = self.faces.delete(int(cmd.split('|', 1)[1]))
                if self.face_index >= self.faces.count():
                    self.face_index = max(0, self.faces.count() - 1)
                self.draw_saved_face()
                return 'ok' if ok else 'ERR ' + msg
            if cmd.startswith('moveFace370|'):
                _, src, dst = cmd.split('|', 2)
                self.faces.move(src, dst)
                return self.faces.to_json()
            if cmd.startswith('lockFace370|'):
                _, idx, val = cmd.split('|', 2)
                self.faces.lock(idx, val)
                return self.faces.to_json()
            if cmd.startswith('typeFace370|'):
                _, idx, typ = cmd.split('|', 2)
                self.faces.set_type(idx, typ)
                return self.faces.to_json()
            if cmd.startswith('renameFace370Index|'):
                _, idx, name = cmd.split('|', 2)
                self.faces.rename(idx, name)
                return self.faces.to_json()
            if cmd.startswith('updateFace370|'):
                parts = cmd.split('|')
                self.faces.update_meta(parts[1], parts[2] if len(parts) > 2 else None, parts[3] if len(parts) > 3 else None, parts[4] if len(parts) > 4 else None)
                return self.faces.to_json()
            if cmd.startswith('scrollText370|'):
                _, speed, text = cmd.split('|', 2)
                self.start_scroll(speed, text)
                return 'ok'
            if cmd == 'scrollTextStop370':
                self.stop_runtime('scroll stop')
                self.draw_saved_face()
                return 'ok'
            if cmd.startswith('timeline370Begin|'):
                _, fps, last_frame, loop, count, name = cmd.split('|', 5)
                self.timeline_begin(fps, last_frame, loop, count, name)
                return 'ok'
            if cmd.startswith('timeline370Chunk|'):
                added = self.timeline_chunk(cmd.split('|', 1)[1])
                return json.dumps({'ok': True, 'added': added, 'loaded': len(self.timeline)})
            if cmd == 'timeline370Play':
                return 'ok' if self.timeline_play() else 'ERR no timeline frames'
            if cmd.startswith('timeline370Preview|'):
                return 'ok' if self.timeline_preview(cmd.split('|', 1)[1]) else 'ERR frame not loaded'
            if cmd == 'timeline370Stop':
                self.stop_runtime('timeline stop')
                self.draw_saved_face()
                return 'ok'
            if cmd == 'timeline370Clear':
                self.stop_runtime('timeline clear')
                self.timeline = {}
                gc.collect()
                return 'ok'
            if cmd.startswith('brightness|'):
                self.brightness = clamp_brightness(int(cmd.split('|', 1)[1]))
                self.apply_brightness()
                self.show_overlay_text('brightness')
                self.save_runtime_settings()
                return 'ok'
            if cmd.startswith('color|'):
                _, r, g, b = cmd.split('|', 3)
                self.color = (int(r), int(g), int(b))
                board.update_color(self.color)
                self.save_runtime_settings()
                return 'ok'
            if cmd.startswith('fullFaceHex370|'):
                self.stop_runtime('fullFaceHex370')
                bm = legacy_hex_to_bitmap(cmd.split('|', 1)[1])
                board.draw_bitmap(bm, on_color=self.color, dim_color=self.dim_color)
                return 'ok'
            if cmd.startswith('bitmap370Json|'):
                self.stop_runtime('bitmap370Json')
                board.draw_bitmap(normalize_bitmap(cmd.split('|', 1)[1]), on_color=self.color, dim_color=self.dim_color)
                return 'ok'
            if cmd.startswith('partFace370|'):
                _, le, re, mo, ch = cmd.split('|', 4)
                bm = compose_part_bitmap(int(le), int(re), int(mo), int(ch))
                board.draw_bitmap(bm, on_color=self.color, dim_color=self.dim_color)
                return 'ok'
            if cmd in ('prevFace370', 'facePrev'):
                self.cycle_face(-1); return 'ok'
            if cmd in ('nextFace370', 'faceNext'):
                self.cycle_face(+1); return 'ok'
            if cmd == 'toggleAuto370':
                self.toggle_auto(); return 'ok'
            log.warn('CMD', 'unknown', cmd=cmd[:120])
            return 'ERR unknown command: ' + cmd[:80]
        except Exception as e:
            log.exception('CMD', 'command error {}'.format(cmd[:80]), e)
            return 'ERR ' + str(e)

    def handle_legacy_udp(self, data):
        ln = len(data)
        log.info('UDP', 'legacy packet', length=ln)
        self.network_control_entered('legacyUdp')
        self.stop_runtime('legacy udp')
        if ln == 36:
            bm = legacy_grid_to_bitmap(legacy_bits_to_grid(data, offset_rows=0))
            board.draw_bitmap(bm, on_color=self.color, dim_color=self.dim_color)
            return 'ok legacy FACE_FULL'
        if ln == 16:
            bm = legacy_grid_to_bitmap(legacy_bits_to_grid(data, offset_rows=4))
            board.draw_bitmap(bm, on_color=self.color, dim_color=self.dim_color)
            return 'ok legacy FACE_TEXT_LITE'
        if ln == 4:
            bm = compose_part_bitmap(data[0], data[1], data[2], data[3])
            board.draw_bitmap(bm, on_color=self.color, dim_color=self.dim_color)
            return 'ok legacy FACE_LITE'
        if ln == 3:
            self.color = (data[0], data[1], data[2])
            board.update_color(self.color)
            self.save_runtime_settings()
            return 'ok legacy COLOR'
        if ln == 1:
            self.brightness = clamp_brightness(int(data[0] * 100 / 255))
            self.apply_brightness()
            self.save_runtime_settings()
            return 'ok legacy BRIGHT'
        return 'ERR legacy length %d' % ln

    # -------------------- buttons --------------------
    def start_b6_press(self):
        log.info('BUTTON', 'B6 press started')
        self.b6_pending = True
        self.b6_press_started_ms = ticks_ms()
        self.b6_long_fired = False

    def check_b6_hold_release(self):
        b6 = self.buttons.is_down(BTN_BATTERY)
        if self.b6_pending and b6 and not self.buttons.is_down(BTN_AUTO) and not self.buttons.is_down(BTN_NEXT):
            if (not self.b6_long_fired) and diff_ms(ticks_ms(), self.b6_press_started_ms) >= B6_LONG_PRESS_MS:
                self.b6_long_fired = True
                log.info('BUTTON', 'B6 long press')
                self.start_battery_overlay(single=False)
        if self.prev_b6_down and not b6:
            if self.b6_pending:
                if self.b6_long_fired:
                    log.info('BUTTON', 'B6 release after long')
                    self.stop_battery_overlay()
                else:
                    log.info('BUTTON', 'B6 short press')
                    self.start_battery_overlay(single=True)
                self.b6_pending = False
                self.b6_long_fired = False
        self.prev_b6_down = b6

    def check_b3_release(self):
        b3 = self.buttons.is_down(BTN_AUTO)
        if self.prev_b3_down and not b3:
            if not self.b3_consumed and not self.demo_combo_fired:
                log.info('BUTTON', 'B3 release toggle auto')
                self.toggle_auto()
            self.b3_consumed = False
            self.demo_combo_fired = False
        self.prev_b3_down = b3

    def check_combos(self):
        now = ticks_ms()
        b2 = self.buttons.is_down(BTN_NEXT)
        b3 = self.buttons.is_down(BTN_AUTO)
        b4 = self.buttons.is_down(BTN_BRIGHT_DN)
        b5 = self.buttons.is_down(BTN_BRIGHT_UP)
        b6 = self.buttons.is_down(BTN_BATTERY)
        if b4 and b5:
            if not self.brightness_combo_latched:
                log.info('BUTTON', 'combo B4+B5 reset brightness')
                self.button_control_entered()
                self.brightness_combo_latched = True
                self.reset_brightness()
            return True
        else:
            self.brightness_combo_latched = False
        if b3 and b6:
            self.b3_consumed = True
            self.b6_pending = False
            if self.demo_combo_started_ms is None:
                log.info('BUTTON', 'combo B3+B6 started')
                self.demo_combo_started_ms = now
                self.demo_combo_fired = False
            elif (not self.demo_combo_fired) and diff_ms(now, self.demo_combo_started_ms) >= SPECIAL_COMBO_LONG_PRESS_MS:
                self.demo_combo_fired = True
                # MatrixDemo is intentionally disabled/consumed in the ESP32-S3 version.
                log.info('BUTTON', 'combo B3+B6 fired demo disabled')
                self.button_control_entered()
                self.show_overlay_text('info', 'DEMO OFF')
            return True
        self.demo_combo_started_ms = None
        if b2 and b6:
            self.b6_pending = False
            if self.ip_combo_started_ms is None:
                log.info('BUTTON', 'combo B2+B6 started')
                self.ip_combo_started_ms = now
                self.ip_combo_fired = False
            elif (not self.ip_combo_fired) and diff_ms(now, self.ip_combo_started_ms) >= SPECIAL_COMBO_LONG_PRESS_MS:
                self.ip_combo_fired = True
                log.info('BUTTON', 'combo B2+B6 fired IP/SSID scroll')
                self.button_control_entered()
                label = self.network.label() if self.network else 'NO IP'
                self.start_scroll(IP_SCROLL_SPEED_MS, label)
            return True
        self.ip_combo_started_ms = None
        return False

    def handle_button_press(self, gp):
        log.info('BUTTON', 'handle press', gpio=gp)
        self.button_control_entered()
        if self.buttons.is_down(BTN_AUTO) and gp in (BTN_PREV, BTN_NEXT):
            self.b3_consumed = True
            self.adjust_interval(-INTERVAL_STEP_S if gp == BTN_PREV else INTERVAL_STEP_S)
            return
        if gp == BTN_PREV:
            self.cycle_face(-1)
        elif gp == BTN_NEXT:
            self.cycle_face(+1)
        elif gp == BTN_AUTO:
            self.b3_consumed = False
        elif gp == BTN_BRIGHT_DN:
            self.adjust_brightness(-BRIGHTNESS_STEP)
        elif gp == BTN_BRIGHT_UP:
            self.adjust_brightness(+BRIGHTNESS_STEP)
        elif gp == BTN_BATTERY:
            self.start_b6_press()

    def urgent_poll(self):
        # Called by the HTTP/UDP server during long transfers.  It must never
        # poll networking again; it only scans physical buttons and expires the
        # short overlay timer.
        self.service_buttons()
        self.stop_overlay_if_expired()

    def service_buttons(self):
        if self._servicing_buttons:
            return
        self._servicing_buttons = True
        try:
            combo = self.check_combos()
            for gp in self.buttons.poll():
                if combo:
                    continue
                self.handle_button_press(gp)
                self.next_auto_ms = add_ms(ticks_ms(), int(self.interval_s * 1000))
            self.check_combos()
            self.check_b6_hold_release()
            self.check_b3_release()
        finally:
            self._servicing_buttons = False

    def service_auto(self):
        if self.runtime_type or self.battery_overlay_active or self.flash_until_ms:
            self.next_auto_ms = add_ms(ticks_ms(), int(self.interval_s * 1000))
            return
        if self.auto and diff_ms(ticks_ms(), self.next_auto_ms) >= 0:
            old = self.face_index
            self.face_index = (self.face_index + 1) % max(1, self.faces.count())
            log.info('AUTO', 'cycle', old=old, new=self.face_index, interval_s=self.interval_s)
            self.draw_saved_face()
            self.next_auto_ms = add_ms(ticks_ms(), int(self.interval_s * 1000))
            self.save_runtime_settings()

    # -------------------- lifecycle --------------------
    def initialize(self):
        log.info('APP', 'boot', product='RinaChanBoard ESP32-S3 370 native fused', version=VERSION)
        log.info('APP', 'hardware config', led=LED_PIN, batt_adc=BATT_ADC_PIN, chg_adc=CHG_ADC_PIN, buttons=BUTTON_PINS, leds=NUM_LEDS, rows=ROWS, cols=COLS)
        log.info('APP', 'faces config', saved_faces=self.faces.count(), default_start=DEFAULT_START_INDEX)
        self.apply_brightness()
        self.draw_saved_face()
        self.battery.service_mean_sampler(force=True)
        self.network = NetworkManager()
        self.network.begin()
        self.server = ProtocolServer(self)
        self.server.begin()

    def run(self):
        self.initialize()
        last_save_ms = ticks_ms()
        while True:
            self.service_buttons()
            if self.server:
                for _ in range(int(SERVER_POLLS_PER_LOOP)):
                    self.server.poll()
                    self.service_buttons()
            self.battery.service_mean_sampler()
            if self.battery.update_learning_and_history() and diff_ms(ticks_ms(), last_save_ms) > 5000:
                self.save_runtime_settings()
                last_save_ms = ticks_ms()
            self.service_battery_overlay()
            self.stop_overlay_if_expired()
            self.service_runtime()
            self.service_auto()
            self.service_deferred_save()
            now = ticks_ms()
            if diff_ms(now, self.last_heartbeat_ms) >= LOG_HEARTBEAT_MS:
                self.last_heartbeat_ms = now
                snap = self.battery.snapshot()
                log.info('APP', 'heartbeat', face_index=self.face_index, auto=self.auto, manual=self.manual_control_mode, runtime=self.runtime_type or 'none', battery_v=snap.get('battery_voltage'), charge_v=snap.get('charge_voltage'), charging=snap.get('charging'), percent=snap.get('percent'), ap_clients=(self.network.ap_station_count() if self.network else 0))
            time.sleep_ms(POLL_PERIOD_MS)


def main():
    app = RinaChanApp()
    app.run()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        board.clear(True)
        log.warn('APP', 'stopped by KeyboardInterrupt')
