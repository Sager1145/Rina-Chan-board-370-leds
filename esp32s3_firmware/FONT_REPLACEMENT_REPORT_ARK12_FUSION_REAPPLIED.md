# Ark12 fusion font replacement report

## Status

The uploaded firmware package has been patched again from a clean extract of `esp32s3_firmware(39).zip`.

This time the upload script was also patched, so running:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFirmware -UploadFS
```

will not silently rebuild or keep the old Ark12 JSON. The script now validates the fused glyph table before upload.

## Replaced / added files

| File | Action | Size | SHA256 |
|---|---:|---:|---|
| `data/resources/fonts/ark12.json` | replaced with strict-format fused JSON | 2400588 | `fc81caa0a6d04c3ce2000c6b1c439411e48788346df9e42625a41b4d0ae04549` |
| `data/resources/fonts/ark12.json.gz` | regenerated from fused JSON | 531023 | `e94cb4ac5b63c20b96a7accc4329db24256f78f23ac8840ae23ceb66d3081643` |
| `data/resources/fonts/ark12.woff2` | replaced with bundled Ark12 base web font | 593276 | `97ebb9ae2d1d721eb048e025dd885621d566bd6fa9d38c4a3cf4bd56cc2fb175` |
| `data/resources/fonts/ark12_fallback.woff2` | added fused fallback web font | 260352 | `6a1a4fcd5b6f4ec6c3690d15f7d75816c70e6f1608ba12b40e77589bf526e7a3` |
| `data/styles.css` | patched to use fallback chain | 127077 | `d2b01a51e061a911ad91617ec5a258735ebbfdfd7f03ca55928a868b518772ef` |
| `data/index.html` | patched font preload stack for fallback font | 279546 | `2332cb9ce22cf0e556a6bbcd1e290d82a1e506e5a528e18316e6867d4532d824` |
| `data/index.html.gz` | regenerated from patched HTML | 63613 | `166b95f9914d1aaa05baaa175396b716275d782d689bf3f37d625793ed7c075c` |
| `data/styles.css.gz` | regenerated from patched CSS | 62049 | `0a580f58c3d03a468e0dbea27be75ab54bf34d46412c5b48b74c8f5fb3200611` |
| `tools/font_fusion/*` | added bundled fusion source resources for the upload script | - | - |
| `run_rinachan_unifont.ps1` | patched to install/validate fused Ark12 resources | 21185 | `7b7b911a613a91553139536705c72d92fc8dd0c79c5d3e6ce4f3caa3fda19394` |

## Required glyph verification

| Character | Unicode | JSON bitmap | Web fallback WOFF2 |
|---|---:|---:|---:|
| 然 | U+7136 | yes | yes |
| 燃 | U+71C3 | yes | yes |
| 滚 | U+6EDA | yes | yes |
| 滾 | U+6EFE | yes | yes |

## Script behavior changed

`run_rinachan_unifont.ps1` now checks that `ark12.json` has at least 32,000 glyphs and contains `7136 / 71C3 / 6EDA / 6EFE` before upload. If the files are missing or stale, it copies the bundled fusion files from `tools/font_fusion` into `data/resources/fonts` and regenerates `ark12.json.gz`.

## Upload command

Run this inside the extracted `esp32s3_firmware` folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFirmware -UploadFS
```
