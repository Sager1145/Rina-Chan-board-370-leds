# ---------------------------------------------------------------------------
# buttons.py
#
# Debounced button input with optional autorepeat for held buttons.
# Each button is wired between a GPIO pin and GND.
# Internal pull-ups are enabled, so the buttons are active-low:
# - unpressed -> GPIO reads 1
# - pressed   -> GPIO reads 0
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Standard time helper for debounce and repeat timing.
# Pin is the MicroPython GPIO input class.
# ---------------------------------------------------------------------------
import time
from machine import Pin

# ---------------------------------------------------------------------------
# Button-to-GPIO assignments.
# These names are used throughout the rest of the project.
# ---------------------------------------------------------------------------
BTN_PREV       = 20   # Button 1: previous face / interval down
BTN_NEXT       = 19   # Button 2: next face / interval up
BTN_AUTO       = 18   # Button 3: toggle auto / modifier for interval
BTN_BRIGHT_DN  = 11   # Button 4: brightness down
BTN_BRIGHT_UP  = 12   # Button 5: brightness up
BTN_BRIGHT_RST = 13   # Button 6: reset brightness

# ---------------------------------------------------------------------------
# Default button list used when constructing a ButtonBank.
# ---------------------------------------------------------------------------
DEFAULT_BUTTON_PINS = (
    BTN_PREV,
    BTN_NEXT,
    BTN_AUTO,
    BTN_BRIGHT_DN,
    BTN_BRIGHT_UP,
    BTN_BRIGHT_RST,
)

# ---------------------------------------------------------------------------
# Buttons that should generate autorepeat events while held.
# B3 and B6 intentionally do not repeat:
# - B3 is a toggle / modifier
# - B6 is a one-shot reset
# ---------------------------------------------------------------------------
DEFAULT_REPEAT_GPIOS = (
    BTN_PREV,
    BTN_NEXT,
    BTN_BRIGHT_DN,
    BTN_BRIGHT_UP,
)

# ---------------------------------------------------------------------------
# Debounce window in milliseconds.
# Physical switch bounce within this time is ignored.
# ---------------------------------------------------------------------------
DEBOUNCE_MS = 25

# ---------------------------------------------------------------------------
# Autorepeat timing:
# - after the initial real press, wait REPEAT_INITIAL_MS before the first repeat
# - then emit repeat events every REPEAT_PERIOD_MS while held
# ---------------------------------------------------------------------------
REPEAT_INITIAL_MS = 400
REPEAT_PERIOD_MS = 140


# ---------------------------------------------------------------------------
# ButtonBank: debounced active-low input collection with autorepeat.
# poll() returns a list of GPIO numbers that fired on this tick.
# ---------------------------------------------------------------------------
class ButtonBank:
    """Active-low buttons with internal pull-ups and optional autorepeat."""

    __slots__ = (
        "_pins",             # list of (gpio, Pin object)
        "_last_state",       # last stable GPIO level seen
        "_last_change_ms",   # last accepted state-change time
        "_debounce_ms",      # debounce threshold in ms
        "_repeat_gpios",     # set of GPIOs that should repeat while held
        "_press_started_ms", # press start time for each GPIO
        "_next_repeat_ms",   # next scheduled repeat time for each GPIO
        "_initial_ms",       # initial repeat delay
        "_period_ms",        # repeat interval
    )

    # -----------------------------------------------------------------------
    # Create the button bank and initialize per-button state.
    # Each GPIO is configured as input with internal pull-up enabled.
    # -----------------------------------------------------------------------
    def __init__(self, gpios=DEFAULT_BUTTON_PINS,
                 debounce_ms=DEBOUNCE_MS,
                 repeat_gpios=DEFAULT_REPEAT_GPIOS,
                 repeat_initial_ms=REPEAT_INITIAL_MS,
                 repeat_period_ms=REPEAT_PERIOD_MS):
        self._pins = []
        self._last_state = {}
        self._last_change_ms = {}
        self._debounce_ms = debounce_ms
        self._repeat_gpios = set(repeat_gpios) if repeat_gpios else set()
        self._press_started_ms = {}
        self._next_repeat_ms = {}
        self._initial_ms = repeat_initial_ms
        self._period_ms = repeat_period_ms

        now = time.ticks_ms()

        for gp in gpios:
            p = Pin(gp, Pin.IN, Pin.PULL_UP)
            self._pins.append((gp, p))
            self._last_state[gp] = p.value()
            self._last_change_ms[gp] = now
            self._press_started_ms[gp] = None
            self._next_repeat_ms[gp] = None

    # -----------------------------------------------------------------------
    # Poll all buttons and return a list of GPIO numbers that fired this tick.
    #
    # A returned GPIO may represent:
    # - a fresh real press
    # - an autorepeat event while held
    #
    # Release events are not returned directly; they are only used internally
    # to stop repeat scheduling and stabilize button state.
    # -----------------------------------------------------------------------
    def poll(self):
        fired = []
        now = time.ticks_ms()
        debounce = self._debounce_ms

        for gp, p in self._pins:
            v = p.value()

            # ----------------------------------------------------------------
            # If the raw GPIO level changed relative to the last stable state,
            # treat it as a potential edge and apply debounce logic.
            # ----------------------------------------------------------------
            if v != self._last_state[gp]:
                if time.ticks_diff(now, self._last_change_ms[gp]) >= debounce:
                    self._last_state[gp] = v
                    self._last_change_ms[gp] = now

                    # --------------------------------------------------------
                    # Fresh press: active-low, so v == 0 means pressed.
                    # Fire one event immediately and arm autorepeat if enabled.
                    # --------------------------------------------------------
                    if v == 0:
                        fired.append(gp)
                        self._press_started_ms[gp] = now

                        if gp in self._repeat_gpios:
                            self._next_repeat_ms[gp] = time.ticks_add(
                                now, self._initial_ms
                            )
                        else:
                            self._next_repeat_ms[gp] = None

                    # --------------------------------------------------------
                    # Release: clear repeat scheduling and press timing.
                    # --------------------------------------------------------
                    else:
                        self._press_started_ms[gp] = None
                        self._next_repeat_ms[gp] = None

                # ------------------------------------------------------------
                # If still inside the debounce window, ignore the edge.
                # ------------------------------------------------------------
                continue

            # ----------------------------------------------------------------
            # No stable edge happened this tick.
            # If the button is still held and this GPIO supports repeat,
            # emit repeat events at the scheduled repeat times.
            # ----------------------------------------------------------------
            if v == 0 and self._next_repeat_ms[gp] is not None:
                if time.ticks_diff(now, self._next_repeat_ms[gp]) >= 0:
                    fired.append(gp)
                    self._next_repeat_ms[gp] = time.ticks_add(
                        now, self._period_ms
                    )

        return fired

    # -----------------------------------------------------------------------
    # Alias: pressed() behaves the same as poll().
    # -----------------------------------------------------------------------
    pressed = poll

    # -----------------------------------------------------------------------
    # Return True if the specified GPIO's button is currently held down.
    # This uses the debounced stable state, not the raw pin reading.
    # -----------------------------------------------------------------------
    def is_down(self, gpio):
        return self._last_state.get(gpio, 1) == 0

    # -----------------------------------------------------------------------
    # Return True if the specified GPIO's raw input is currently low.
    # Kept available for diagnostics; most runtime logic should use is_down().
    # -----------------------------------------------------------------------
    def is_down_raw(self, gpio):
        for gp, p in self._pins:
            if gp == gpio:
                return p.value() == 0
        return False

    # -----------------------------------------------------------------------
    # Return True if any managed button is currently held down.
    # Uses debounced stable state.
    # -----------------------------------------------------------------------
    def any_down(self):
        for gp, _ in self._pins:
            if self._last_state.get(gp, 1) == 0:
                return True
        return False

    # -----------------------------------------------------------------------
    # Return the list of GPIO numbers managed by this bank.
    # -----------------------------------------------------------------------
    def gpios(self):
        return [gp for gp, _ in self._pins]