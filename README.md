# LinaBoard battery + charging update

This package updates the uploaded project to do the following:

- detect charger voltage on **ADC1 / GP27**
- treat about **3.0 V** as non-charging and **>= 4.5 V** as charging
- keep the previous charge state between those thresholds to avoid flicker
- keep the normal battery page cycle at **3 pages** when not charging
- switch to **4 pages** when charging:
  1. battery percent
  2. battery voltage
  3. estimated time
  4. charger voltage
- keep the battery icon color tied to the battery percentage color
- render the charger-voltage text in **white**
- animate the battery icon column-by-column while charging
- keep all battery flashing intervals at **0.3 s**
- keep the last battery column flashing when the battery is full and charging
- use a **30 s** logging interval
- shrink learned battery min/max by **0.05 V** every **1000** discharge measurements
- apply the **20-measurement** holdoff after each inward adjustment
- stop discharge/runtime logging while charging
- log charging-time history separately while charging
- provide fallback estimates of **1H** runtime and **30M** charging time when no history exists yet
- keep the first battery screen alive for a full cycle instead of showing too briefly
- sample battery and charger voltages in the same averaging window so battery pages stay more even
- show battery voltage as **x.xV** below 10 V
- show charger voltage on the fourth page as compact white text

## Files included in the zip

Changed:
- config.py
- app_state.py
- battery_runtime.py
- settings_store.py
- battery_monitor.py
- display_num.py
- main.py
- README.md

Unchanged copies also included for convenience:
- board.py
- brightness_modes.py
- buttons.py
- demo_faces.py
- matrix_demos.py
- badapple_mode.py
- converter(3).py


## v4.1 fix

- fixed the battery page-count update logic so the overlay actually switches from 3 pages to 4 pages as soon as charging is detected


## Charge detect divider

GP27 / ADC1 charge detection is now interpreted through the external resistor divider:

- R1 = 270k
- R2 = 47k

The firmware now converts the ADC pin voltage back to the real charger-side voltage before applying the 3.0 V non-charging and 4.5 V charging thresholds.
