import time
from machine import Pin
from config import (
    BUTTON_PINS, BTN_PREV, BTN_NEXT, BTN_AUTO, BTN_BRIGHT_DN, BTN_BRIGHT_UP, BTN_BATTERY,
    BUTTON_DEBOUNCE_MS, BUTTON_REPEAT_INITIAL_MS, BUTTON_REPEAT_PERIOD_MS,
)

DEFAULT_REPEAT_GPIOS = (BTN_PREV, BTN_NEXT, BTN_BRIGHT_DN, BTN_BRIGHT_UP)


class ButtonBank:
    def __init__(self, gpios=BUTTON_PINS, repeat_gpios=DEFAULT_REPEAT_GPIOS):
        self._pins = []
        self._last_state = {}
        self._last_change_ms = {}
        self._press_started_ms = {}
        self._next_repeat_ms = {}
        self._repeat_gpios = set(repeat_gpios)
        now = time.ticks_ms()
        for gp in gpios:
            p = Pin(gp, Pin.IN, Pin.PULL_UP)
            self._pins.append((gp, p))
            self._last_state[gp] = p.value()
            self._last_change_ms[gp] = now
            self._press_started_ms[gp] = None
            self._next_repeat_ms[gp] = None

    def poll(self):
        fired = []
        now = time.ticks_ms()
        for gp, pin in self._pins:
            v = pin.value()
            if v != self._last_state[gp]:
                if time.ticks_diff(now, self._last_change_ms[gp]) >= BUTTON_DEBOUNCE_MS:
                    self._last_state[gp] = v
                    self._last_change_ms[gp] = now
                    if v == 0:
                        fired.append(gp)
                        self._press_started_ms[gp] = now
                        if gp in self._repeat_gpios:
                            self._next_repeat_ms[gp] = time.ticks_add(now, BUTTON_REPEAT_INITIAL_MS)
                        else:
                            self._next_repeat_ms[gp] = None
                    else:
                        self._press_started_ms[gp] = None
                        self._next_repeat_ms[gp] = None
                continue
            if v == 0 and self._next_repeat_ms[gp] is not None:
                if time.ticks_diff(now, self._next_repeat_ms[gp]) >= 0:
                    fired.append(gp)
                    self._next_repeat_ms[gp] = time.ticks_add(now, BUTTON_REPEAT_PERIOD_MS)
        return fired

    pressed = poll

    def is_down(self, gpio):
        return self._last_state.get(gpio, 1) == 0

    def is_down_raw(self, gpio):
        for gp, p in self._pins:
            if gp == gpio:
                return p.value() == 0
        return False

    def any_down(self):
        return any(self._last_state.get(gp, 1) == 0 for gp, _ in self._pins)

    def gpios(self):
        return [gp for gp, _ in self._pins]
