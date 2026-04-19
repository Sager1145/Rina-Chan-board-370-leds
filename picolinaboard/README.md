# LinaBoard

This update applies the requested battery-display changes to the current codebase.

## Included changes

- Battery percentage display tolerance is `0.12 V`.
- Battery charging icon animation is separate from the text area below it, so the icon animation does not overwrite or interfere with the percent, voltage, or time text.
- Charging animation advances **one column at a time** from **left to right**.
- The configured timing is the **interval between lighting two adjacent columns**, not the time for the whole sweep.
- Charging speed scales from `0.50 s` at `0%` to `0.07 s` at `90%`.
- As the battery percentage rises, more battery columns stay lit.
- When the icon is effectively full, only the **last column** flashes, with a `0.3 s` interval.
- Battery overlay phase timing is explicitly scheduled so the percent / voltage / time cycle stays consistent instead of drifting.
- Battery voltage text still renders compactly, with the `V` shifted one logical column to the right.
- Interval suffix rendering uses uppercase `S`.

## Battery runtime / history features retained

- Runtime estimation still uses bounded JSON history data.
- When history reaches its maximum length, the entry furthest from the current brightness / mode context is deleted first.
- Battery check still cycles through percent, voltage, and estimated remaining time with a fixed `2 s` phase per item.
- Every `1000` calibration measurements, learned max voltage is reduced by `0.05 V` and learned min voltage is increased by `0.05 V`.
- After that inward adjustment, min/max learning is held off for `20` measurements.

## Important hardware note

The uploaded codebase did not include a guaranteed existing charge-detect input.
Because of that, the charging animation uses an **optional** charger-status GPIO hook in `config.py`:

- `CHARGE_STATUS_GPIO = None`
- `CHARGE_STATUS_ACTIVE_LOW = True`

Set `CHARGE_STATUS_GPIO` to the Pico GPIO connected to the charger status signal if your board exposes one.
If it remains `None`, the normal battery icon still renders, but the charging animation cannot activate because the software has no reliable way to know the pack is charging.

## Files changed

- `config.py`
- `app_state.py`
- `battery_monitor.py`
- `display_num.py`
- `main.py`
- `README.md`
