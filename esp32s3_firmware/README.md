# Rina-Chan Board WebUI Reference

The Rina-Chan Board WebUI is a browser control panel served directly by the ESP32-S3 from LittleFS. It controls a 370-LED WS2812/NeoPixel matrix through HTTP endpoints on the board access point (`RinaChanBoard-V2`, `http://rina.io/`, `http://192.168.1.14/`). Browser controls generate M370 bitmap frames, JSON commands, or saved-face JSON documents; the firmware validates those requests, updates runtime state, and renders through a dedicated LED/scroll task pinned to Core 1. The current WebUI code uses HTTP `fetch`/XHR only; no WebSocket route or frontend WebSocket sender is present.

This document follows the actual WebUI navigation and documents the backend behavior traced from `data/index.html`, `data/app.js`, `src/web_api.cpp`, `src/led_renderer.cpp`, `src/power_monitor.cpp`, `src/faces.cpp`, `src/buttons.cpp`, and `src/scroll.cpp`.

## Loading Overlay / Boot Phase
*The first visible WebUI phase. It appears before the 6.1 page is revealed.*

### Buttons & Controls:
* **Loading overlay**
  * **Action:** Shows the Rina avatar loading animation, blur reveal, halo contraction, and first-page waterfall reveal. The HTML starts with `data-boot-phase="preload"` and `data-scroll-lock="boot"`.
  * **Backend Function:** During the overlay, the browser preloads the initial loading image, waits for the UI font, initializes the 6.1 controls, and starts a firmware status read from `GET /api/status`. The first LED frame can be applied to the preview before the overlay closes.
  * **Code Reference:** `app.js -> bootstrapWebUi()`, `preloadFirmwareRuntimeState()`, `finishBootVisibility()`; `web_api.cpp -> handleApiStatus()`

* **Boot scroll lock**
  * **Action:** The page blocks scrolling while the loader is active. CSS applies `overflow-y: clip`, `touch-action: none`, and disabled text selection under `html[data-scroll-lock="boot"]`. Scroll unlocks only when the reveal starts or the overlay is hidden.
  * **Backend Function:** None. This is a frontend-only boot safety behavior.
  * **Code Reference:** `styles.css -> html[data-scroll-lock="boot"]`; `app.js -> unlockBootPageScroll()`, `animateReveal()`

## Global Navigation / Status Header
*The sidebar brand area and hamburger menu are visible across pages.*

### Buttons & Controls:
* **Hamburger / Page Switcher**
  * **Action:** Opens or closes the top page navigation menu. The menu is generated from `WEBUI_CONFIG.navigation.pages` and switches between pages 6.1 through 6.5 without reloading the browser.
  * **Backend Function:** None directly. Switching to the text-scroll page lazily starts loading the Ark bitmap font resources used for scroll rendering.
  * **Code Reference:** `app.js -> initNav()`, `setNavMenuOpen()`, `switchPage()`, `ensureScrollFontsLoaded()`

* **Page menu buttons: 6.1 基础功能 / 6.2 自定义表情 / 6.3 表情部件 / 6.4 文字滚动 / 6.5 调试**
  * **Action:** Shows the selected page, updates `document.body.dataset.page`, closes the nav menu, rerenders matrices, and refreshes page-specific layout.
  * **Backend Function:** None directly. Firmware status polling continues in the background; power polling runs on Basic and Debug pages.
  * **Code Reference:** `app.js -> switchPage()`, `startFirmwareStatusPolling()`, `startPowerStatusPolling()`

* **Battery badge / Charging badge**
  * **Action:** Displays battery percentage, battery powered/unpowered state, and charging state from firmware power status.
  * **Backend Function:** Browser polls `GET /api/power` and `GET /api/status`. Firmware samples battery ADC `GPIO10` and charge ADC `GPIO1`, uses trimmed ADC averaging, converts through calibration constants, filters battery voltage with an EMA, detects charger presence above `CHARGE_PRESENT_V`, and reports icon classes and text.
  * **Code Reference:** `power_monitor.cpp -> servicePowerMonitor()`, `sampleBattery()`, `sampleCharge()`; `web_api.cpp -> addPowerStatus()`, `handleApiPower()`

## 6.1 基础功能页面 (Basic / Main Control)
*This page controls global LED color, raw NeoPixel brightness, saved-face navigation, and manual/auto mode.*

### Buttons & Controls:
* **当前颜色 text input**
  * **Action:** Accepts `#RRGGBB` or `RRGGBB`, updates the swatch, previews the color on all lit LEDs, and syncs parent/child dropdown selection when the color matches a preset.
  * **Backend Function:** Sends `POST /api/command` with `cmd:"set_color"` and `payload.hex`. Firmware validates the hex color, updates `runtimeState().colorHex/colorR/colorG/colorB`, touches slow runtime state, and requests an LED render.
  * **Code Reference:** `app.js -> initColorInput()`, `setColor()`; `web_api.cpp -> commandSetColor()`; `led_renderer.cpp -> setColor()`

* **父颜色 dropdown**
  * **Action:** Chooses a parent color preset, updates the current color, repopulates child-color options, and refreshes the custom select UI.
  * **Backend Function:** Same as the color input: `POST /api/command`, `cmd:"set_color"`.
  * **Code Reference:** `app.js -> initColors()`, `setColor()`; `web_api.cpp -> commandSetColor()`; `led_renderer.cpp -> setColor()`

* **子颜色 dropdown**
  * **Action:** Chooses a child color under the active parent. The special “use parent color” option reverts to the parent preset.
  * **Backend Function:** Same as the color input: `POST /api/command`, `cmd:"set_color"`.
  * **Code Reference:** `app.js -> renderChildColors()`, `setColor()`; `web_api.cpp -> commandSetColor()`; `led_renderer.cpp -> setColor()`

* **重置默认亮度**
  * **Action:** Restores the brightness slider/input to the firmware-synced default brightness, falling back to raw `50`.
  * **Backend Function:** Sends `POST /api/command`, `cmd:"set_brightness"`, `payload.raw`. Firmware clamps brightness to `10..200`, updates runtime brightness, and requests a render.
  * **Code Reference:** `app.js -> resetBrightnessDefault()`, `setBrightness()`; `web_api.cpp -> commandSetBrightness()`; `led_renderer.cpp -> setBrightness()`

* **−8 / +8 brightness buttons**
  * **Action:** Decreases or increases raw brightness by `8`.
  * **Backend Function:** Sends `cmd:"set_brightness"` to `/api/command`. Firmware clamps with `MIN_BRIGHTNESS` and `MAX_BRIGHTNESS`.
  * **Code Reference:** `app.js -> initBrightness()`, `setBrightness()`; `web_api.cpp -> commandSetBrightness()`; `led_renderer.cpp -> setBrightness()`

* **Brightness slider**
  * **Action:** Continuously changes raw brightness from `10` to `200`.
  * **Backend Function:** Sends `cmd:"set_brightness"` through the auxiliary command path. The LED render task later applies `strip.setBrightness()` only when the value changes.
  * **Code Reference:** `app.js -> initBrightness()`, `setBrightness()`; `web_api.cpp -> commandSetBrightness()`; `led_renderer.cpp -> setBrightness()`, `renderCurrentFrameToLedStrip()`

* **Brightness number input**
  * **Action:** Commits a typed raw brightness value.
  * **Backend Function:** Same as brightness slider.
  * **Code Reference:** `app.js -> initBrightness()`, `setBrightness()`; `web_api.cpp -> commandSetBrightness()`; `led_renderer.cpp -> setBrightness()`

* **Brightness preset buttons: 10 / 25 / 50 / 80 / 128 / 160 / 200**
  * **Action:** Sets the brightness to the selected raw preset.
  * **Backend Function:** Same as brightness slider.
  * **Code Reference:** `app.js -> renderPresetButtons()`, `initBrightness()`; `web_api.cpp -> commandSetBrightness()`; `led_renderer.cpp -> setBrightness()`

* **← previous face**
  * **Action:** Moves to the previous saved face in the unified saved-face library and updates all matrix previews.
  * **Backend Function:** Queues `POST /api/command`, `cmd:"button"`, `payload.button:"B2"`. Firmware runs the same semantic action as hardware B2: stops firmware scroll if active, clears auto-restore, decrements `autoFaceIndex` with wraparound, and applies that saved face by M370.
  * **Code Reference:** `app.js -> prevFace()`, `sendButtonCommand()`; `web_api.cpp -> commandButton()`; `buttons.cpp -> runButtonAction()`; `faces.cpp -> applyRelativeSavedFace()`; `led_renderer.cpp -> applyM370()`

* **→ next face**
  * **Action:** Moves to the next saved face in the unified saved-face library and updates all matrix previews.
  * **Backend Function:** Queues `POST /api/command`, `cmd:"button"`, `payload.button:"B1"`. Firmware stops firmware scroll if active, clears auto-restore, increments `autoFaceIndex` with wraparound, and applies the saved face by M370.
  * **Code Reference:** `app.js -> nextFace()`, `sendButtonCommand()`; `web_api.cpp -> commandButton()`; `buttons.cpp -> runButtonAction()`; `faces.cpp -> applyRelativeSavedFace()`; `led_renderer.cpp -> applyM370()`

* **M 手动 / A 自动 toggle**
  * **Action:** Toggles between manual saved-face mode and automatic saved-face cycling. The label changes to `M 手动` or `A 自动`.
  * **Backend Function:** Queues `POST /api/command`, `cmd:"button"`, `payload.button:"B3"`. Firmware runs `toggleModeFromButtonAction()`, stops firmware scroll, switches mode, persists runtime settings, applies the current saved face, and if switching away from another activity first blanks the display and schedules a delayed saved-face restore.
  * **Code Reference:** `app.js -> toggleMode()`, `sendButtonCommand()`; `web_api.cpp -> commandButton()`; `buttons.cpp -> runButtonAction()`; `faces.cpp -> toggleModeFromButtonAction()`, `setMode()`

* **−0.5 / +0.5 auto interval buttons**
  * **Action:** Decreases or increases automatic saved-face interval by `500 ms`.
  * **Backend Function:** Sends `POST /api/command`, `cmd:"set_auto_interval"`, `payload.ms`. Firmware constrains the interval to `500..10000 ms` and persists runtime settings.
  * **Code Reference:** `app.js -> adjustInterval()`, `setAutoIntervalMs()`; `web_api.cpp -> commandSetAutoInterval()`; `faces.cpp -> setAutoInterval()`

* **Auto interval slider**
  * **Action:** Sets automatic saved-face interval in seconds from `0.5` to `10.0`.
  * **Backend Function:** Same `cmd:"set_auto_interval"` path. Firmware stores milliseconds.
  * **Code Reference:** `app.js -> setAutoIntervalSeconds()`, `setAutoIntervalMs()`; `web_api.cpp -> commandSetAutoInterval()`; `faces.cpp -> setAutoInterval()`

* **Auto interval number input**
  * **Action:** Commits a typed interval in seconds.
  * **Backend Function:** Same as auto interval slider.
  * **Code Reference:** `app.js -> setAutoIntervalSeconds()`; `web_api.cpp -> commandSetAutoInterval()`; `faces.cpp -> setAutoInterval()`

* **Auto interval presets: 0.5 / 1 / 2 / 3 / 5 / 7.5 / 10 s**
  * **Action:** Sets the automatic saved-face interval to a preset.
  * **Backend Function:** Same as auto interval slider.
  * **Code Reference:** `app.js -> renderPresetButtons()`, `initBasicControls()`; `web_api.cpp -> commandSetAutoInterval()`; `faces.cpp -> setAutoInterval()`

* **370 LED readonly preview**
  * **Action:** Displays the current logical M370 frame. It is not editable on this page.
  * **Backend Function:** Populated from `/api/status` `renderer.lastM370` when not scrolling. Firmware returns logical row-major M370; physical serpentine mapping happens only during LED output.
  * **Code Reference:** `app.js -> initializeBasicPreviewMatrix()`, `applyFirmwareRuntimeState()`; `web_api.cpp -> handleApiStatus()`; `led_renderer.cpp -> logicalToPhysicalLedIndex()`, `renderCurrentFrameToLedStrip()`

## 6.2 自定义表情页面 (Custom Face)
*This page edits a 370-cell bitmap manually, sends it as M370, and manages the shared saved-face JSON library.*

### Buttons & Controls:
* **Custom matrix cells**
  * **Action:** Clicking an editable LED cell toggles that logical bit in the custom edit frame and updates the M370 textarea.
  * **Backend Function:** None unless realtime mode is on. With realtime enabled, each edit sends the current frame through `POST /api/frame`.
  * **Code Reference:** `app.js -> initMatrix()`, `editCell()`, `sendCustomFrameIfLive()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **发送**
  * **Action:** Sends the current custom bitmap to the board and makes it the active output.
  * **Backend Function:** Browser converts the frame with `frameToM370()` and queues `POST /api/frame`. Firmware stops firmware scroll for non-scroll modes, sets custom/parts output to manual mode, sets `runtimeState().playback`, validates M370, and queues/applies the packed frame.
  * **Code Reference:** `app.js -> sendCustomFrame()`, `setCurrentFrame()`, `queueFirmwareFrame()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> normalizeM370()`, `applyM370()`, `enqueuePackedM370Frame()`

* **实时 toggle**
  * **Action:** Toggles live-send mode shared by Custom and Parts pages. When enabled, edit operations automatically send new M370 frames.
  * **Backend Function:** No command on toggle itself. Subsequent edits call `POST /api/frame`.
  * **Code Reference:** `app.js -> toggleLiveSend()`, `sendCustomFrameIfLive()`, `sendPartsFrameIfLive()`

* **清空**
  * **Action:** Clears the custom edit frame to all LEDs off.
  * **Backend Function:** Sends `POST /api/frame` only if realtime mode is enabled.
  * **Code Reference:** `app.js -> initCustom()`, `blankFrame()`, `sendCustomFrameIfLive()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **全亮**
  * **Action:** Sets every logical LED in the custom edit frame on.
  * **Backend Function:** Sends `POST /api/frame` only if realtime mode is enabled.
  * **Code Reference:** `app.js -> initCustom()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **反转**
  * **Action:** Inverts every logical bit in the custom edit frame.
  * **Backend Function:** Sends `POST /api/frame` only if realtime mode is enabled.
  * **Code Reference:** `app.js -> initCustom()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **M370 textarea**
  * **Action:** Shows the custom frame as `M370:<93 hex>`. Users can paste a compatible M370 string.
  * **Backend Function:** None until imported or sent.
  * **Code Reference:** `app.js -> updateM370Views()`, `frameToM370()`, `m370ToFrame()`

* **复制 M370**
  * **Action:** Copies the custom frame M370 string to the clipboard.
  * **Backend Function:** None.
  * **Code Reference:** `app.js -> copyText()`, `frameToM370()`

* **从文本导入到画板**
  * **Action:** Parses the textarea as M370 and replaces the editable custom frame.
  * **Backend Function:** None by itself. It only changes browser state.
  * **Code Reference:** `app.js -> m370ToFrame()`, `initCustom()`

* **保存自定义表情**
  * **Action:** Adds the custom frame to the unified saved-face library using the name in `保存名称`.
  * **Backend Function:** Builds a normalized `saved_faces.json` document and sends `POST /api/saved_faces`. Firmware validates the document, writes it atomically under `/resources/saved_faces.json`, and reloads runtime auto faces without changing the active frame.
  * **Code Reference:** `app.js -> saveFace()`, `persistFaceDocuments()`; `web_api.cpp -> handleSavedFacesPost()`; `storage.cpp -> validateSavedFaces()`, `writeSavedFaces()`, `loadSavedFaces()`

* **保存名称 input**
  * **Action:** Supplies the display name for the next saved custom face, truncated to 64 characters.
  * **Backend Function:** Included in the saved face JSON only when saving.
  * **Code Reference:** `app.js -> saveFace()`

* **读取 saved_faces.json**
  * **Action:** Reloads the unified face library from the firmware API, falling back to static/local JSON if needed.
  * **Backend Function:** Calls `GET /api/saved_faces`. Firmware streams `/resources/saved_faces.json` from LittleFS.
  * **Code Reference:** `app.js -> loadFaceLibrary()`, `loadUnifiedFacesDocument()`; `web_api.cpp -> handleSavedFacesGet()`

* **打开本地 saved_faces.json**
  * **Action:** Uses the browser File System Access API to open a local JSON file, imports it, and stores a handle for later write-back.
  * **Backend Function:** After import, the browser also tries `POST /api/saved_faces` to sync the firmware copy.
  * **Code Reference:** `app.js -> openLocalFaceLibraryFile()`, `importFacesJsonText()`, `persistFaceDocuments()`; `web_api.cpp -> handleSavedFacesPost()`

* **保存到已打开文件**
  * **Action:** Writes the current unified face document back to the previously opened local file.
  * **Backend Function:** None unless other persistence already calls firmware sync. This button itself writes through the browser file handle.
  * **Code Reference:** `app.js -> saveFaceLibraryToLocalFile()`

* **下载 saved_faces.json**
  * **Action:** Downloads the current unified face document.
  * **Backend Function:** None.
  * **Code Reference:** `app.js -> downloadFacesJson()`, `downloadJsonFile()`

* **导入 saved_faces.json**
  * **Action:** Opens a hidden file picker and imports a JSON file.
  * **Backend Function:** After normalization, sends `POST /api/saved_faces` to replace firmware saved faces.
  * **Code Reference:** `app.js -> initFaceManagerControls()`, `importFacesJsonFile()`, `persistFaceDocuments()`; `web_api.cpp -> handleSavedFacesPost()`

* **Saved-face row drag handle**
  * **Action:** Drag-reorders saved faces. The UI autoscrolls near window edges while dragging.
  * **Backend Function:** Reassigns 1-based `order` values and sends `POST /api/saved_faces`.
  * **Code Reference:** `app.js -> attachFaceReorderHandle()`, `reorderFace()`, `persistFaceDocuments()`; `web_api.cpp -> handleSavedFacesPost()`

* **Saved-face name input / ✏️**
  * **Action:** Edits a saved-face name. Enter or blur commits. The pencil focuses and selects the input.
  * **Backend Function:** Sends `POST /api/saved_faces` with the renamed document. Default faces may be renamed.
  * **Code Reference:** `app.js -> createFaceRow()`, `persistFaceDocuments()`; `web_api.cpp -> handleSavedFacesPost()`

* **Saved-face ↑ / ↓**
  * **Action:** Moves a face up or down in display and auto-play order.
  * **Backend Function:** Sends reordered `saved_faces.json` through `POST /api/saved_faces`.
  * **Code Reference:** `app.js -> moveFace()`, `reorderFace()`; `web_api.cpp -> handleSavedFacesPost()`

* **Saved-face 🗑️**
  * **Action:** Deletes a user custom/parts face after confirmation. Default faces show a disabled delete button and cannot be deleted.
  * **Backend Function:** Sends updated `saved_faces.json` through `POST /api/saved_faces`. Firmware validation requires at least one `type:"default"` face.
  * **Code Reference:** `app.js -> deleteFace()`; `web_api.cpp -> handleSavedFacesPost()`; `storage.cpp -> validateSavedFaces()`

* **Saved-face 💡 upload/apply**
  * **Action:** Applies that saved face to the board.
  * **Backend Function:** Browser sends the row M370 through `POST /api/frame`. Firmware applies M370 and, when `faceId` is present, can align `autoFaceIndex`.
  * **Code Reference:** `app.js -> applySavedFace()`, `setCurrentFrame()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

## 6.3 表情部件组合页面 (Expression Parts)
*This page composes a face from predefined left-eye, right-eye, mouth, and cheek parts, then sends or saves the composed M370 frame.*

### Buttons & Controls:
* **Part selection cards: leye / reye / mouth / cheek**
  * **Action:** Selects one part from the generated part lists. Each button shows an 8x8 mini preview and display number. Cheek ID `400` resolves to the empty part.
  * **Backend Function:** None unless realtime mode is enabled. With realtime enabled, the composed frame is sent by `POST /api/frame`.
  * **Code Reference:** `app.js -> initParts()`, `selectPart()`, `composePartsFrame()`, `orPartIntoFrame()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **发送**
  * **Action:** Sends the composed parts frame to the board.
  * **Backend Function:** Same M370 path as Custom: `POST /api/frame`; firmware stops scroll, switches custom/parts output to manual mode, validates M370, and queues/applies the frame.
  * **Code Reference:** `app.js -> sendPartsFrame()`, `setCurrentFrame()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **实时 toggle**
  * **Action:** Toggles live-send mode shared with the Custom page.
  * **Backend Function:** No command on toggle itself. Later part changes send `POST /api/frame`.
  * **Code Reference:** `app.js -> toggleLiveSend()`, `sendPartsFrameIfLive()`

* **随机**
  * **Action:** Randomizes selected parts. Eyes and mouth avoid ID `0`; cheeks may select empty `400`. If symmetry is enabled, left/right eyes use the same display index.
  * **Backend Function:** Immediately sends the randomized composed frame via `POST /api/frame`.
  * **Code Reference:** `app.js -> randomParts()`, `sendPartsFrame()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **默认**
  * **Action:** Resets selected parts to left eye `101`, right eye `201`, mouth `301`, cheek `400`.
  * **Backend Function:** Sends `POST /api/frame` only if realtime mode is enabled.
  * **Code Reference:** `app.js -> initParts()`, `composePartsFrame()`, `sendPartsFrameIfLive()`

* **左右眼对称 toggle**
  * **Action:** When enabled, selecting either eye synchronizes both eyes by display index. Random also uses matched eye display indices.
  * **Backend Function:** Sends `POST /api/frame` only if realtime mode is enabled.
  * **Code Reference:** `app.js -> syncSymmetricEyesFrom()`, `renderPartButtons()`, `sendPartsFrameIfLive()`

* **M370 textarea**
  * **Action:** Shows the composed parts output M370.
  * **Backend Function:** None until imported, copied, sent, or saved.
  * **Code Reference:** `app.js -> updateM370Views()`

* **复制 M370**
  * **Action:** Copies the composed frame M370 to the clipboard.
  * **Backend Function:** None.
  * **Code Reference:** `app.js -> frameToM370()`, `copyText()`

* **从文本导入到当前输出**
  * **Action:** Parses the textarea as M370 and immediately applies that frame as the current board output.
  * **Backend Function:** Sends `POST /api/frame` with reason `parts_m370_import`.
  * **Code Reference:** `app.js -> m370ToFrame()`, `setCurrentFrame()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **保存部件表情**
  * **Action:** Saves the composed frame as a `type:"parts"` user face, including the selected part call IDs.
  * **Backend Function:** Sends updated `saved_faces.json` through `POST /api/saved_faces`.
  * **Code Reference:** `app.js -> saveFace()`; `web_api.cpp -> handleSavedFacesPost()`; `storage.cpp -> validateSavedFaces()`, `writeSavedFaces()`

* **Saved-face JSON controls and saved-face row controls**
  * **Action:** Same shared controls as the Custom page: read, open local, save local, download, import, reorder, rename, delete user faces, and apply faces.
  * **Backend Function:** Same shared `GET /api/saved_faces`, `POST /api/saved_faces`, and `POST /api/frame` paths.
  * **Code Reference:** `app.js -> initFaceManagerControls()`, `createFaceRow()`; `web_api.cpp -> handleApiSavedFaces()`, `handleApiFrame()`

## 6.4 文字滚动页面 (Text Scroll)
*This page rasterizes text into M370 frames, uploads those frames to firmware RAM, and lets the firmware scroll independently.*

### Buttons & Controls:
* **滚动文字 textarea**
  * **Action:** Accepts up to 1000 visible characters, normalizes emoji presentation selectors, autoresizes, marks the scroll timeline dirty, and keeps currently running firmware scroll unchanged until the next send.
  * **Backend Function:** None while typing.
  * **Code Reference:** `app.js -> sanitizeScrollTextInput()`, `markScrollTextDirty()`, `autoResizeScrollTextInput()`

* **重置默认帧率**
  * **Action:** Sets FPS back to default `10`.
  * **Backend Function:** If scroll is active, paused, or firmware-backed, sends `POST /api/command`, `cmd:"set_scroll_interval"` with FPS and interval milliseconds. Firmware constrains interval to `33..1000 ms`.
  * **Code Reference:** `app.js -> setScrollFps()`; `web_api.cpp -> commandSetScrollInterval()`; `faces.cpp -> startFirmwareScroll()`; `config.h -> MIN_SCROLL_INTERVAL_MS`

* **−5 / +5 FPS buttons**
  * **Action:** Decreases or increases text-scroll FPS by 5, clamped to `1..60`.
  * **Backend Function:** Sends `cmd:"set_scroll_interval"` only while scroll is active/paused/firmware-backed.
  * **Code Reference:** `app.js -> setScrollFps()`; `web_api.cpp -> commandSetScrollInterval()`

* **FPS slider**
  * **Action:** Continuously sets FPS from `1` to `60`.
  * **Backend Function:** Same as FPS buttons when a scroll timeline is active.
  * **Code Reference:** `app.js -> initScroll()`, `setScrollFps()`; `web_api.cpp -> commandSetScrollInterval()`

* **FPS number input**
  * **Action:** Accepts digits only, sanitizes pasted/typed values, and sets FPS from `1` to `60`.
  * **Backend Function:** Same as FPS slider when active.
  * **Code Reference:** `app.js -> sanitizeScrollFpsInput()`, `setScrollFps()`; `web_api.cpp -> commandSetScrollInterval()`

* **FPS preset buttons: 1 / 10 / 20 / 30 / 40 / 50 / 60**
  * **Action:** Sets FPS to the selected preset.
  * **Backend Function:** Same as FPS slider when active.
  * **Code Reference:** `app.js -> renderPresetButtons()`, `setScrollFps()`; `web_api.cpp -> commandSetScrollInterval()`

* **发送**
  * **Action:** Generates a text bitmap with the Ark Pixel 12px font table, extracts one M370 frame per horizontal LED offset, uploads frames in chunks to firmware RAM, then starts firmware scroll. The progress bar shows encoding, chunk upload, and start progress.
  * **Backend Function:** Uploads chunks with `POST /api/scroll` (`frames`, `append`, `storage:"ram"`, `persist:false`, `saveToFlash:false`). Firmware validates every M370 frame into the scroll frame buffer and refuses flash persistence. After upload, browser sends `POST /api/command`, `cmd:"start_scroll"`. Firmware starts scroll playback from frame 0, may switch auto mode to manual while remembering `restoreAutoAfterScroll`, and applies the first frame immediately.
  * **Code Reference:** `app.js -> startScroll()`, `prepareTextScrollTimelineAsync()`, `uploadFirmwareScrollTimeline()`; `web_api.cpp -> handleApiScroll()`, `commandStartScroll()`; `faces.cpp -> startFirmwareScroll()`; `scroll.cpp -> scrollRenderTask()`

* **暂停 / 继续**
  * **Action:** Pauses or resumes text scroll. Disabled when no firmware/user scroll is active or when only a system pause is active.
  * **Backend Function:** Pause sends `cmd:"pause_scroll"`; resume sends `cmd:"resume_scroll"`. Firmware toggles user pause flags and leaves cached frames in RAM.
  * **Code Reference:** `app.js -> togglePauseScroll()`, `pauseScroll()`, `resumeScroll()`; `web_api.cpp -> commandPauseScroll()`, `commandResumeScroll()`; `faces.cpp -> setFirmwareScrollUserPaused()`, `resumeFirmwareScrollIfCached()`

* **停止/清屏**
  * **Action:** Stops local preview, clears scroll state, clears the display preview, applies the startup/default saved face locally, and returns to auto mode if scroll interrupted auto playback.
  * **Backend Function:** Sends `POST /api/command`, `cmd:"stop_scroll"`, `payload.clear:true`, `payload.restoreAuto`. Firmware stops scroll, clears the scroll frame cache state, clears queued M370 frames, applies a blank frame, then schedules the startup default saved face after the blank hold. If auto should restore, it returns to `auto_saved_face`.
  * **Code Reference:** `app.js -> stopScroll()`; `web_api.cpp -> commandStopScroll()`; `faces.cpp -> stopFirmwareScroll()`, `scheduleStartupDefaultFaceRestoreAfterBlank()`, `serviceDeferredFaceRestore()`

* **<- previous frame**
  * **Action:** Generates/uses the current text timeline, steps the browser preview one frame backward, and marks playback as `scroll_step`.
  * **Backend Function:** Sends `POST /api/command`, `cmd:"scroll_step"`, `payload.direction:1` because this button is wired with direction `1` in the current code. Firmware treats positive direction as next frame. The label and code direction are therefore reversed in the current implementation.
  * **Code Reference:** `app.js -> setScrollStepHandler("scroll-step-prev", 1)`; `web_api.cpp -> commandScrollStep()`; `led_renderer.cpp -> applyPackedFrameImmediate()`

* **-> next frame**
  * **Action:** Generates/uses the current text timeline, steps the browser preview one frame forward, and marks playback as `scroll_step`.
  * **Backend Function:** Sends `cmd:"scroll_step"`, `payload.direction:-1` because this button is wired with direction `-1`. Firmware treats negative direction as previous frame. The label and code direction are therefore reversed in the current implementation.
  * **Code Reference:** `app.js -> setScrollStepHandler("scroll-step-next", -1)`; `web_api.cpp -> commandScrollStep()`; `led_renderer.cpp -> applyPackedFrameImmediate()`

* **Upload progress bar**
  * **Action:** Displays local encode and HTTP upload progress.
  * **Backend Function:** Reflects `POST /api/scroll` chunking and the final `start_scroll` command. Scroll frames are RAM-only and are not saved to flash or `saved_faces.json`.
  * **Code Reference:** `app.js -> setScrollUploadProgress()`, `completeScrollUploadProgress()`, `apiPostWithUploadProgress()`; `web_api.cpp -> handleApiScroll()`

* **Text-scroll LED preview**
  * **Action:** Shows generated or currently previewed text-scroll frame.
  * **Backend Function:** During firmware scroll, status polling uses summary/no-frame reads to avoid pulling full M370 while scrolling. Firmware Core 1 advances cached frames at `scrollIntervalMs`.
  * **Code Reference:** `app.js -> advanceScroll()`, `syncRuntimeSummaryFromFirmware()`; `web_api.cpp -> handleApiStatus()`; `scroll.cpp -> scrollRenderTask()`

## 6.5 调试页面 (Debug)
*This page displays merged runtime state and exposes diagnostics for GPIO semantics, M370 patterns, power, logs, and firmware API checks.*

### Buttons & Controls:
* **主控制 / 状态信息 panel**
  * **Action:** Displays state, renderer, AP, memory, storage, queues, scroll, and power fields. Shows a warning if estimated current-frame power exceeds 40 W.
  * **Backend Function:** Populated by `GET /api/status` and `GET /api/power`. Firmware status includes runtime version, AP clients, renderer values, scroll state, memory, storage, and stats.
  * **Code Reference:** `app.js -> renderState()`, `syncRuntimeStateFromFirmware()`; `web_api.cpp -> handleApiStatus()`, `addPowerStatus()`

* **B1 下一个 / B2 上一个 / B3 A/M / B4 亮度- / B5 亮度+ / B6 短按电量 / B6 长按详情 / B3+B1 间隔- / B3+B2 间隔+ / B6+B3 网络信息**
  * **Action:** These buttons exist in HTML with `data-gpio` attributes and receive only the global visual press animation.
  * **Backend Function:** No current JavaScript event listener is bound to `data-gpio`, so these debug buttons do not send commands in the current WebUI. The corresponding firmware semantic button actions exist for `B1`, `B2`, `B3`, `B4`, `B5`, `B3B1`, and `B3B2`; `B6S`, `B6L`, and `B6B3` are not accepted by `runButtonAction()`.
  * **Code Reference:** `index.html -> button[data-gpio]`; `app.js -> initButtonPressAnimations()`; `buttons.cpp -> runButtonAction()`

* **全黑**
  * **Action:** Sends an all-off debug frame.
  * **Backend Function:** Sends `POST /api/frame` with a blank M370 and reason `debug_all_off`.
  * **Code Reference:** `app.js -> initializeDebugControls()`, `setCurrentFrame()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **全亮**
  * **Action:** Sends an all-on debug frame.
  * **Backend Function:** Sends `POST /api/frame` with all 370 bits on and reason `debug_all_on`.
  * **Code Reference:** `app.js -> initializeDebugControls()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **棋盘**
  * **Action:** Generates a checkerboard pattern over valid matrix cells and sends it.
  * **Backend Function:** Sends `POST /api/frame`, reason `debug_checker`.
  * **Code Reference:** `app.js -> makePatternFrame("checker")`, `setCurrentFrame()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **边框**
  * **Action:** Generates a border pattern along each valid row range and sends it.
  * **Backend Function:** Sends `POST /api/frame`, reason `debug_border`.
  * **Code Reference:** `app.js -> makePatternFrame("border")`, `setCurrentFrame()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **当前保存表情**
  * **Action:** Applies the currently selected saved face from the browser library.
  * **Backend Function:** Sends that face as M370 through `POST /api/frame`.
  * **Code Reference:** `app.js -> applySavedFace()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> applyM370()`

* **Debug M370 textarea**
  * **Action:** Accepts `93` hex characters or `M370:<93 hex>`.
  * **Backend Function:** None until `解析并应用 M370`.
  * **Code Reference:** `app.js -> m370ToFrame()`

* **解析并应用 M370**
  * **Action:** Parses the debug textarea and sends the result as the active board output.
  * **Backend Function:** Sends `POST /api/frame`, reason `debug_apply_m370`. Firmware validates with `normalizeM370()`.
  * **Code Reference:** `app.js -> initializeDebugControls()`, `m370ToFrame()`, `setCurrentFrame()`; `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> normalizeM370()`, `applyM370()`

* **复制状态 JSON**
  * **Action:** Copies the browser-side `state` object to the clipboard.
  * **Backend Function:** None.
  * **Code Reference:** `app.js -> initializeDebugControls()`

* **清空用户表情**
  * **Action:** After confirmation, removes all non-default user faces from the browser library and rerenders lists.
  * **Backend Function:** Sends updated `saved_faces.json` through `POST /api/saved_faces`. Firmware validation preserves required default faces.
  * **Code Reference:** `app.js -> initializeDebugControls()`, `persistFaceDocuments()`; `web_api.cpp -> handleSavedFacesPost()`; `storage.cpp -> validateSavedFaces()`

* **刷新电池状态**
  * **Action:** Forces an immediate browser power refresh and rerenders badges and debug power fields.
  * **Backend Function:** Calls `GET /api/power`. Firmware samples power through `servicePowerMonitor()`, then returns full `addPowerStatus()` output.
  * **Code Reference:** `app.js -> refreshPowerStatusFromFirmware()`; `web_api.cpp -> handleApiPower()`; `power_monitor.cpp -> servicePowerMonitor()`

* **重置最低电压**
  * **Action:** Resets the persisted battery minimum calibration record.
  * **Backend Function:** Sends `POST /api/command`, `cmd:"reset_battery_min"`. Firmware calls `resetBatteryVoltageMinimum()`: if battery is powered, not charging, and the current voltage is safely below the max record, it records current filtered `vbat`; otherwise it resets to nominal `BATTERY_EMPTY_V`. The value is written to `/resources/battery_calib.json`.
  * **Code Reference:** `app.js -> resetBatteryVoltageRecord("min")`; `web_api.cpp -> commandResetBatteryMinimum()`; `power_monitor.cpp -> resetBatteryVoltageMinimum()`, `saveBatteryCalibration()`

* **重置最高电压**
  * **Action:** Resets the persisted battery maximum calibration record.
  * **Backend Function:** Sends `POST /api/command`, `cmd:"reset_battery_max"`. Firmware calls `resetBatteryVoltageMaximum()`: if battery is powered and current filtered `vbat` is safely above the min record, it records current `vbat`; otherwise it resets to nominal `BATTERY_FULL_V`. The value is written to `/resources/battery_calib.json`.
  * **Code Reference:** `app.js -> resetBatteryVoltageRecord("max")`; `web_api.cpp -> commandResetBatteryMaximum()`; `power_monitor.cpp -> resetBatteryVoltageMaximum()`, `saveBatteryCalibration()`

* **ADC 调试 Vbat / ADC 调试 Vcharge inputs**
  * **Action:** Local-only debug fields for simulating UI battery/charge display values.
  * **Backend Function:** None until `更新 ADC 状态`, and even then no firmware request is sent.
  * **Code Reference:** `app.js -> initializeDebugControls()`

* **更新 ADC 状态**
  * **Action:** Updates browser state using the two debug input values, recomputes local charging/unpowered flags, and rerenders the UI.
  * **Backend Function:** None. This does not change ESP32 ADC readings or calibration.
  * **Code Reference:** `app.js -> initializeDebugControls()`, `batteryIconForPercent()`

* **通信日志 command input**
  * **Action:** Accepts JSON text for an auxiliary debug command payload.
  * **Backend Function:** None until `发送辅助命令`.
  * **Code Reference:** `app.js -> initializeDebugControls()`

* **发送辅助命令**
  * **Action:** Parses the command input as JSON and attempts to send it.
  * **Backend Function:** Sends `POST /api/command`, `cmd:"manual_json"`, `payload:<parsed JSON>`. The current firmware route table does not include `manual_json`, so the backend returns `400 unknown command: manual_json`.
  * **Code Reference:** `app.js -> initializeDebugControls()`, `sendAuxCommand()`; `web_api.cpp -> findApiCommandRoute()`, `handleApiCommand()`

* **清空日志**
  * **Action:** Clears the browser communication log.
  * **Backend Function:** None.
  * **Code Reference:** `app.js -> renderLog()`, `initializeDebugControls()`

* **下载日志**
  * **Action:** Downloads the browser log text using the JSON download helper. The filename is `rina_webui_log.txt`.
  * **Backend Function:** None.
  * **Code Reference:** `app.js -> downloadJsonFile()`, `initializeDebugControls()`

* **读取固件状态**
  * **Action:** Forces a full firmware status sync.
  * **Backend Function:** Calls `GET /api/status`. Firmware returns renderer state, AP info, power, matrix metadata, endpoints, storage, memory, and stats. While scrolling or summary mode, full `lastM370` may be skipped/deferred.
  * **Code Reference:** `app.js -> syncRuntimeStateFromFirmware("firmware_ping")`; `web_api.cpp -> handleApiStatus()`

* **发送暂停指令**
  * **Action:** Sends a firmware pause command from the debug page.
  * **Backend Function:** Sends `POST /api/command`, `cmd:"pause_scroll"`. Firmware pauses firmware scroll if active; this button is named generically but currently uses the scroll-specific pause command, not the generic `pause` route.
  * **Code Reference:** `app.js -> initializeDebugControls()`; `web_api.cpp -> commandPauseScroll()`; `faces.cpp -> setFirmwareScrollUserPaused()`

* **Resource / System panel**
  * **Action:** Shows resource/storage hints and values from firmware status.
  * **Backend Function:** `GET /api/status` reports LittleFS mount state, saved-face/settings file paths, storage capacity when safe, heap, PSRAM, and scroll buffer location.
  * **Code Reference:** `app.js -> renderState()`; `web_api.cpp -> handleApiStatus()`; `state.cpp -> initRuntimeScrollFrameBuffer()`

## Shared Backend Notes

### M370 Frame Rendering
* **Action:** Browser pages send logical M370 frames to firmware using `POST /api/frame`.
* **Backend Function:** Firmware validates `M370:<93 hex>` strings, decodes 370 logical row-major bits into packed bytes, and queues frames when requests arrive faster than `M370_FRAME_MIN_INTERVAL_MS` (`33 ms`). Queue depth is `3`; overflow drops the oldest queued frame and increments `framesDropped`.
* **Code Reference:** `web_api.cpp -> handleApiFrame()`; `led_renderer.cpp -> normalizeM370()`, `decodeNormalizedM370ToPackedBits()`, `enqueuePackedM370Frame()`, `serviceM370FrameQueue()`

### Optimized LED Refresh Timing
* **Action:** User controls update browser state immediately, then firmware applies LED updates without blocking WebServer timing-sensitive paths longer than necessary.
* **Backend Function:** Main loop on Core 0 services queued M370 frames, HTTP, buttons, power, deferred restores, and auto playback. Core 1 runs `scrollRenderTask()`, consumes render requests, advances firmware scroll frames, and calls `renderCurrentFrameToLedStrip()`. The renderer copies state under lock, releases locks before pixel buffer work, waits for `LED_RENDER_MIN_GAP_US`, performs `strip.show()` under the hardware bus lock, and inserts `LED_SIGNAL_RESET_US` reset gaps before and after the show. These gaps let non-LED tasks run cooperatively without disrupting WS2812 timing.
* **Code Reference:** `main.cpp -> loop()`; `scroll.cpp -> scrollRenderTask()`; `led_renderer.cpp -> requestLedRender()`, `renderCurrentFrameToLedStrip()`; `config.h -> LED_RENDER_MIN_GAP_US`, `LED_SIGNAL_RESET_US`

### Battery Percentage Algorithm
* **Action:** Battery status appears in the header and Debug page.
* **Backend Function:** Firmware samples battery and charge ADCs every second using 16 samples with trimmed averaging. Battery voltage is converted with `BATTERY_CAL_SCALE` and `BATTERY_CAL_OFFSET_V`, filtered with a 20-second EMA, and mapped to percent using the custom 2S LiPo piecewise-linear lookup table in `BATTERY_PERCENT_LUT`. The displayed percent updates only when the computed value changes by more than 1 point. Battery disconnect/unpowered detection forces `vbat=0` and `batteryPercent=0`.
* **Code Reference:** `power_monitor.cpp -> readTrimmedAdcMilliVolts()`, `sampleBattery()`, `batteryPercentFromVoltage()`; `config.h -> BATTERY_PERCENT_LUT`

* **Calibration min/max behavior**
  * **Action:** Debug buttons expose reset of minimum and maximum voltage records.
  * **Backend Function:** Firmware loads and saves `/resources/battery_calib.json` with `v_min` and `v_max`. The sampling path computes a `freezeCalibration` flag that is true while charging, disconnected, unpowered, or below the unpowered threshold, so any automatic calibration tracking path is explicitly paused during charging. In the current code, `updateBatteryCalibration()` only sanitizes/defaults the records rather than automatically expanding min/max; actual record changes happen through the reset-min/reset-max commands. Do not treat `batteryRangeMin` and `batteryRangeMax` as live automatically tracked extrema in this firmware revision.
  * **Code Reference:** `power_monitor.cpp -> updateBatteryCalibration()`, `sampleBattery()`, `resetBatteryVoltageMinimum()`, `resetBatteryVoltageMaximum()`, `saveBatteryCalibration()`

### HTTP API Summary
* `GET /api/status` -> full or summary runtime state. `since`, `runtimeOnly`, `summary`, `noFrame`, and `fullPower` query parameters affect payload size.
* `GET /api/power` -> full power object.
* `POST /api/frame` -> one active M370 output frame.
* `POST /api/scroll` -> RAM-only scroll frame chunks.
* `POST /api/command` -> auxiliary command route table: `set_color`, `set_brightness`, `set_mode`, `set_auto_interval`, `set_scroll_interval`, `start_scroll`, `scroll_step`, `pause_scroll`, `resume_scroll`, `stop_scroll`, `pause`, `resume`, `button`, `terminate_other_activities`, `reset_battery_min`, `reset_battery_max`.
* `GET /api/saved_faces` -> stream `/resources/saved_faces.json`.
* `POST /api/saved_faces` -> validate, atomically write, and reload saved faces.

## Coverage Critique

I checked the static HTML controls, dynamically generated controls, custom select menus, saved-face row buttons, part buttons, preset buttons, hidden file input, loading overlay, and Debug controls. Two visible Debug-page areas are intentionally documented as nonfunctional in the current implementation: `button[data-gpio]` helper buttons have no JavaScript handler, and `发送辅助命令` posts `manual_json`, which is not present in the firmware command route table.

The README describes the implemented firmware behavior rather than only frontend labels. The main caveat is battery min/max tracking: the code has calibration storage, reset controls, and a freeze-while-charging path, but automatic expansion of min/max is currently not implemented inside `updateBatteryCalibration()`.
