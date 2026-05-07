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
# Import: Loads time so this module can use that dependency.
import time
# Import: Loads Pin from machine so this module can use that dependency.
from machine import Pin

# ---------------------------------------------------------------------------
# Button-to-GPIO assignments.
# These names are used throughout the rest of the project.
# ---------------------------------------------------------------------------
# Variable: BTN_PREV stores the configured literal value.
BTN_PREV       = 17   # Button 1: previous face / interval down
# Variable: BTN_NEXT stores the configured literal value.
BTN_NEXT       = 16   # Button 2: next face / interval up
# Variable: BTN_AUTO stores the configured literal value.
BTN_AUTO       = 15   # Button 3: toggle auto / modifier for interval
# Variable: BTN_BRIGHT_DN stores the configured literal value.
BTN_BRIGHT_DN  = 40   # Button 4: brightness down
# Variable: BTN_BRIGHT_UP stores the configured literal value.
BTN_BRIGHT_UP  = 41   # Button 5: brightness up
# Variable: BTN_BRIGHT_RST stores the configured literal value.
BTN_BRIGHT_RST = 42   # Button 6: reset brightness

# ---------------------------------------------------------------------------
# Default button list used when constructing a ButtonBank.
# ---------------------------------------------------------------------------
# Variable: DEFAULT_BUTTON_PINS stores the collection of values used later in this module.
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
# Variable: DEFAULT_REPEAT_GPIOS stores the collection of values used later in this module.
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
# Variable: DEBOUNCE_MS stores the configured literal value.
DEBOUNCE_MS = 25

# ---------------------------------------------------------------------------
# Autorepeat timing:
# - after the initial real press, wait REPEAT_INITIAL_MS before the first repeat
# - then emit repeat events every REPEAT_PERIOD_MS while held
# ---------------------------------------------------------------------------
# Variable: REPEAT_INITIAL_MS stores the configured literal value.
REPEAT_INITIAL_MS = 400
# Variable: REPEAT_PERIOD_MS stores the configured literal value.
REPEAT_PERIOD_MS = 140


# ---------------------------------------------------------------------------
# ButtonBank: debounced active-low input collection with autorepeat.
# poll() returns a list of GPIO numbers that fired on this tick.
# ---------------------------------------------------------------------------
# Class: Defines ButtonBank as the state and behavior container for Button Bank.
class ButtonBank:
    # Module: Documents the purpose of this scope.
    """Active-low buttons with internal pull-ups and optional autorepeat."""

    # Variable: __slots__ stores the collection of values used later in this module.
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
    # Function: Defines __init__(self, gpios, debounce_ms, repeat_gpios, repeat_initial_ms, repeat_period_ms) to handle init behavior.
    def __init__(self, gpios=DEFAULT_BUTTON_PINS,
                 debounce_ms=DEBOUNCE_MS,
                 repeat_gpios=DEFAULT_REPEAT_GPIOS,
                 repeat_initial_ms=REPEAT_INITIAL_MS,
                 repeat_period_ms=REPEAT_PERIOD_MS):
        # Variable: self._pins stores the collection of values used later in this module.
        self._pins = []
        # Variable: self._last_state stores the lookup table used by this module.
        self._last_state = {}
        # Variable: self._last_change_ms stores the lookup table used by this module.
        self._last_change_ms = {}
        # Variable: self._debounce_ms stores the current debounce_ms value.
        self._debounce_ms = debounce_ms
        # Variable: self._repeat_gpios stores the conditional expression set(repeat_gpios) if repeat_gpios else set().
        self._repeat_gpios = set(repeat_gpios) if repeat_gpios else set()
        # Variable: self._press_started_ms stores the lookup table used by this module.
        self._press_started_ms = {}
        # Variable: self._next_repeat_ms stores the lookup table used by this module.
        self._next_repeat_ms = {}
        # Variable: self._initial_ms stores the current repeat_initial_ms value.
        self._initial_ms = repeat_initial_ms
        # Variable: self._period_ms stores the current repeat_period_ms value.
        self._period_ms = repeat_period_ms

        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()

        # Loop: Iterates gp over gpios so each item can be processed.
        for gp in gpios:
            # Variable: p stores the result returned by Pin().
            p = Pin(gp, Pin.IN, Pin.PULL_UP)
            # Expression: Calls self._pins.append() for its side effects.
            self._pins.append((gp, p))
            # Variable: self._last_state[...] stores the result returned by p.value().
            self._last_state[gp] = p.value()
            # Variable: self._last_change_ms[...] stores the current now value.
            self._last_change_ms[gp] = now
            # Variable: self._press_started_ms[...] stores the empty sentinel value.
            self._press_started_ms[gp] = None
            # Variable: self._next_repeat_ms[...] stores the empty sentinel value.
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
    # Function: Defines poll(self) to handle poll behavior.
    def poll(self):
        # Variable: fired stores the collection of values used later in this module.
        fired = []
        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Variable: debounce stores the referenced self._debounce_ms value.
        debounce = self._debounce_ms

        # Loop: Iterates gp, p over self._pins so each item can be processed.
        for gp, p in self._pins:
            # Variable: v stores the result returned by p.value().
            v = p.value()

            # ----------------------------------------------------------------
            # If the raw GPIO level changed relative to the last stable state,
            # treat it as a potential edge and apply debounce logic.
            # ----------------------------------------------------------------
            # Logic: Branches when v != self._last_state[gp] so the correct firmware path runs.
            if v != self._last_state[gp]:
                # Logic: Branches when time.ticks_diff(now, self._last_change_ms[gp]) >= debounce so the correct firmware path runs.
                if time.ticks_diff(now, self._last_change_ms[gp]) >= debounce:
                    # Variable: self._last_state[...] stores the current v value.
                    self._last_state[gp] = v
                    # Variable: self._last_change_ms[...] stores the current now value.
                    self._last_change_ms[gp] = now

                    # --------------------------------------------------------
                    # Fresh press: active-low, so v == 0 means pressed.
                    # Fire one event immediately and arm autorepeat if enabled.
                    # --------------------------------------------------------
                    # Logic: Branches when v == 0 so the correct firmware path runs.
                    if v == 0:
                        # Expression: Calls fired.append() for its side effects.
                        fired.append(gp)
                        # Variable: self._press_started_ms[...] stores the current now value.
                        self._press_started_ms[gp] = now

                        # Logic: Branches when gp in self._repeat_gpios so the correct firmware path runs.
                        if gp in self._repeat_gpios:
                            # Variable: self._next_repeat_ms[...] stores the result returned by time.ticks_add().
                            self._next_repeat_ms[gp] = time.ticks_add(
                                now, self._initial_ms
                            )
                        # Logic: Runs this fallback branch when the earlier condition did not match.
                        else:
                            # Variable: self._next_repeat_ms[...] stores the empty sentinel value.
                            self._next_repeat_ms[gp] = None

                    # --------------------------------------------------------
                    # Release: clear repeat scheduling and press timing.
                    # --------------------------------------------------------
                    # Logic: Runs this fallback branch when the earlier condition did not match.
                    else:
                        # Variable: self._press_started_ms[...] stores the empty sentinel value.
                        self._press_started_ms[gp] = None
                        # Variable: self._next_repeat_ms[...] stores the empty sentinel value.
                        self._next_repeat_ms[gp] = None

                # ------------------------------------------------------------
                # If still inside the debounce window, ignore the edge.
                # ------------------------------------------------------------
                # Control: Skips to the next loop iteration after this case is handled.
                continue

            # ----------------------------------------------------------------
            # No stable edge happened this tick.
            # If the button is still held and this GPIO supports repeat,
            # emit repeat events at the scheduled repeat times.
            # ----------------------------------------------------------------
            # Logic: Branches when v == 0 and self._next_repeat_ms[gp] is not None so the correct firmware path runs.
            if v == 0 and self._next_repeat_ms[gp] is not None:
                # Logic: Branches when time.ticks_diff(now, self._next_repeat_ms[gp]) >= 0 so the correct firmware path runs.
                if time.ticks_diff(now, self._next_repeat_ms[gp]) >= 0:
                    # Expression: Calls fired.append() for its side effects.
                    fired.append(gp)
                    # Variable: self._next_repeat_ms[...] stores the result returned by time.ticks_add().
                    self._next_repeat_ms[gp] = time.ticks_add(
                        now, self._period_ms
                    )

        # Return: Sends the current fired value back to the caller.
        return fired

    # -----------------------------------------------------------------------
    # Alias: pressed() behaves the same as poll().
    # -----------------------------------------------------------------------
    # Variable: pressed stores the current poll value.
    pressed = poll

    # -----------------------------------------------------------------------
    # Return True if the specified GPIO's button is currently held down.
    # This uses the debounced stable state, not the raw pin reading.
    # -----------------------------------------------------------------------
    # Function: Defines is_down(self, gpio) to handle is down behavior.
    def is_down(self, gpio):
        # Return: Sends the comparison result self._last_state.get(gpio, 1) == 0 back to the caller.
        return self._last_state.get(gpio, 1) == 0

    # -----------------------------------------------------------------------
    # Return True if the specified GPIO's raw input is currently low.
    # Kept available for diagnostics; most runtime logic should use is_down().
    # -----------------------------------------------------------------------
    # Function: Defines is_down_raw(self, gpio) to handle is down raw behavior.
    def is_down_raw(self, gpio):
        # Loop: Iterates gp, p over self._pins so each item can be processed.
        for gp, p in self._pins:
            # Logic: Branches when gp == gpio so the correct firmware path runs.
            if gp == gpio:
                # Return: Sends the comparison result p.value() == 0 back to the caller.
                return p.value() == 0
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False

    # -----------------------------------------------------------------------
    # Return True if any managed button is currently held down.
    # Uses debounced stable state.
    # -----------------------------------------------------------------------
    # Function: Defines any_down(self) to handle any down behavior.
    def any_down(self):
        # Loop: Iterates gp, _ over self._pins so each item can be processed.
        for gp, _ in self._pins:
            # Logic: Branches when self._last_state.get(gp, 1) == 0 so the correct firmware path runs.
            if self._last_state.get(gp, 1) == 0:
                # Return: Sends the enabled/disabled flag value back to the caller.
                return True
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False

    # -----------------------------------------------------------------------
    # Return the list of GPIO numbers managed by this bank.
    # -----------------------------------------------------------------------
    # Function: Defines gpios(self) to handle gpios behavior.
    def gpios(self):
        # Return: Sends the expression [gp for gp, _ in self._pins] back to the caller.
        return [gp for gp, _ in self._pins]