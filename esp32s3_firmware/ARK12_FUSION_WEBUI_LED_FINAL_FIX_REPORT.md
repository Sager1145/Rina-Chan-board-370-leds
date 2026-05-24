# Ark12 Fusion WebUI/LED Final Fix Report

## Result

Fixed the two issues that can cause patched characters to appear as a square/tofu and to be converted into a square LED frame.

## Root causes fixed

1. **Compressed WebUI assets could be stale.** `run_rinachan_unifont.ps1` rebuilt/embedded the WebUI GNU Unifont subset into `styles.css`, but did not regenerate `styles.css.gz`. If the ESP32 served the `.gz` asset, the browser could still receive the old CSS.
2. **Browser font matching was too fragile.** The previous package used a separate `Ark Pixel 12px Fusion Fallback` font family. This version registers the fallback WOFF2 under the same family as Ark: `Ark Pixel 12px Monospaced`, with deterministic `unicode-range` generated from the real font cmap.
3. **The WebUI JSON glyph tuple parser had the wrong field order.** It now reads the original schema correctly: `[advance, width, height, xOffset, yOffset, dstY, rowsHex]`.

## Files changed

- `data/styles.css`
- `data/styles.css.gz`
- `data/index.html`
- `data/index.html.gz`
- `run_rinachan_unifont.ps1`
- `README.md`
- `plan.md`

## Patched glyph verification

| Character | Codepoint | JSON | Web fallback WOFF2 | Width | Height | Advance | Lit pixels | Not square glyph |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 然 | `U+7136` | yes | yes | 12 | 12 | 12 | 42 | yes |
| 燃 | `U+71C3` | yes | yes | 12 | 12 | 12 | 53 | yes |
| 滚 | `U+6EDA` | yes | yes | 12 | 12 | 12 | 44 | yes |
| 滾 | `U+6EFE` | yes | yes | 12 | 12 | 12 | 50 | yes |

## Gzip synchronization

- `data/index.html.gz` matches `data/index.html`: **yes**
- `data/styles.css.gz` matches `data/styles.css`: **yes**
- `data/resources/fonts/ark12.json.gz` matches `ark12.json`: **yes**

## Required upload command

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .un_rinachan_unifont.ps1 -UploadFirmware -UploadFS
```

The script now regenerates compressed WebUI assets before `uploadfs`, so the board should not serve stale CSS/HTML.

## Manual browser check

After uploading, hard refresh the WebUI once. In DevTools Console:

```js
document.fonts.check('12px "Ark Pixel 12px Monospaced"', '然燃滚滾')
```

Expected: `true`.

Then enter `然燃滚滾` into text-scroll and click send. The loader now throws an explicit error if `ark12.json` does not contain the patched glyphs; it will not silently use `□` for these four characters.
