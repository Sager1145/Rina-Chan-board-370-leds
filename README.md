# LinaBoard

This update applies the requested battery-display changes to the current codebase.

## Included changes

- Battery percentage display tolerance reduced from `0.17 V` to `0.12 V`.
- Battery voltage text now renders as `x.x V`, which shifts the `V` one logical column to the right.
- Battery overlay phase timing is now explicitly scheduled so the percent / voltage / time text cycle is more consistent.
- Battery icon rendering supports a charging animation that is separate from the text area below it.
- Charging animation behavior:
  - lights columns left to right
  - advances one column at a time
  - interval is between adjacent column advances, not the whole sweep
  - animation speed scales from `0.50 s` at `0%` to `0.07 s` at `90%`
  - more filled columns remain lit as battery percentage rises
  - when the icon is effectively full, only the last column flashes at `0.3 s`


- Battery runtime estimation is stored in JSON history and uses bounded history with context-aware trimming.
- Battery check cycles through percent, voltage, and estimated remaining time every `2 s` per phase.
- Interval unit now uses uppercase `S` so the suffix renders correctly on the matrix.

## Important hardware note

The current uploaded codebase did not include an existing charge-detect input.
Because of that, this update adds an **optional** charge-status hook in `config.py`:

- `CHARGE_STATUS_GPIO = None`
- `CHARGE_STATUS_ACTIVE_LOW = True`

Set `CHARGE_STATUS_GPIO` to the GPIO connected to the charger status signal if your board exposes one.
If it remains `None`, the battery icon will still render normally, but the charging animation will not activate because the software has no reliable way to know the pack is charging.

## Files changed

- `config.py`
- `app_state.py`
- `battery_monitor.py`
- `display_num.py`
- `main.py`
- `README.md`
